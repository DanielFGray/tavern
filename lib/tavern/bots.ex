defmodule Tavern.Bots do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Tavern.Accounts
  alias Tavern.Accounts.Scope
  alias Tavern.Bots.Authority
  alias Tavern.Bots.Commands
  alias Tavern.Bots.Serializer
  alias Tavern.Chat
  alias Tavern.Chat.AuditLog
  alias Tavern.Chat.BotToken
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Ids
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Role
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @touch_threshold_seconds 300

  # What a bot management view shows for each bot.
  @bot_preloads [:membership, :bot_tokens, member_roles: :role]

  def command_registry, do: Commands.command_registry()

  @doc "The bots the scope may control. Empty when it may not manage bots."
  def list_controllable_bot_users(%Scope{} = scope) do
    case Authority.manage_bots(scope) do
      {:ok, authority} ->
        bot_users_query()
        |> order_by([user], asc: user.display_name, asc: user.username)
        |> preload(^@bot_preloads)
        |> Repo.all()
        |> Enum.filter(&(Authority.control_bot(authority, &1) == :ok))

      {:error, :forbidden} ->
        []
    end
  end

  @doc "Every role the scope may give a bot; empty when it may not manage bots."
  def grantable_roles(%Scope{} = scope) do
    case Authority.manage_bots(scope) do
      {:ok, authority} -> Authority.grantable_roles(authority)
      {:error, :forbidden} -> []
    end
  end

  @doc """
  Creates a bot with the roles in `role_ids`. The scope must manage bots, and needs
  manage_roles plus authority over each role (see `Tavern.Bots.Authority`). Decides and writes
  in one transaction under the role-list lock (see `with_role_authority/2`).
  """
  def create_bot(%Scope{} = scope, attrs) when is_map(attrs) do
    role_ids = Map.get(attrs, "role_ids") || Map.get(attrs, :role_ids) || []

    with_role_authority(scope, fn authority ->
      with {:ok, roles} <- Authority.grant_roles(authority, role_ids) do
        insert_bot(scope, attrs, roles)
      end
    end)
  end

  defp insert_bot(scope, attrs, roles) do
    now = DateTime.utc_now()

    with {:ok, bot_user} <-
           %User{bot: true, system: false}
           |> User.account_changeset(%{
             username: Map.get(attrs, "username") || Map.get(attrs, :username),
             display_name: Map.get(attrs, "display_name") || Map.get(attrs, :display_name),
             email: Map.get(attrs, "email") || Map.get(attrs, :email),
             bio: Map.get(attrs, "bio") || Map.get(attrs, :bio)
           })
           |> Repo.insert() do
      membership =
        %Membership{user_id: bot_user.id}
        |> Membership.join_changeset(now)
        |> Repo.insert!()

      assign_roles!(scope, bot_user, roles)

      AuditLog.record!(scope.user_id, "bot_created", bot_user.id, {"bot", bot_user.id},
        metadata: %{"role_ids" => role_ids(roles)}
      )

      {:ok,
       bot_user
       |> Repo.preload(@bot_preloads)
       |> Map.put(:membership, membership)}
    end
  end

  @doc """
  Updates the profile of bot `bot_id`. When `attrs` carries `role_ids`, they replace the bot's
  roles under the same rules as `create_bot/2`; without it, the roles stay as they are.
  """
  def update_bot(%Scope{} = scope, bot_id, attrs) when is_map(attrs) do
    with_controlled_bot(scope, bot_id, fn authority, bot_user ->
      with {:ok, roles} <- roles_for_update(authority, attrs) do
        save_bot(scope, bot_user, attrs, roles)
      end
    end)
  end

  # A bot grant compares role positions, and a role write may renumber every position. So the
  # grant takes the role-list lock first, then the actor's membership row, then loads the actor's
  # authority, and decides and writes `member_roles` in that one transaction, as
  # `Tavern.Chat.Roles` does. Every bot write runs here, so control of a bot is decided from the
  # same current positions.
  #
  # A write that changes another member's membership row passes that member's id in `member_ids`;
  # the actor's row and those rows are then taken `FOR UPDATE` in user id order, the order every
  # multi-row membership write uses (`Visibility.lock_memberships!/1`).
  defp with_role_authority(scope, member_ids \\ [], fun) do
    Repo.transact(fn ->
      Visibility.lock_role_list!()
      if member_ids != [], do: Visibility.lock_memberships!([scope.user_id | member_ids])

      with :ok <- Visibility.authorize_write(scope, :manage_bots, :server),
           {:ok, authority} <- Authority.manage_bots(scope) do
        fun.(authority)
      end
    end)
  end

  # Runs `fun` with the authority and bot `bot_id`, locked, when the scope may control that bot.
  # A missing bot is `{:error, :not_found}`; one the scope may not control is `{:error, :forbidden}`.
  defp with_controlled_bot(scope, bot_id, fun, opts \\ []) do
    member_ids =
      with true <- Keyword.get(opts, :lock_membership, false),
           {:ok, bot_id} <- Ids.cast(bot_id) do
        [bot_id]
      else
        _ -> []
      end

    with_role_authority(scope, member_ids, fn authority ->
      with {:ok, bot_user} <- lock_bot_user(bot_id),
           :ok <- Authority.control_bot(authority, bot_user) do
        fun.(authority, bot_user)
      end
    end)
  end

  defp roles_for_update(authority, attrs) do
    with :error <- Map.fetch(attrs, "role_ids"),
         :error <- Map.fetch(attrs, :role_ids) do
      {:ok, :keep}
    else
      {:ok, ids} -> Authority.grant_roles(authority, ids || [])
    end
  end

  defp save_bot(scope, bot_user, attrs, roles) do
    with {:ok, updated_bot} <-
           bot_user
           |> User.account_changeset(%{
             username: Map.get(attrs, "username", bot_user.username),
             display_name: Map.get(attrs, "display_name", bot_user.display_name),
             email: Map.get(attrs, "email", bot_user.email),
             bio: Map.get(attrs, "bio", bot_user.bio)
           })
           |> Repo.update() do
      metadata =
        if roles == :keep do
          %{}
        else
          replace_roles!(scope, updated_bot, roles)
          %{"role_ids" => role_ids(roles)}
        end

      AuditLog.record!(scope.user_id, "bot_updated", updated_bot.id, {"bot", updated_bot.id},
        metadata: metadata
      )

      {:ok, Repo.preload(updated_bot, @bot_preloads, force: true)}
    end
  end

  @doc """
  Deactivates bot `bot_id`: revokes its tokens, deactivates its membership and deletes the bot
  user. Needs control of the bot, decided as `update_bot/3` does.
  """
  def revoke_bot(%Scope{} = scope, bot_id) do
    with_controlled_bot(
      scope,
      bot_id,
      fn _authority, bot_user -> {:ok, deactivate_bot!(scope, bot_user)} end,
      lock_membership: true
    )
  end

  defp deactivate_bot!(scope, bot_user) do
    now = DateTime.utc_now()

    from(token in BotToken, where: token.user_id == ^bot_user.id)
    |> Repo.update_all(set: [revoked_at: now])

    if bot_user.membership do
      bot_user.membership
      |> Membership.deactivate_changeset(now, %{"bot_revoked" => true})
      |> Repo.update!()
    end

    revoked_bot =
      bot_user
      |> Ecto.Changeset.change(deleted_at: now)
      |> Repo.update!()

    AuditLog.record!(scope.user_id, "bot_revoked", revoked_bot.id, {"bot", revoked_bot.id})
    Repo.preload(revoked_bot, @bot_preloads, force: true)
  end

  @doc """
  The tokens of the bot `bot_id`, newest first, when the scope may control that bot. A missing
  bot and a bot the scope cannot control both return `{:error, :not_found}`, so the caller cannot
  tell them apart.
  """
  def list_controllable_bot_tokens(%Scope{} = scope, bot_id) do
    with {:ok, bot_user} <- fetch_bot_user(bot_id),
         {:ok, authority} <- Authority.manage_bots(scope),
         :ok <- Authority.control_bot(authority, bot_user) do
      {:ok,
       BotToken
       |> where([token], token.user_id == ^bot_user.id)
       |> order_by([token], desc: token.inserted_at)
       |> Repo.all()}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Mints a token for bot `bot_id`. Needs control of the bot, decided as `update_bot/3` does.
  Returns `%{token: plaintext, bot_token: row, bot: bot_user}`; the plaintext is never stored.
  """
  def create_bot_token(%Scope{} = scope, bot_id, attrs) when is_map(attrs) do
    with_controlled_bot(scope, bot_id, fn _authority, bot_user ->
      insert_bot_token(scope, bot_user, attrs)
    end)
  end

  defp insert_bot_token(scope, bot_user, attrs) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    with {:ok, expires_at} <- expires_at_from_attrs(attrs, now),
         {:ok, bot_token} <-
           %BotToken{}
           |> BotToken.changeset(%{
             user_id: bot_user.id,
             token_hash: Accounts.hash_token(token),
             label: Map.get(attrs, "label") || Map.get(attrs, :label),
             last_used_at: nil,
             expires_at: expires_at
           })
           |> Repo.insert() do
      AuditLog.record!(scope.user_id, "bot_token_created", bot_user.id, {"bot", bot_user.id},
        metadata: %{"token_id" => bot_token.id}
      )

      {:ok, %{token: token, bot_token: bot_token, bot: bot_user}}
    end
  end

  @doc """
  Revokes token `token_id`. Needs control of its bot, decided as `update_bot/3` does, before the
  token is read: a scope without manage_bots gets `{:error, :forbidden}` for any id. A missing
  token, or a token whose bot was deleted, is `{:error, :not_found}`.
  """
  def revoke_bot_token(%Scope{} = scope, token_id) do
    with_role_authority(scope, fn authority ->
      with {:ok, bot_token} <- fetch_bot_token(token_id),
           {:ok, bot_user} <- lock_bot_user(bot_token.user_id),
           :ok <- Authority.control_bot(authority, bot_user),
           {:ok, revoked_token} <-
             bot_token
             |> BotToken.changeset(%{revoked_at: DateTime.utc_now()})
             |> Repo.update() do
        AuditLog.record!(scope.user_id, "bot_token_revoked", bot_user.id, {"bot", bot_user.id},
          metadata: %{"token_id" => revoked_token.id}
        )

        {:ok, revoked_token}
      end
    end)
  end

  # A token's bot never changes, so the row is read unlocked and its bot is locked next, in the
  # same order as every other bot write; the update then takes the token's row lock.
  defp fetch_bot_token(token_id) do
    with {:ok, token_id} <- Ids.cast(token_id),
         %BotToken{} = bot_token <- Repo.get(BotToken, token_id) do
      {:ok, bot_token}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_bot_scope_by_token(token) when is_binary(token) do
    hashed_token = Accounts.hash_token(token)
    now = DateTime.utc_now()

    bot_token =
      BotToken
      |> join(:inner, [token], user in assoc(token, :user))
      |> where([token, user], token.token_hash == ^hashed_token)
      |> where([token, user], is_nil(token.revoked_at))
      |> where([token, user], is_nil(token.expires_at) or token.expires_at > ^now)
      |> where(
        [token, user],
        user.bot == true and user.system == false and is_nil(user.deleted_at)
      )
      |> Repo.one()

    # A valid token whose bot is deactivated cannot act, so it is refused here like any bad token.
    scope = bot_token && %Scope{user_id: bot_token.user_id, bot_token_id: bot_token.id}

    if scope && Visibility.member(scope) do
      touch_bot_token(bot_token)
      {:ok, scope}
    else
      {:error, :unauthorized}
    end
  end

  def can_manage_bots?(%Scope{} = scope), do: Visibility.can?(scope, :manage_bots, :server)

  def can_manage_bots?(_), do: false

  def execute_command(command_name, %Scope{} = scope, params) when is_map(params) do
    Commands.execute(command_name, scope, params)
  end

  def command_send_message(%Scope{} = scope, params), do: Commands.send_message(scope, params)

  def command_send_message(_, _), do: {:error, :invalid_params}

  def command_list_messages(%Scope{} = scope, params),
    do: Commands.list_messages(scope, params)

  def command_list_messages(_, _), do: {:error, :invalid_params}

  def command_edit_message(%Scope{} = scope, params), do: Commands.edit_message(scope, params)

  def command_edit_message(_, _), do: {:error, :invalid_params}

  def command_typing(%Scope{} = scope, params), do: Commands.typing(scope, params)

  def command_typing(_, _), do: {:error, :invalid_params}

  def get_thread_for_starter_message(%Scope{} = scope, starter_message_id) do
    case Ecto.UUID.cast(starter_message_id) do
      {:ok, starter_id} ->
        case Chat.get_thread_for_starter_message(scope, starter_id) do
          %Channel{} = thread -> {:ok, %{thread: Serializer.serialize_thread(thread)}}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def get_thread_for_starter_message(_, _), do: {:error, :invalid_params}

  def create_public_thread(scope, starter_message_id, attrs \\ %{})

  def create_public_thread(%Scope{} = scope, starter_message_id, attrs) when is_map(attrs) do
    with {:ok, _bot_user} <- acting_member(scope) do
      case Chat.create_public_thread(scope, starter_message_id, attrs) do
        {:ok, thread} -> {:ok, %{thread: Serializer.serialize_thread(thread)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_public_thread(_, _, _), do: {:error, :invalid_params}

  @doc """
  Sends a poll as the acting bot (`Tavern.Chat.Polls.create_poll/3`). The bot sets every option
  label, and may narrow the voters and close the poll after N votes: an agent question is a poll
  with one named voter and `max_voters: 1`. Returns `{:ok, %{message: serialized}}`.
  """
  def create_poll(%Scope{} = scope, channel_id, attrs) when is_map(attrs) do
    with {:ok, _bot_user} <- acting_member(scope),
         {:ok, message} <- Chat.create_poll(scope, channel_id, attrs) do
      {:ok, %{message: Serializer.serialize_message(message)}}
    end
  end

  def create_poll(_, _, _), do: {:error, :invalid_params}

  @doc "The message `message_id`, serialized, when the bot may view its channel."
  def get_message(%Scope{} = scope, message_id) do
    case Chat.get_message(scope, message_id) do
      %Tavern.Chat.Message{} = message ->
        {:ok, %{message: Serializer.serialize_message(message)}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "The poll message `message_id` with its results, when the bot may view it."
  def get_poll(%Scope{} = scope, message_id) do
    case Chat.get_message(scope, message_id) do
      %{poll: %Tavern.Chat.Poll{}} = message ->
        {:ok, %{message: Serializer.serialize_message(message)}}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Ends the poll on `message_id` (`Tavern.Chat.Polls.close_poll/2`)."
  def close_poll(%Scope{} = scope, message_id) do
    with {:ok, _bot_user} <- acting_member(scope),
         {:ok, message} <- Chat.close_poll(scope, message_id) do
      {:ok, %{message: Serializer.serialize_message(message)}}
    end
  end

  def command_timeout_member(%Scope{} = scope, params),
    do: Commands.timeout_member(scope, params)

  def command_timeout_member(_, _), do: {:error, :invalid_params}

  def command_kick_member(%Scope{} = scope, params), do: Commands.kick_member(scope, params)

  def command_kick_member(_, _), do: {:error, :invalid_params}

  def command_ban_member(%Scope{} = scope, params), do: Commands.ban_member(scope, params)

  def command_ban_member(_, _), do: {:error, :invalid_params}

  @doc """
  The member a bot scope acts as, for the context calls that still take a `%User{}`. A revoked
  or expired token yields `{:error, :unauthorized}`.
  """
  def acting_member(%Scope{} = scope) do
    case Visibility.member(scope) do
      %User{} = bot_user -> {:ok, bot_user}
      nil -> {:error, :unauthorized}
    end
  end

  def serialize_bot_user(%User{} = bot_user), do: Serializer.serialize_bot_user(bot_user)

  @doc "A visible active member with their role ids, or nil."
  def get_member(%Scope{} = scope, user_id) do
    case Chat.member_with_roles(scope, user_id) do
      nil -> nil
      %{user: user, roles: roles} -> Serializer.serialize_member(user, roles)
    end
  end

  def serialize_message(message), do: Serializer.serialize_message(message)

  def serialize_reaction(message, reaction), do: Serializer.serialize_reaction(message, reaction)

  def serialize_thread(thread), do: Serializer.serialize_thread(thread)

  def serialize_poll_vote(message, vote), do: Serializer.serialize_poll_vote(message, vote)

  def serialize_poll_closed(message, reason),
    do: Serializer.serialize_poll_closed(message, reason)

  # A bot that is not deleted and not the system user, or `{:error, :not_found}`. A value that is
  # not a UUID is not found, not an error.
  defp fetch_bot_user(bot_id) do
    with {:ok, bot_id} <- Ids.cast(bot_id),
         %User{} = bot_user <- bot_users_query() |> preload(^@bot_preloads) |> Repo.get(bot_id) do
      {:ok, bot_user}
    else
      _ -> {:error, :not_found}
    end
  end

  # As `fetch_bot_user/1`, with the bot's user row locked `FOR UPDATE`, after the actor's locks, so
  # two writes to one bot (a token mint and a revoke) run one after the other.
  defp lock_bot_user(bot_id) do
    with {:ok, bot_id} <- Ids.cast(bot_id),
         %User{} = bot_user <-
           bot_users_query()
           |> where([user], user.id == ^bot_id)
           |> lock("FOR UPDATE")
           |> preload(^@bot_preloads)
           |> Repo.one() do
      {:ok, bot_user}
    else
      _ -> {:error, :not_found}
    end
  end

  defp assign_roles!(%Scope{} = scope, %User{} = bot_user, roles) do
    Enum.each(roles, fn %Role{id: role_id} ->
      %MemberRole{}
      |> MemberRole.changeset(%{
        user_id: bot_user.id,
        role_id: role_id,
        granted_by_user_id: scope.user_id
      })
      |> Repo.insert!()
    end)
  end

  defp replace_roles!(%Scope{} = scope, %User{} = bot_user, roles) do
    from(member_role in MemberRole, where: member_role.user_id == ^bot_user.id)
    |> Repo.delete_all()

    assign_roles!(scope, bot_user, roles)
  end

  defp role_ids(roles), do: Enum.map(roles, & &1.id)

  defp touch_bot_token(%BotToken{id: id}) do
    threshold = DateTime.add(DateTime.utc_now(), -@touch_threshold_seconds, :second)

    from(token in BotToken,
      where: token.id == ^id,
      where: is_nil(token.last_used_at) or token.last_used_at < ^threshold
    )
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])
  end

  # Only the `expires_in_days` key is read. Absent or blank means the token never expires.
  # Ecto's integer cast accepts a JSON integer and a form string such as "30"; the settings
  # form posts "" when the field is left blank. Any other value is a changeset error, so a
  # bad value can never mint a token that does not expire.
  defp expires_at_from_attrs(attrs, now) do
    {%{}, %{expires_in_days: :integer}}
    |> Ecto.Changeset.cast(Map.take(attrs, ["expires_in_days"]), [:expires_in_days])
    |> Ecto.Changeset.validate_number(:expires_in_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 365
    )
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, data} ->
        case Map.get(data, :expires_in_days) do
          nil -> {:ok, nil}
          days -> {:ok, DateTime.add(now, days * 86_400, :second)}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Bootstrap creates the system user with bot: true, but it is the server's own actor: no
  # member may list it, manage it or hold a token for it.
  defp bot_users_query do
    where(User, [user], user.bot == true and user.system == false and is_nil(user.deleted_at))
  end
end
