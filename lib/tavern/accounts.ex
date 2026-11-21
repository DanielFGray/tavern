defmodule Tavern.Accounts do
  @moduledoc """
  Authentication and account management for tavern users.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tavern.Accounts.LoginRateLimiter
  alias Tavern.Accounts.Scope
  alias Tavern.Accounts.VerificationMail
  alias Tavern.Chat.AuditLog
  alias Tavern.Chat.BotToken
  alias Tavern.Chat.ChannelMembership
  alias Tavern.Chat.ChannelNotificationOverride
  alias Tavern.Chat.ChannelPermissionOverwrite
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Invites
  alias Tavern.Chat.ServerSettings
  alias Tavern.Chat.ThreadFollower
  alias Tavern.Chat.Topics
  alias Tavern.Chat.User
  alias Tavern.Chat.UserNotificationSetting
  alias Tavern.Chat.UserSession
  alias Tavern.Chat.Visibility
  alias Tavern.Ephemeral
  alias Tavern.ProductEvents
  alias Tavern.Repo

  @session_valid_days 30
  @email_token_valid_days 7
  @password_reset_valid_minutes 60
  @deletion_sweep_limit 500
  # An arbitrary constant that names "server ownership" among Postgres advisory locks.
  @ownership_lock_key 7_314_002_001

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  The active members of the server (not deleted, not deactivated), owners first, each with its
  presence. A scope that is not an active member gets `[]`. `unverified?` marks a member who holds
  the Unverified role, and only for a scope that holds `manage_roles`: it is false for everyone
  else.
  """
  def list_members(%Scope{} = scope) do
    if is_nil(Visibility.member(scope)) do
      []
    else
      show_unverified? = Visibility.can?(scope, :manage_roles, :server)

      active_members()
      |> preload([:avatar_asset, :membership])
      |> Repo.all()
      |> presence_entries()
      |> Enum.map(&Map.put(&1, :unverified?, show_unverified? and unverified?(&1.user)))
    end
  end

  @doc """
  The active member `user_id` with its membership and roles, or nil. A scope that is not an active
  member gets nil, and so does a banned, removed or deleted user, or an id that is not a UUID.
  """
  def get_member(%Scope{} = scope, user_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %User{} <- Visibility.member(scope) do
      active_members()
      |> where([user], user.id == ^user_id)
      |> preload([:membership, member_roles: :role])
      |> Repo.one()
    else
      _ -> nil
    end
  end

  defp active_members do
    User
    |> join(:inner, [user], membership in Membership, on: membership.user_id == user.id)
    |> where([user, membership], is_nil(user.deleted_at) and is_nil(membership.deactivated_at))
    |> order_by([_user, membership], desc: membership.is_owner, asc: membership.joined_at)
  end

  defp presence_entries(members) do
    now = DateTime.utc_now()

    active_sessions =
      members
      |> Enum.map(& &1.id)
      |> Ephemeral.get_presence_timestamps()

    Enum.map(members, fn user ->
      last_active_at =
        active_sessions[user.id] || user.membership.last_seen_at || user.inserted_at

      status = presence_status(last_active_at, now)

      %{user: user, last_active_at: last_active_at, status: status}
    end)
  end

  def get_user_by_session_token(token) when is_binary(token) do
    hashed_token = hash_token(token)
    now = DateTime.utc_now()

    user =
      User
      |> join(:inner, [user], session in UserSession, on: session.user_id == user.id)
      |> where([_user, session], session.context == "session")
      |> where([_user, session], session.token_hash == ^hashed_token)
      |> where([_user, session], is_nil(session.revoked_at) and session.expires_at > ^now)
      |> preload([user, _session], [:avatar_asset, :membership, member_roles: :role])
      |> Repo.one()

    if user do
      touch_session(token, user)
      heartbeat_presence(user)
    end

    user
  end

  def register_user(attrs, opts \\ [])

  def register_user(attrs, opts) when is_map(attrs) and is_list(opts) do
    invite_code = Keyword.get(opts, :invite_code)

    Repo.transact(fn ->
      # The ownership lock comes first, in the same order `change_ownership/3` takes it, so a
      # first registration and a concurrent ownership transfer never lock each other out.
      lock_ownership!()

      with :ok <- authorize_registration(invite_code),
           {:ok, user} <- %User{} |> User.registration_changeset(attrs) |> Repo.insert(),
           membership = create_first_membership!(user),
           {:ok, invite} <- redeem_invite(invite_code, user) do
        user = confirm_if_invite_mailed!(user, invite)

        {:ok,
         user
         |> Repo.preload([:membership, member_roles: :role])
         |> Map.put(:membership, membership)}
      end
    end)
    |> tap(fn
      {:ok, user} ->
        ProductEvents.record({:member_signed_up, user, invite_code != nil})

        # A member who registers with the address their invite was mailed to has proved they read
        # that mailbox, so they start verified (the first-verification effects run once).
        if user.confirmed_at, do: after_email_confirmed({:ok, {nil, user}})

      {:error, _reason} ->
        :ok
    end)
  end

  defp confirm_if_invite_mailed!(user, nil), do: user

  defp confirm_if_invite_mailed!(%User{} = user, invite) do
    if Invites.mailed_to?(invite, user.email),
      do: user |> Changeset.change(confirmed_at: DateTime.utc_now()) |> Repo.update!(),
      else: user
  end

  # The first human member owns the server, as the seeded welcome message says.
  defp create_first_membership!(%User{} = user) do
    membership = create_membership!(user, DateTime.utc_now())

    if owner_exists?(),
      do: membership,
      else: membership |> Membership.ownership_changeset(true) |> Repo.update!()
  end

  defp redeem_invite(nil, _user), do: {:ok, nil}
  defp redeem_invite(invite_code, user), do: Invites.redeem(invite_code, user)

  @doc """
  Promote an existing active human member to the first server owner.

  The ownership lock makes the check and promotion one decision across concurrent release
  commands. Existing owners remain owners; transfers use `promote_to_owner/2` instead.
  """
  def promote_first_owner(email) when is_binary(email) do
    Repo.transact(fn ->
      lock_ownership!()

      cond do
        owner_exists?() ->
          {:error, :owner_exists}

        true ->
          case Repo.one(
                 from user in User,
                   join: membership in Membership,
                   on: membership.user_id == user.id,
                   where:
                     user.email == ^String.downcase(email) and is_nil(user.deleted_at) and
                       user.bot == false and is_nil(membership.deactivated_at),
                   select: {user, membership}
               ) do
            {user, membership} ->
              updated_membership =
                membership
                |> Membership.ownership_changeset(true)
                |> Repo.update!()

              {:ok,
               user
               |> Repo.preload([:membership, member_roles: :role])
               |> Map.put(:membership, updated_membership)}

            nil ->
              {:error, :not_found}
          end
      end
    end)
  end

  def register_user!(attrs) do
    case register_user(attrs) do
      {:ok, user} ->
        user

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  def change_registration_user(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end

  @doc "A changeset for the reset form's validation. It does not hash the password."
  def change_password_user(%User{} = user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  def change_profile_user(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  @doc """
  Saves the profile fields a member edits on their own account, and changes their avatar as
  `avatar` says: `:keep`, `:remove`, or `{:replace, upload}` for a file consumed from a LiveView
  upload (`%{path:, client_name:}`). A file that is not a PNG, JPEG, GIF or WebP is
  `{:error, :invalid_upload_type}`.

  The row of a replaced or removed avatar goes in the same transaction; its object goes after
  the commit. Only a `:avatar` asset is deleted, so an id pointed at another kind of asset
  stays.
  """
  def update_profile_user(%User{} = user, attrs, avatar \\ :keep) do
    Repo.transact(fn -> save_profile(user, attrs, avatar) end)
    |> case do
      {:ok, {updated_user, retired_keys}} ->
        MediaAssets.delete_objects(retired_keys)

        {:ok,
         Repo.preload(updated_user, [:avatar_asset, :membership, member_roles: :role],
           force: true
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_profile(user, attrs, :keep), do: write_profile(user, attrs, :keep)
  defp save_profile(user, attrs, :remove), do: write_profile(user, attrs, {:set, nil})

  defp save_profile(user, attrs, {:replace, upload}) do
    MediaAssets.store_upload(%Scope{user_id: user.id}, upload, :avatar, fn asset ->
      write_profile(user, attrs, {:set, asset.id})
    end)
  end

  defp write_profile(user, attrs, avatar_change) do
    old_asset = user.avatar_asset_id && Repo.get(MediaAsset, user.avatar_asset_id)
    changeset = User.profile_changeset(user, attrs)

    changeset =
      case avatar_change do
        :keep -> changeset
        {:set, asset_id} -> Changeset.put_change(changeset, :avatar_asset_id, asset_id)
      end

    with {:ok, updated} <- Repo.update(changeset),
         {:ok, retired_keys} <- retire_avatar(old_asset, avatar_change) do
      {:ok, {updated, retired_keys}}
    end
  end

  defp retire_avatar(%MediaAsset{kind: :avatar} = asset, {:set, _id}),
    do: MediaAssets.delete_asset_row(asset)

  defp retire_avatar(_asset, _change), do: {:ok, []}

  def change_user_email(%User{} = user, attrs \\ %{}) do
    User.email_changeset(user, attrs)
  end

  @doc """
  Changes the email when `password` is the account's current password. A wrong or missing
  password adds an error on `:password` and writes nothing.

  While verification is active (`verification_active?/0`), the change waits for the new
  address: this mails a link to it and returns `{:ok, :confirmation_sent}`, and the email
  changes only when the link is opened (`update_user_email_from_token/1`). The account stays
  verified meanwhile. With verification inactive, or when the email does not change, it returns
  `{:ok, user}` at once. A mail that cannot be sent is an error on `:email`.
  """
  def update_user_email(%User{} = user, password, attrs) do
    changeset =
      user
      |> User.email_changeset(attrs)
      |> Changeset.unsafe_validate_unique(:email, Repo)

    cond do
      not valid_user_password?(user, password) ->
        changeset
        |> Changeset.add_error(:password, "is not correct")
        |> Changeset.apply_action(:update)

      not verification_active?() or not changeset.valid? or
          not Changeset.changed?(changeset, :email) ->
        changeset
        |> Repo.update()
        |> case do
          {:ok, updated_user} ->
            {:ok,
             Repo.preload(updated_user, [:avatar_asset, :membership, member_roles: :role],
               force: true
             )}

          {:error, changeset} ->
            {:error, changeset}
        end

      true ->
        request_email_change(user, changeset)
    end
  end

  @doc """
  Applies the email change that `token` confirms, and marks the account verified: the member
  proved they read the new address. The token is single use and works only while the account
  still has the email it was requested from. Returns `{:ok, user}`, `{:error, :invalid}` for a
  used, expired or unknown link, or `{:error, :email_taken}` when another account took the address
  in the meantime.
  """
  def update_user_email_from_token(token) when is_binary(token) do
    Repo.transact(fn ->
      case lock_email_token(token, :email_change) do
        nil ->
          {:error, :invalid}

        {row, user} ->
          delete_email_tokens!(user.id, :email_change)

          user
          |> User.email_changeset(%{email: row.sent_to})
          |> Changeset.put_change(:confirmed_at, user.confirmed_at || DateTime.utc_now())
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, {user.confirmed_at, updated}}
            {:error, _changeset} -> {:error, :email_taken}
          end
      end
    end)
    |> after_email_confirmed()
  end

  # --- Verification --------------------------------------------------------------------------

  @doc """
  Whether email verification is on. It is on exactly when mail can be sent
  (`Tavern.Mailer.configured?/0`): with no provider, nobody could verify, so nobody is
  restricted.
  """
  def verification_active?, do: Tavern.Mailer.configured?()

  @doc """
  Whether the account holds the Unverified role: verification is active, and it is a human,
  non-owner account whose email is not confirmed. Bots and owners never hold it. The role is
  derived here each time, never stored as a `member_roles` row. The account needs its membership
  loaded, or it is not known to be an owner.
  """
  def unverified?(%User{bot: true}), do: false
  def unverified?(%User{confirmed_at: %DateTime{}}), do: false
  def unverified?(%User{deleted_at: %DateTime{}}), do: false
  def unverified?(%User{} = user), do: not owner?(user) and verification_active?()

  @doc """
  Mails `user` a link that confirms their email, while verification is active and the email is
  not confirmed. Registration calls it. Returns `:ok` (also when there is nothing to send) or
  `{:error, reason}` when the mail fails.
  """
  def deliver_user_confirmation_instructions(
        %User{bot: false, confirmed_at: nil, deleted_at: nil, email: email} = user
      )
      when is_binary(email) do
    if verification_active?() do
      token = insert_email_token!(user, :confirm, email)
      VerificationMail.deliver_confirmation(email, token)
    else
      :ok
    end
  end

  def deliver_user_confirmation_instructions(%User{}), do: :ok

  @doc """
  Sends the confirmation link again for a member who holds the Unverified role, through the
  login rate limiter. Returns `:ok`, `{:error, :not_needed}` for an account that is not
  unverified, `{:error, {:rate_limited, seconds}}`, or `{:error, reason}` when the mail fails.
  """
  def resend_user_confirmation(%User{} = user) do
    with true <- unverified?(user) || {:error, :not_needed},
         :ok <- rate_limit_email_link(user) do
      deliver_user_confirmation_instructions(user)
    end
  end

  # Resends and email changes share one bucket per member: each mails a link the member asked for.
  defp rate_limit_email_link(user) do
    case LoginRateLimiter.check_email_link(user.id) do
      :ok -> :ok
      {:error, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  @doc """
  Confirms the email that `token` was sent to: sets `confirmed_at` and spends every confirmation
  link of the account. It signs nobody in or out. The link is single use, expires after
  #{@email_token_valid_days} days, and works only while the account still has the address it
  was sent to. Returns `{:ok, user}` or `{:error, :invalid}`.
  """
  def confirm_user(token) when is_binary(token) do
    Repo.transact(fn ->
      case lock_email_token(token, :confirm) do
        nil ->
          {:error, :invalid}

        {_row, user} ->
          delete_email_tokens!(user.id, :confirm)

          confirmed =
            user
            |> Changeset.change(confirmed_at: user.confirmed_at || DateTime.utc_now())
            |> Repo.update!()

          {:ok, {user.confirmed_at, confirmed}}
      end
    end)
    |> after_email_confirmed()
  end

  # After the commit: tells every open view that `user` confirmed an email (the member's own
  # views may have lost the Unverified role, and managers' member lists show a badge), and counts
  # the account verified when it had never confirmed an address before.
  defp after_email_confirmed({:ok, {previously_confirmed_at, %User{} = user}}) do
    Topics.broadcast_server({:email_confirmed, user.id})
    if is_nil(previously_confirmed_at), do: ProductEvents.record({:member_verified, user.id})
    {:ok, user}
  end

  defp after_email_confirmed(error), do: error

  defp request_email_change(%User{} = user, changeset) do
    with {:ok, draft} <- Changeset.apply_action(changeset, :update),
         :ok <- rate_limit_email_link(user) do
      # Only the latest request's link works.
      delete_email_tokens!(user.id, :email_change)
      token = insert_email_token!(user, :email_change, draft.email)

      case VerificationMail.deliver_email_change(draft.email, token) do
        :ok ->
          {:ok, :confirmation_sent}

        {:error, reason} ->
          delete_email_tokens!(user.id, :email_change)

          changeset
          |> Changeset.add_error(:email, "could not be sent the confirmation link: #{reason}")
          |> Changeset.apply_action(:update)
      end
    else
      {:error, {:rate_limited, seconds}} ->
        changeset
        |> Changeset.add_error(
          :email,
          "was sent too many links. Try again in #{div(seconds + 59, 60)} min."
        )
        |> Changeset.apply_action(:update)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Email links live in `user_sessions` beside sessions, told apart by `context`: "confirm" for a
  # verification link, "reset" for a password reset, and "change:<current email>" for an email
  # change. The change context names the address it was requested from, so a link stops working
  # once the email changes another way; confirm and reset links name it in `sent_to` for the same
  # reason.
  defp email_token_context(:confirm, _user), do: "confirm"
  defp email_token_context(:password_reset, _user), do: "reset"
  defp email_token_context(:email_change, %User{email: email}), do: "change:" <> email

  defp email_token_valid_seconds(:password_reset), do: @password_reset_valid_minutes * 60
  defp email_token_valid_seconds(_kind), do: @email_token_valid_days * 86_400

  defp insert_email_token!(%User{} = user, kind, sent_to) do
    insert_token!(&UserSession.changeset/2, %{
      user_id: user.id,
      context: email_token_context(kind, user),
      sent_to: sent_to,
      expires_at: DateTime.add(DateTime.utc_now(), email_token_valid_seconds(kind), :second)
    })
  end

  # The live token row and its account, both locked, or nil. A second use waits on the first's
  # lock and then finds the row deleted.
  defp lock_email_token(token, kind) do
    token |> live_email_token_query(kind) |> lock("FOR UPDATE") |> Repo.one()
  end

  defp live_email_token_query(token, kind) do
    now = DateTime.utc_now()

    query =
      from(session in UserSession,
        join: user in User,
        on: user.id == session.user_id,
        where: session.token_hash == ^hash_token(token) and session.expires_at > ^now,
        where: is_nil(user.deleted_at) and user.bot == false,
        select: {session, user}
      )

    case kind do
      kind when kind in [:confirm, :password_reset] ->
        context = email_token_context(kind, nil)

        where(
          query,
          [session, user],
          session.context == ^context and session.sent_to == user.email
        )

      :email_change ->
        where(query, [session, user], session.context == fragment("'change:' || ?", user.email))
    end
  end

  defp delete_email_tokens!(user_id, :confirm) do
    from(session in UserSession,
      where: session.user_id == ^user_id and session.context == "confirm"
    )
    |> Repo.delete_all()
  end

  defp delete_email_tokens!(user_id, :password_reset) do
    from(session in UserSession,
      where: session.user_id == ^user_id and session.context == "reset"
    )
    |> Repo.delete_all()
  end

  defp delete_email_tokens!(user_id, :email_change) do
    from(session in UserSession,
      where: session.user_id == ^user_id and like(session.context, "change:%")
    )
    |> Repo.delete_all()
  end

  # Every email link of the account, whatever its kind.
  defp delete_email_tokens!(user_id, :all) do
    from(session in UserSession,
      where:
        session.user_id == ^user_id and
          (session.context in ["confirm", "reset"] or like(session.context, "change:%"))
    )
    |> Repo.delete_all()
  end

  # --- Password reset ------------------------------------------------------------------------

  @doc """
  Whether a visitor can ask for a password reset link: it needs mail
  (`Tavern.Mailer.configured?/0`).
  """
  def password_reset_available?, do: Tavern.Mailer.configured?()

  @doc """
  Mails the account that owns `email` a link that sets a new password, when there is such an
  account and mail works. The caller learns nothing about the account: it gets `:ok` whether or
  not a mail was sent, so a visitor cannot tell which emails have accounts. The mail goes out in
  a background task, so the reply does not take longer for an account that exists.

  The request counts against the login limiter for `ip_address` and `email`. Past the limit it
  returns `{:error, {:rate_limited, seconds}}`, whether or not the email has an account. Each
  account also takes at most the link-mail limit (`LoginRateLimiter.check_email_link/1`), so a
  visitor cannot fill someone's mailbox; a request past it sends nothing and still returns `:ok`.

  The link works once, within #{@password_reset_valid_minutes} minutes, and a newer request
  replaces it. A bot, a deleted account and an account with no password get no mail.
  """
  def request_password_reset(email, ip_address) when is_binary(email) do
    case LoginRateLimiter.check_attempt(ip_address, email) do
      {:error, seconds} ->
        {:error, {:rate_limited, seconds}}

      :ok ->
        with true <- password_reset_available?(),
             %User{} = user <- get_resettable_user(email),
             :ok <- LoginRateLimiter.check_email_link(user.id) do
          delete_email_tokens!(user.id, :password_reset)
          token = insert_email_token!(user, :password_reset, user.email)

          {:ok, _pid} =
            Task.Supervisor.start_child(Tavern.Mailer.TaskSupervisor, fn ->
              VerificationMail.deliver_password_reset(user.email, token)
            end)
        end

        :ok
    end
  end

  defp get_resettable_user(email) do
    from(user in User,
      where: user.email == ^String.trim(email),
      where: user.bot == false and is_nil(user.deleted_at) and not is_nil(user.hashed_password)
    )
    |> Repo.one()
  end

  @doc """
  The account that a reset `token` is for, or nil when the link is used, expired or not valid.
  It changes nothing, so a page can check a link before it shows the form.
  """
  def get_user_by_password_reset_token(token) when is_binary(token) do
    case token |> live_email_token_query(:password_reset) |> Repo.one() do
      {_row, user} -> user
      nil -> nil
    end
  end

  @doc """
  Sets a new password with the reset link `token`. The password must pass the registration rules,
  or the result is `{:error, changeset}` and the link still works. On success the link and every
  other email link of the account are spent, so a confirmation or email change link mailed before
  the reset stops working, and every session of the account ends. The member signs in again with
  the new password.

  The link went to the account's current email, so opening it proves the member reads that
  mailbox: an account with no `confirmed_at` is verified in the same transaction, with the effects
  of any first verification (`after_email_confirmed/1`). An account that is already verified keeps
  its `confirmed_at`, and nothing about its verification is announced.

  Returns `{:ok, user}`, `{:error, changeset}`, or `{:error, :invalid}` for a used, expired or
  unknown link.
  """
  def reset_user_password(token, attrs) when is_binary(token) do
    Repo.transact(fn ->
      case lock_email_token(token, :password_reset) do
        nil ->
          {:error, :invalid}

        {_row, user} ->
          changeset =
            user
            |> User.password_changeset(attrs)
            |> Changeset.put_change(:confirmed_at, user.confirmed_at || DateTime.utc_now())

          with {:ok, updated} <- Repo.update(changeset) do
            delete_email_tokens!(user.id, :all)
            {:ok, {user.confirmed_at, updated}}
          end
      end
    end)
    |> case do
      {:ok, {previously_confirmed_at, user}} ->
        :ok = revoke_user_sessions(user.id)

        if is_nil(previously_confirmed_at),
          do: after_email_confirmed({:ok, {nil, user}}),
          else: {:ok, user}

      error ->
        error
    end
  end

  def dummy_login_changeset do
    User.login_changeset(%User{}, %{})
  end

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(String.downcase(email))

    if valid_user_password?(user, password),
      do: Repo.preload(user, [:avatar_asset, :membership, member_roles: :role])
  end

  def valid_user_password?(%User{hashed_password: nil}, _password) do
    Bcrypt.no_user_verify()
    false
  end

  def valid_user_password?(%User{} = user, password) when is_binary(password) do
    Bcrypt.verify_pass(password, user.hashed_password)
  end

  def valid_user_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  def generate_user_session_token(%User{} = user, attrs \\ %{}) do
    now = DateTime.utc_now()

    token =
      insert_token!(&UserSession.session_changeset/2, %{
        user_id: user.id,
        context: "session",
        expires_at: DateTime.add(now, @session_valid_days * 86_400, :second),
        last_seen_at: now,
        user_agent: Map.get(attrs, :user_agent),
        ip_address: Map.get(attrs, :ip_address)
      })

    ProductEvents.record({:session_seen, user.id})
    token
  end

  # Inserts a `user_sessions` row for a fresh random token and returns the token. The row keeps
  # only the hash, so a database leak gives no usable token.
  defp insert_token!(changeset, attrs) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %UserSession{}
    |> changeset.(Map.put(attrs, :token_hash, hash_token(token)))
    |> Repo.insert!()

    token
  end

  def delete_user_session_token(token) when is_binary(token) do
    hashed_token = hash_token(token)
    now = DateTime.utc_now()

    from(session in UserSession,
      where: session.token_hash == ^hashed_token and session.context == "session"
    )
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  @doc """
  The id of the socket topic a session's LiveViews join, derived from the stored token hash so
  the server can find the sockets of any session row. A `"disconnect"` broadcast to it closes them.
  """
  def live_socket_id(token) when is_binary(token), do: socket_id_for_hash(hash_token(token))

  @doc """
  Deletes every session of `user_id` and disconnects their open LiveViews. Run it after the
  transaction that removed the member has committed, so a reconnecting socket finds no session.
  """
  def revoke_user_sessions(user_id) do
    {_count, hashes} =
      from(session in UserSession,
        where: session.user_id == ^user_id and session.context == "session",
        select: session.token_hash
      )
      |> Repo.delete_all()

    Enum.each(hashes, fn hash ->
      TavernWeb.Endpoint.broadcast(socket_id_for_hash(hash), "disconnect", %{})
    end)

    :ok
  end

  defp socket_id_for_hash(hash), do: "users_sessions:" <> Base.url_encode64(hash, padding: false)

  @doc """
  Deletes the account `user_id`. Every deletion path (a scheduled deletion, a prune) runs it.

  The email is cleared and the username becomes a tombstone that registration never produces
  (`User.deletion_changeset/2`), so both can register again. The display name becomes
  "Deleted user", so every place that shows the account's messages shows that name. Profile
  fields and images, sessions, bot tokens, roles, channel overwrites, channel read state, thread
  follows and notification settings go, and the membership is deactivated. Messages, reactions,
  poll ballots, moderation cases and audit entries stay.

  `actor_id` names who deleted the account in the `account_deleted` audit entry. The deletion
  sweep passes none. No permission is checked here: each caller decides who may delete.

  Returns `{:ok, user}`, also for an account that is already deleted (then nothing is written),
  or `{:error, reason}`: `:not_found`, `:bot` (bots and system accounts) or `:owner`.
  """
  def delete_account(user_id, actor_id \\ nil) do
    case Ecto.UUID.cast(user_id) do
      {:ok, user_id} ->
        Repo.transact(fn -> delete_account_locked(user_id, actor_id) end)
        |> after_account_deletion(actor_id)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes each account whose scheduled deletion time (`deletion_scheduled_at` on the membership)
  is at or before `now`, at most #{@deletion_sweep_limit} per call, and returns how many it
  deleted.

  Each account is deleted in its own transaction, which takes the membership row lock and checks
  again under it that the deletion is due (`due_memberships/1`). A rejoin, a ban or a
  cancellation that commits first keeps the account, and a row another node holds is skipped, so
  nodes that sweep at the same time never delete one account twice.
  `Tavern.Accounts.DeletionSweeper` calls this.
  """
  def delete_due_accounts(%DateTime{} = now) do
    due_memberships(now)
    |> order_by([membership], asc: membership.deletion_scheduled_at)
    |> limit(@deletion_sweep_limit)
    |> select([membership], membership.user_id)
    |> Repo.all()
    |> Enum.count(&delete_if_due(&1, now))
  end

  def delete_bot_token(token) when is_binary(token) do
    hashed_token = hash_token(token)
    now = DateTime.utc_now()

    from(bot_token in BotToken, where: bot_token.token_hash == ^hashed_token)
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  def user_scope(%User{id: user_id}), do: %Scope{user_id: user_id}

  def membership_state(nil), do: :anonymous

  def membership_state(%User{membership: nil}), do: :removed

  def membership_state(%User{membership: membership}) do
    cond do
      is_nil(membership.deactivated_at) -> :active
      membership_flag?(membership, "banned") -> :banned
      true -> :removed
    end
  end

  def banned?(%User{} = user), do: membership_state(user) == :banned

  @doc "Whether the user may reach no chat page: banned, kicked, or without a membership."
  def excluded?(%User{} = user), do: membership_state(user) in [:banned, :removed]
  def removed?(%User{} = user), do: membership_state(user) == :removed

  def hash_token(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc """
  Promote the member `subject_user_id` to owner. The scope must be an active owner now, in the
  database. Returns `{:ok, membership}`, or `{:error, reason}`: `:forbidden` for a scope that is
  not an owner, `:self`, or `:not_found` for a subject with no membership.
  """
  def promote_to_owner(%Scope{} = scope, subject_user_id) do
    change_ownership(scope, subject_user_id, true)
  end

  @doc """
  Demote the owner `subject_user_id`. The scope must be an active owner now, in the database, and
  cannot demote themselves. So the actor is still an owner after every demotion, and the
  server always keeps at least one owner. Returns the same errors as `promote_to_owner/2`.
  """
  def demote_from_owner(%Scope{} = scope, subject_user_id) do
    change_ownership(scope, subject_user_id, false)
  end

  def owner?(%User{membership: %Membership{is_owner: true}}), do: true
  def owner?(_), do: false

  # Every ownership decision runs under one lock and reads memberships after taking it.
  # Without the lock, two owners who demote each other at the same time each see the
  # other as an owner, and both demotions commit.
  # The advisory lock comes first, then `Visibility.authorize_write/3` takes both membership rows
  # `FOR UPDATE` and decides that the actor is an active owner. A non-owner is `:forbidden` before
  # the self check. The subject's own state is read only after those locks are held.
  defp change_ownership(%Scope{} = scope, subject_user_id, is_owner) do
    case Ecto.UUID.cast(subject_user_id) do
      {:ok, subject_id} -> run_change_ownership(scope, subject_id, is_owner)
      :error -> {:error, :not_found}
    end
  end

  defp run_change_ownership(%Scope{user_id: actor_id} = scope, subject_id, is_owner) do
    Repo.transact(fn ->
      lock_ownership!()

      with :ok <- Visibility.authorize_write(scope, :manage_ownership, subject_id) do
        subject_membership = current_membership(subject_id)

        cond do
          actor_id == subject_id ->
            {:error, :self}

          is_nil(subject_membership) or not is_nil(subject_membership.deactivated_at) ->
            {:error, :not_found}

          subject_membership.is_owner == is_owner ->
            {:ok, subject_membership}

          true ->
            subject_membership |> Membership.ownership_changeset(is_owner) |> Repo.update()
        end
      end
    end)
  end

  @doc """
  Promotes the oldest active human member to owner when no owner exists.

  Bootstrap runs this on every release, so a server whose members registered before
  ownership became automatic still gets its owner. Returns `{:ok, user}` when a member
  was promoted, or `{:ok, :none}` when an owner already exists or no member qualifies.
  """
  def ensure_first_owner! do
    Repo.transact(fn ->
      lock_ownership!()

      if owner_exists?() do
        {:ok, :none}
      else
        case oldest_active_human_membership() do
          nil ->
            {:ok, :none}

          membership ->
            promoted =
              membership
              |> Membership.ownership_changeset(true)
              |> Repo.update!()

            {:ok, Repo.get!(User, promoted.user_id)}
        end
      end
    end)
  end

  defp oldest_active_human_membership do
    from(membership in Membership,
      join: user in User,
      on: user.id == membership.user_id,
      where: is_nil(user.deleted_at) and user.bot == false and is_nil(membership.deactivated_at),
      order_by: [asc: membership.joined_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp current_membership(user_id), do: Repo.get_by(Membership, user_id: user_id)

  # A transaction-scoped Postgres advisory lock: it is released at commit or rollback.
  defp lock_ownership! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@ownership_lock_key])
  end

  # The registration mode is decided here, from the settings row locked `FOR SHARE`, so a mode
  # change (which takes the row `FOR UPDATE`) and a registration serialize. A server with no owner
  # lets its first registration through, so a fresh invite-only server can still get an owner.
  defp authorize_registration(invite_code) do
    mode =
      ServerSettings
      |> lock("FOR SHARE")
      |> select([settings], settings.registration_mode)
      |> Repo.one()

    if mode == :invite_only and is_nil(invite_code) and owner_exists?(),
      do: {:error, :invite_required},
      else: :ok
  end

  defp create_membership!(%User{} = user, now) do
    %Membership{user_id: user.id, is_owner: false}
    |> Membership.join_changeset(now)
    |> Repo.insert!()
  end

  defp owner_exists? do
    Repo.exists?(
      from membership in Membership,
        where: membership.is_owner == true and is_nil(membership.deactivated_at)
    )
  end

  # Stamps the session's last use at most once per 5 minutes. Each stamp, like each new session,
  # is a `session.seen` product event: the member had Tavern open.
  defp touch_session(token, %User{id: user_id}) do
    hashed_token = hash_token(token)
    threshold = DateTime.add(DateTime.utc_now(), -300, :second)

    from(session in UserSession,
      where: session.token_hash == ^hashed_token,
      where: is_nil(session.last_seen_at) or session.last_seen_at < ^threshold
    )
    |> Repo.update_all(set: [last_seen_at: DateTime.utc_now()])
    |> case do
      {0, _rows} -> :ok
      {_stamped, _rows} -> ProductEvents.record({:session_seen, user_id})
    end
  end

  defp heartbeat_presence(%User{id: user_id}) do
    _ = Ephemeral.heartbeat_presence(user_id)
    :ok
  end

  defp presence_status(last_active_at, now) do
    cond do
      is_nil(last_active_at) -> :offline
      DateTime.diff(now, last_active_at, :second) <= 300 -> :online
      DateTime.diff(now, last_active_at, :second) <= 3_600 -> :recent
      true -> :offline
    end
  end

  # The memberships whose account deletion is due at `now`: the date has passed, the member is
  # still deactivated, and not banned. A ban clears the date (`Chat.ban_member/3`); the ban check
  # is a second guard, because deleting a banned account would free its email.
  defp due_memberships(now) do
    from(membership in Membership,
      where:
        membership.deletion_scheduled_at <= ^now and not is_nil(membership.deactivated_at) and
          fragment("coalesce(?->>'banned', 'false') <> 'true'", membership.flags)
    )
  end

  defp delete_if_due(user_id, now) do
    Repo.transact(fn ->
      due =
        due_memberships(now)
        |> where([membership], membership.user_id == ^user_id)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> select([membership], membership.id)
        |> Repo.one()

      if due, do: delete_account_locked(user_id, nil), else: {:error, :not_due}
    end)
    |> after_account_deletion(nil)
    |> case do
      {:ok, _user} -> true
      {:error, _reason} -> false
    end
  end

  # Runs inside a transaction. The membership row is locked before the user row, the order every
  # deletion path takes, so a sweep and a direct deletion of one account wait for each other
  # instead of deadlocking. The account's state is read under those locks.
  defp delete_account_locked(user_id, actor_id) do
    membership =
      from(membership in Membership, where: membership.user_id == ^user_id, lock: "FOR UPDATE")
      |> Repo.one()

    user = from(user in User, where: user.id == ^user_id, lock: "FOR UPDATE") |> Repo.one()

    cond do
      is_nil(user) -> {:error, :not_found}
      user.bot or user.system -> {:error, :bot}
      not is_nil(user.deleted_at) -> {:ok, {user, :already_deleted}}
      membership && membership.is_owner -> {:error, :owner}
      true -> {:ok, wipe_account!(user, membership, actor_id)}
    end
  end

  defp wipe_account!(%User{} = user, membership, actor_id) do
    now = DateTime.utc_now()

    asset_ids =
      Enum.reject(
        [
          user.avatar_asset_id,
          user.banner_asset_id,
          membership && membership.server_avatar_asset_id
        ],
        &is_nil/1
      )

    if membership, do: membership |> Membership.deleted_account_changeset(now) |> Repo.update!()

    deleted_user = user |> User.deletion_changeset(now) |> Repo.update!()

    for schema <- [
          MemberRole,
          ChannelMembership,
          ChannelPermissionOverwrite,
          ChannelNotificationOverride,
          UserNotificationSetting,
          ThreadFollower,
          BotToken
        ] do
      Repo.delete_all(from(row in schema, where: row.user_id == ^user.id))
    end

    {_count, session_hashes} =
      from(session in UserSession,
        where: session.user_id == ^user.id,
        select: session.token_hash
      )
      |> Repo.delete_all()

    {_count, storage_keys} =
      from(asset in MediaAsset, where: asset.id in ^asset_ids, select: asset.storage_key)
      |> Repo.delete_all()

    AuditLog.record!(actor_id, "account_deleted", user.id, {"user", user.id})

    {deleted_user, %{session_hashes: session_hashes, storage_keys: storage_keys}}
  end

  # After the deletion commits: open LiveViews of the account disconnect (a reconnect finds no
  # session), its profile images leave the object store, and the deletion is a product event.
  # An account that was already deleted had nothing written.
  defp after_account_deletion({:ok, {user, :already_deleted}}, _actor_id), do: {:ok, user}

  defp after_account_deletion({:ok, {user, cleanup}}, actor_id) do
    Enum.each(cleanup.session_hashes, fn hash ->
      TavernWeb.Endpoint.broadcast(socket_id_for_hash(hash), "disconnect", %{})
    end)

    MediaAssets.delete_objects(cleanup.storage_keys)

    ProductEvents.record({:member_deleted, user.id, actor_id})
    {:ok, user}
  end

  defp after_account_deletion({:error, reason}, _actor_id), do: {:error, reason}

  defp membership_flag?(membership, key) do
    flags = membership.flags || %{}

    case Map.get(flags, key) do
      true -> true
      "true" -> true
      _ -> false
    end
  end
end
