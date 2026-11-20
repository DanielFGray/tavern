defmodule Tavern.Chat.Moderation do
  @moduledoc """
  Moderation of members: timeout, kick, ban, unban, rejoin with an invite, and scheduled account
  deletion. Every write goes through `moderate/4` (or `rejoin_with_invite/2`), records a
  moderation case where the action has one and an audit entry, and runs in one transaction under
  the membership row locks.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts
  alias Tavern.Accounts.DeletionNotice
  alias Tavern.Accounts.Scope
  alias Tavern.Chat.AuditLog
  alias Tavern.Chat.Ids
  alias Tavern.Chat.Invites
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.Membership
  alias Tavern.Chat.ModerationCase
  alias Tavern.Chat.Topics
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.ProductEvents
  alias Tavern.Repo

  # How long a member kicked by `kick_member_and_schedule_deletion/3` has to rejoin.
  @deletion_grace_days 30

  def change_moderation_action(attrs \\ %{}) do
    {%{}, %{reason: :string, duration_minutes: :integer, action: :string}}
    |> Ecto.Changeset.cast(attrs, [:reason, :duration_minutes, :action])
  end

  @doc """
  The moderation cases against `subject_user_id`, newest first. A scope without `view_audit_log`
  gets `{:error, :forbidden}`.
  """
  def list_moderation_cases(%Scope{} = scope, subject_user_id) do
    if Visibility.can?(scope, :view_audit_log, :server) do
      with {:ok, subject_user_id} <- Ids.cast(subject_user_id) do
        cases =
          ModerationCase
          |> where([moderation_case], moderation_case.subject_user_id == ^subject_user_id)
          |> order_by([moderation_case], desc: moderation_case.inserted_at)
          |> preload([:actor_user, :subject_user])
          |> Repo.all()

        {:ok, cases}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Times out the member `subject_user_id` and records the case and the audit entry. Returns
  `{:ok, subject, moderation_case}`; see `moderate/4` for the refusals.
  """
  def timeout_member(%Scope{} = scope, subject_user_id, duration_minutes, reason \\ nil)
      when is_integer(duration_minutes) and duration_minutes > 0 do
    moderate(scope, subject_user_id, :moderate_members, fn membership, subject_id ->
      timeout_until = DateTime.add(DateTime.utc_now(), duration_minutes * 60, :second)

      membership = Repo.update!(Membership.timeout_changeset(membership, timeout_until))

      moderation_case =
        record_moderation_case(scope.user_id, subject_id, :timeout, reason,
          expires_at: timeout_until,
          executed_at: DateTime.utc_now(),
          details: %{"duration_minutes" => duration_minutes}
        )

      AuditLog.record!(scope.user_id, "timeout_member", subject_id, {"user", subject_id},
        reason: reason,
        metadata: %{"duration_minutes" => duration_minutes, "timeout_until" => timeout_until}
      )

      {membership, moderation_case}
    end)
  end

  @doc "Removes the member `subject_user_id` from the server. Returns `{:ok, subject, moderation_case}`."
  def kick_member(%Scope{} = scope, subject_user_id, reason \\ nil) do
    deactivate_member(scope, subject_user_id, :kick_members, fn membership, subject_id ->
      remove_membership!(scope, membership, subject_id, :kick, reason, %{"kicked" => true})
    end)
  end

  @doc """
  Kicks the member `subject_user_id` as `kick_member/3` does, and schedules the deletion of their
  account #{@deletion_grace_days} days from now, unless they rejoin with an invite first
  (`rejoin_with_invite/2`) or a moderator cancels it (`cancel_account_deletion/2`).
  `Tavern.Accounts.delete_due_accounts/1` runs the deletion. Writes the kick case, the
  `kick_member` audit entry and an `account_deletion_scheduled` entry. When mail is configured, it
  mails the member the date after the commit.

  Returns `{:ok, subject, moderation_case}`. A bot or the system account is `{:error, :forbidden}`:
  a bot is revoked, never deleted. See `moderate/4` for the other refusals.
  """
  def kick_member_and_schedule_deletion(%Scope{} = scope, subject_user_id, reason \\ nil) do
    deletion_at = DateTime.add(DateTime.utc_now(), @deletion_grace_days, :day)

    deactivate_member(scope, subject_user_id, :kick_members, fn membership, subject_id ->
      case Repo.get!(User, subject_id) do
        %User{bot: false, system: false} ->
          {membership, moderation_case} =
            remove_membership!(scope, membership, subject_id, :kick, reason, %{"kicked" => true})

          membership = membership |> Membership.deletion_changeset(deletion_at) |> Repo.update!()

          AuditLog.record!(
            scope.user_id,
            "account_deletion_scheduled",
            subject_id,
            {"user", subject_id},
            reason: reason,
            metadata: %{"deletion_scheduled_at" => deletion_at}
          )

          {membership, moderation_case}

        %User{} ->
          {:error, :forbidden}
      end
    end)
    |> tap(fn
      {:ok, subject, _moderation_case} ->
        ProductEvents.record({:member_deletion_scheduled, scope.user_id, subject.id})
        DeletionNotice.deliver(subject, deletion_at)

      {:error, _reason} ->
        :ok
    end)
  end

  @doc """
  The kicked members whose account deletion is scheduled, soonest first, for a scope with
  `kick_members`; any other scope gets `{:error, :forbidden}`. Each entry is
  `%{user: user, deletion_scheduled_at: datetime}`.
  """
  def list_scheduled_deletions(%Scope{} = scope) do
    if Visibility.can?(scope, :kick_members, :server) do
      {:ok,
       from(user in User,
         join: membership in Membership,
         on: membership.user_id == user.id,
         where: not is_nil(membership.deletion_scheduled_at),
         order_by: [asc: membership.deletion_scheduled_at],
         select: %{user: user, deletion_scheduled_at: membership.deletion_scheduled_at}
       )
       |> Repo.all()}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Cancels the scheduled deletion of `subject_user_id`'s account, for a scope with `kick_members`.
  The member stays kicked. Writes an `account_deletion_canceled` audit entry. Returns
  `{:ok, membership}`; `{:error, :forbidden}` for a scope without the permission, and
  `{:error, :not_found}` when no deletion is scheduled.
  """
  def cancel_account_deletion(%Scope{} = scope, subject_user_id) do
    with {:ok, subject_id} <- Ids.cast(subject_user_id),
         true <- Visibility.can?(scope, :kick_members, :server) || {:error, :forbidden} do
      Repo.transact(fn ->
        case lock_membership(subject_id) do
          %Membership{deletion_scheduled_at: %DateTime{}} = membership ->
            {:ok, cancel_scheduled_deletion!(membership, scope.user_id)}

          _none ->
            {:error, :not_found}
        end
      end)
    end
  end

  @doc """
  Bans the member `subject_user_id`. A scheduled account deletion is canceled, with an
  `account_deletion_canceled` audit entry naming the moderator: a banned account is never deleted
  automatically, since deleting it would free its email for a new registration. Returns
  `{:ok, subject, moderation_case}`.
  """
  def ban_member(%Scope{} = scope, subject_user_id, reason \\ nil) do
    deactivate_member(scope, subject_user_id, :ban_members, fn membership, subject_id ->
      {banned, moderation_case} =
        remove_membership!(scope, membership, subject_id, :ban, reason, %{
          "banned" => true,
          "ban_reason" => reason
        })

      {cancel_scheduled_deletion!(banned, scope.user_id), moderation_case}
    end)
  end

  @doc """
  The banned members, newest ban first, for a scope with `ban_members`; any other scope gets
  `{:error, :forbidden}`. `ban_members` is the right to lift a ban, so it is also the right to
  read the list the unban button belongs to. `view_audit_log` alone does not open it.

  Each entry is `%{user: user, reason: reason, banned_at: datetime, moderator: user | nil}`; the
  reason and the moderator come from the member's latest `:ban` case.
  """
  def list_bans(%Scope{} = scope) do
    if Visibility.can?(scope, :ban_members, :server) do
      banned =
        from(user in User,
          join: membership in Membership,
          on: membership.user_id == user.id,
          where:
            not is_nil(membership.deactivated_at) and
              fragment("?->>'banned' = 'true'", membership.flags),
          order_by: [desc: membership.deactivated_at],
          select: {user, membership.deactivated_at}
        )
        |> Repo.all()

      ids = Enum.map(banned, fn {user, _banned_at} -> user.id end)

      # Oldest first, so `Map.new/2` keeps each member's latest case.
      cases =
        from(moderation_case in ModerationCase,
          where: moderation_case.action_type == :ban and moderation_case.subject_user_id in ^ids,
          order_by: [asc: moderation_case.inserted_at],
          preload: :actor_user
        )
        |> Repo.all()
        |> Map.new(&{&1.subject_user_id, &1})

      {:ok,
       for {user, banned_at} <- banned do
         moderation_case = Map.get(cases, user.id)

         %{
           user: user,
           banned_at: banned_at,
           reason: moderation_case && moderation_case.reason,
           moderator: moderation_case && moderation_case.actor_user
         }
       end}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Lifts the ban on `subject_user_id`. The member is active again with the default role only: the
  roles they held when banned are dropped, not restored. Records an `:unban` case, marks the ban
  case revoked, and broadcasts `:roles_changed`. Returns `{:ok, subject, moderation_case}`; a
  member who is not banned (or has no membership) is `{:error, :not_found}`, and the moderation
  rules of `ban_member/3` apply.
  """
  def unban_member(%Scope{} = scope, subject_user_id, reason \\ nil) do
    moderate(scope, subject_user_id, :ban_members, fn membership, subject_id ->
      if banned_membership?(membership) do
        now = DateTime.utc_now()

        from(member_role in MemberRole, where: member_role.user_id == ^subject_id)
        |> Repo.delete_all()

        from(moderation_case in ModerationCase,
          where:
            moderation_case.subject_user_id == ^subject_id and
              moderation_case.action_type == :ban and moderation_case.state == :executed
        )
        |> Repo.update_all(
          set: [state: :revoked, revoked_at: now, revoked_by_user_id: scope.user_id]
        )

        membership = reactivate_membership!(membership, scope.user_id)

        moderation_case =
          record_moderation_case(scope.user_id, subject_id, :unban, reason, executed_at: now)

        AuditLog.record!(scope.user_id, "unban_member", subject_id, {"user", subject_id},
          reason: reason
        )

        {membership, moderation_case}
      else
        {:error, :not_found}
      end
    end)
    |> tap(fn
      {:ok, _subject, _moderation_case} -> Topics.broadcast_server(:roles_changed)
      {:error, _reason} -> :ok
    end)
  end

  @doc """
  Brings the kicked member `scope.user_id` back with the invite `code`. One transaction takes the
  member's membership row `FOR UPDATE`, redeems the invite (`Invites.redeem/2`: row lock, expiry,
  use cap, one use per user), reactivates the membership with the default role only (the roles held
  when kicked are dropped, as `unban_member/3` does), and writes a `member_rejoined` audit entry
  naming the code. Broadcasts `:roles_changed`, and returns `{:ok, membership}`.

  Errors: `{:error, :banned}` for a banned member, `{:error, :not_kicked}` for a member who is
  active or has no membership, and `{:error, :invalid_invite}` for a code that is unknown,
  revoked, expired, exhausted or already used by this member.
  """
  def rejoin_with_invite(%Scope{user_id: user_id}, code) when is_binary(user_id) do
    Repo.transact(fn ->
      with %Membership{} = membership <- lock_membership(user_id),
           :ok <- ensure_kicked(membership),
           %User{} = user <- Repo.get(User, user_id),
           {:ok, invite} <- Invites.redeem(code, user) do
        from(member_role in MemberRole, where: member_role.user_id == ^user_id)
        |> Repo.delete_all()

        membership = reactivate_membership!(membership, user_id)

        AuditLog.record!(user_id, "member_rejoined", user_id, {"user", user_id},
          metadata: %{"invite_code" => invite.code}
        )

        {:ok, membership}
      else
        nil -> {:error, :not_kicked}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> tap(fn
      {:ok, _membership} ->
        Topics.broadcast_server(:roles_changed)
        ProductEvents.record({:member_rejoined, user_id})

      {:error, _reason} ->
        :ok
    end)
  end

  def rejoin_with_invite(%Scope{}, _code), do: {:error, :not_kicked}

  defp lock_membership(user_id) do
    from(membership in Membership, where: membership.user_id == ^user_id, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp ensure_kicked(%Membership{deactivated_at: nil}), do: {:error, :not_kicked}

  defp ensure_kicked(%Membership{} = membership),
    do: if(banned_membership?(membership), do: {:error, :banned}, else: :ok)

  defp banned_membership?(%Membership{deactivated_at: nil}), do: false
  defp banned_membership?(%Membership{flags: flags}), do: Map.get(flags || %{}, "banned") == true

  # Removes a member through `moderate/4` with `change`. A removed member's sessions go after the
  # removal commits, and their open LiveViews disconnect. A socket that reconnects finds no
  # session and is sent to log in.
  defp deactivate_member(scope, subject_user_id, bit, change) do
    scope
    |> moderate(subject_user_id, bit, change)
    |> tap(fn
      {:ok, subject, _moderation_case} -> Accounts.revoke_user_sessions(subject.id)
      {:error, _reason} -> :ok
    end)
  end

  defp remove_membership!(scope, membership, subject_id, action_type, reason, extra_flags) do
    now = DateTime.utc_now()
    flags = Map.merge(membership.flags || %{}, extra_flags)

    membership =
      membership
      |> Membership.deactivate_changeset(now, flags)
      |> Repo.update!()

    moderation_case =
      record_moderation_case(scope.user_id, subject_id, action_type, reason,
        executed_at: now,
        details: flags
      )

    AuditLog.record!(scope.user_id, "#{action_type}_member", subject_id, {"user", subject_id},
      reason: reason,
      metadata: flags
    )

    {membership, moderation_case}
  end

  # Reactivation (a rejoin, an unban) cancels a scheduled deletion: an active member never carries
  # one.
  defp reactivate_membership!(%Membership{} = membership, actor_id) do
    membership
    |> cancel_scheduled_deletion!(actor_id)
    |> Membership.reactivate_changeset()
    |> Repo.update!()
  end

  # Clears a scheduled deletion and records the cancellation, naming `actor_id`. A membership with
  # none is returned unchanged, with nothing written.
  defp cancel_scheduled_deletion!(
         %Membership{deletion_scheduled_at: nil} = membership,
         _actor_id
       ),
       do: membership

  defp cancel_scheduled_deletion!(%Membership{} = membership, actor_id) do
    AuditLog.record!(
      actor_id,
      "account_deletion_canceled",
      membership.user_id,
      {"user", membership.user_id},
      metadata: %{"deletion_scheduled_at" => membership.deletion_scheduled_at}
    )

    membership |> Membership.deletion_changeset(nil) |> Repo.update!()
  end

  # Every moderation write runs here, in one transaction. `Visibility.authorize_write/3` takes the
  # actor's and the subject's membership rows `FOR UPDATE` in user_id order, then decides, so the
  # decision sees the subject's state as of the lock. `change` gets the subject's membership row,
  # which that lock already holds, and returns the membership to keep and the moderation case. A
  # subject with no membership row is `:not_found`; a subject the actor may not moderate is
  # `:forbidden`, both from `Visibility`. `change` may instead return `{:error, reason}`, which
  # rolls the transaction back.
  defp moderate(%Scope{} = scope, subject_user_id, bit, change) do
    with {:ok, subject_user_id} <- Ids.cast(subject_user_id) do
      Repo.transact(fn ->
        with :ok <- Visibility.authorize_write(scope, {:moderate, bit}, subject_user_id),
             {:ok, membership} <- subject_membership(subject_user_id),
             {%Membership{} = membership, moderation_case} <- change.(membership, subject_user_id) do
          subject =
            User
            |> Repo.get!(subject_user_id)
            |> Repo.preload(member_roles: :role)
            |> Map.put(:membership, membership)

          {:ok, {subject, moderation_case}}
        end
      end)
      |> case do
        {:ok, {subject, moderation_case}} ->
          ProductEvents.record({:member_moderated, moderation_case})
          {:ok, subject, moderation_case}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp subject_membership(subject_id) do
    case Repo.get_by(Membership, user_id: subject_id) do
      nil -> {:error, :not_found}
      %Membership{} = membership -> {:ok, membership}
    end
  end

  defp record_moderation_case(actor_id, subject_id, action_type, reason, attrs) do
    attrs = %{
      action_type: action_type,
      state: :executed,
      actor_user_id: actor_id,
      subject_user_id: subject_id,
      reason: reason,
      details: Keyword.get(attrs, :details, %{}),
      expires_at: Keyword.get(attrs, :expires_at),
      executed_at: Keyword.get(attrs, :executed_at)
    }

    insert_moderation_case(attrs, 5)
  end

  defp insert_moderation_case(attrs, attempts_left) when attempts_left > 0 do
    case_number = next_case_number()

    case %ModerationCase{}
         |> ModerationCase.changeset(Map.put(attrs, :case_number, case_number))
         |> Repo.insert() do
      {:ok, moderation_case} ->
        moderation_case

      {:error, changeset} ->
        if unique_case_number_error?(changeset) do
          insert_moderation_case(attrs, attempts_left - 1)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp insert_moderation_case(_attrs, 0) do
    raise "failed to allocate a unique moderation case number"
  end

  defp unique_case_number_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:case_number, _details} -> true
      _other -> false
    end)
  end

  defp next_case_number do
    (Repo.aggregate(ModerationCase, :max, :case_number) || 0) + 1
  end
end
