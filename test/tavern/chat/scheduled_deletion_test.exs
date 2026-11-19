defmodule Tavern.Chat.ScheduledDeletionTest do
  @moduledoc """
  `Chat.kick_member_and_schedule_deletion/3` kicks a member and schedules their account deletion
  30 days ahead. A rejoin, a ban or a moderator's cancel clears it; each step writes an audit entry, and
  the schedule is mailed when a mail provider is configured.
  """
  use Tavern.DataCase, async: false

  import Ecto.Query
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.AuditLogLine
  alias Tavern.Chat.Membership
  alias Tavern.Chat.ModerationCase
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    member = user_fixture(%{email: "scheduled@example.com"})
    %{owner: owner, member: member, channel: channel_by_slug!("general")}
  end

  describe "kick_member_and_schedule_deletion/3" do
    test "kicks, schedules deletion in 30 days, records the case and audit entries, and mails",
         ctx do
      assert {:ok, subject, moderation_case} =
               Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), ctx.member.id, "spam")

      membership = Repo.get_by!(Membership, user_id: ctx.member.id)
      assert membership.deactivated_at
      assert membership.flags["kicked"] == true
      assert subject.membership.deletion_scheduled_at == membership.deletion_scheduled_at

      days = DateTime.diff(membership.deletion_scheduled_at, DateTime.utc_now(), :day)
      assert days in 29..30

      assert %ModerationCase{action_type: :kick, reason: "spam"} = moderation_case
      assert Accounts.removed?(user_with_membership!(ctx.member.id))

      entry = audit_entry!("account_deletion_scheduled", ctx.member.id)
      assert entry.actor_user_id == ctx.owner.id
      assert audit_entry!("kick_member", ctx.member.id)

      date = Calendar.strftime(membership.deletion_scheduled_at, "%B %-d, %Y")

      assert AuditLogLine.format(entry) ==
               "@#{ctx.owner.username} scheduled the deletion of @#{ctx.member.username} for #{Calendar.strftime(membership.deletion_scheduled_at, "%b %-d, %Y")}: spam"

      assert_receive {:mail_captured, %{to: "scheduled@example.com"} = mail}
      assert mail.subject =~ date
      assert mail.text =~ "unless"
    end

    test "sends no mail when no provider is configured", ctx do
      previous = Application.get_env(:tavern, Tavern.Mailer)
      Application.put_env(:tavern, Tavern.Mailer, provider: nil)
      on_exit(fn -> Application.put_env(:tavern, Tavern.Mailer, previous) end)

      assert {:ok, _subject, _case} =
               Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), ctx.member.id)

      refute_receive {:mail_captured, _mail}
    end

    test "refuses a bot, and a moderator without kick_members", ctx do
      bot = bot_fixture(ctx.owner)

      assert {:error, :forbidden} =
               Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), bot.id)

      assert is_nil(Repo.get_by!(Membership, user_id: bot.id).deletion_scheduled_at)

      plain = user_fixture()

      assert {:error, :forbidden} =
               Chat.kick_member_and_schedule_deletion(scope_for(plain), ctx.member.id)

      assert is_nil(Repo.get_by!(Membership, user_id: ctx.member.id).deactivated_at)
    end
  end

  describe "cancelling" do
    setup ctx do
      {:ok, _, _} = Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), ctx.member.id)
      :ok
    end

    test "rejoining with an invite clears the schedule and records the cancellation", ctx do
      {:ok, invite} = Chat.create_invite(%{"channel_id" => ctx.channel.id}, ctx.owner)

      assert {:ok, membership} = Chat.rejoin_with_invite(scope_for(ctx.member), invite.code)
      assert is_nil(membership.deletion_scheduled_at)

      entry = audit_entry!("account_deletion_canceled", ctx.member.id)
      assert entry.actor_user_id == ctx.member.id
    end

    test "a moderator with kick_members cancels; the member stays kicked", ctx do
      moderator = user_fixture()

      member_role_fixture(
        moderator,
        role_fixture(%{permissions: PermissionBits.combine([:kick_members]), position: 40})
      )

      assert {:ok, [%{user: listed}]} = Chat.list_scheduled_deletions(scope_for(moderator))
      assert listed.id == ctx.member.id

      assert {:ok, membership} = Chat.cancel_account_deletion(scope_for(moderator), ctx.member.id)
      assert is_nil(membership.deletion_scheduled_at)
      assert membership.deactivated_at

      entry = audit_entry!("account_deletion_canceled", ctx.member.id)
      assert entry.actor_user_id == moderator.id

      assert AuditLogLine.format(entry) ==
               "@#{moderator.username} canceled the deletion of @#{ctx.member.username}"

      assert {:ok, []} = Chat.list_scheduled_deletions(scope_for(moderator))

      assert {:error, :not_found} =
               Chat.cancel_account_deletion(scope_for(moderator), ctx.member.id)
    end

    test "banning cancels the deletion, and the sweep keeps the banned account", ctx do
      assert {:ok, subject, _case} =
               Chat.ban_member(scope_for(ctx.owner), ctx.member.id, "worse")

      assert is_nil(subject.membership.deletion_scheduled_at)

      membership = Repo.get_by!(Membership, user_id: ctx.member.id)
      assert is_nil(membership.deletion_scheduled_at)
      assert membership.flags["banned"] == true

      entry = audit_entry!("account_deletion_canceled", ctx.member.id)
      assert entry.actor_user_id == ctx.owner.id

      assert Accounts.delete_due_accounts(DateTime.add(DateTime.utc_now(), 31, :day)) == 0

      kept = Repo.get!(Tavern.Chat.User, ctx.member.id)
      assert is_nil(kept.deleted_at)
      assert kept.email == "scheduled@example.com"
    end

    test "the sweep skips a banned membership that still carries a date", ctx do
      {:ok, _subject, _case} = Chat.ban_member(scope_for(ctx.owner), ctx.member.id, "worse")

      # A date the ban path did not clear, such as a row written before bans canceled deletions.
      Membership
      |> Repo.get_by!(user_id: ctx.member.id)
      |> Membership.deletion_changeset(DateTime.add(DateTime.utc_now(), -1, :day))
      |> Repo.update!()

      assert Accounts.delete_due_accounts(DateTime.utc_now()) == 0
      assert is_nil(Repo.get!(Tavern.Chat.User, ctx.member.id).deleted_at)
    end

    test "a member without kick_members can neither list nor cancel", ctx do
      plain = user_fixture()

      assert {:error, :forbidden} = Chat.list_scheduled_deletions(scope_for(plain))
      assert {:error, :forbidden} = Chat.cancel_account_deletion(scope_for(plain), ctx.member.id)

      assert Repo.get_by!(Membership, user_id: ctx.member.id).deletion_scheduled_at
    end
  end

  defp audit_entry!(action_type, subject_id) do
    from(entry in AuditLogEntry,
      where: entry.action_type == ^action_type and entry.subject_user_id == ^subject_id,
      preload: [:actor_user, :subject_user, :channel]
    )
    |> Repo.one!()
  end
end
