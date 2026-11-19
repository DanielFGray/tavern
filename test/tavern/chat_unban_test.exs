defmodule Tavern.ChatUnbanTest do
  use Tavern.DataCase, async: false

  import Ecto.Query

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.ModerationCase
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  import Tavern.ChatFixtures

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    moderator = user_fixture()

    role = role_fixture(%{permissions: PermissionBits.combine([:ban_members]), position: 50})
    member_role_fixture(moderator, role)

    %{moderator: moderator, owner: owner}
  end

  describe "unban_member/3" do
    test "reactivates the member with no roles and records the case, the audit entry and the broadcast",
         %{moderator: moderator} do
      member = user_fixture()
      member_role_fixture(member, role_fixture(%{position: 10}))
      {:ok, _banned, ban_case} = Chat.ban_member(scope_for(moderator), member.id, "spam")

      assert {:ok, subject, unban_case} =
               Chat.unban_member(scope_for(moderator), member.id, "appealed")

      assert is_nil(subject.membership.deactivated_at)
      assert subject.membership.flags == %{}
      assert subject.member_roles == []
      refute Accounts.excluded?(user_with_membership!(member.id))
      assert Repo.all(from(role in MemberRole, where: role.user_id == ^member.id)) == []

      assert unban_case.action_type == :unban
      assert unban_case.reason == "appealed"
      assert unban_case.actor_user_id == moderator.id
      assert Repo.get!(ModerationCase, ban_case.id).state == :revoked

      assert Repo.get_by!(AuditLogEntry, action_type: "unban_member", subject_user_id: member.id).reason ==
               "appealed"
    end

    # The broadcast skips the calling process, so a second process does the unban.
    test "broadcasts :roles_changed to the server topic", %{moderator: moderator} do
      member = user_fixture()
      {:ok, _banned, _case} = Chat.ban_member(scope_for(moderator), member.id)
      Chat.Topics.subscribe_server()

      task = Task.async(fn -> Chat.unban_member(scope_for(moderator), member.id) end)

      assert {:ok, _subject, _case} = Task.await(task)
      assert_receive :roles_changed
    end

    test "a scope without ban_members is refused", %{moderator: moderator} do
      member = user_fixture()
      {:ok, _banned, _case} = Chat.ban_member(scope_for(moderator), member.id)

      assert {:error, :forbidden} = Chat.unban_member(scope_for(user_fixture()), member.id)
      assert Accounts.excluded?(user_with_membership!(member.id))
    end

    test "a member who is not banned is :not_found", %{moderator: moderator, owner: owner} do
      active = user_fixture()
      kicked = user_fixture()
      {:ok, _kicked, _case} = Chat.kick_member(scope_for(owner), kicked.id)

      assert {:error, :not_found} = Chat.unban_member(scope_for(moderator), active.id)
      assert {:error, :not_found} = Chat.unban_member(scope_for(moderator), kicked.id)
      assert {:error, :not_found} = Chat.unban_member(scope_for(moderator), Ecto.UUID.generate())
      assert {:error, :not_found} = Chat.unban_member(scope_for(moderator), "not-a-uuid")
      assert Accounts.excluded?(user_with_membership!(kicked.id))
    end

    test "refuses a banned member ranked at or above the moderator", %{moderator: moderator} do
      peer = user_fixture()
      member_role_fixture(peer, role_fixture(%{position: 50}))
      {:ok, _banned, _case} = Chat.ban_member(scope_for(user_fixture_admin()), peer.id)

      assert {:error, :forbidden} = Chat.unban_member(scope_for(moderator), peer.id)
      assert Accounts.excluded?(user_with_membership!(peer.id))
    end
  end

  describe "list_bans/1" do
    test "lists banned members with reason, time and moderator, and not kicked ones", %{
      owner: owner,
      moderator: moderator
    } do
      banned = user_fixture()
      kicked = user_fixture()
      {:ok, _banned, _case} = Chat.ban_member(scope_for(moderator), banned.id, "spam")
      {:ok, _kicked, _case} = Chat.kick_member(scope_for(owner), kicked.id)

      assert {:ok, [entry]} = Chat.list_bans(scope_for(moderator))
      assert entry.user.id == banned.id
      assert entry.reason == "spam"
      assert entry.moderator.id == moderator.id
      assert entry.banned_at

      {:ok, _subject, _case} = Chat.unban_member(scope_for(moderator), banned.id)
      assert {:ok, []} = Chat.list_bans(scope_for(moderator))
    end

    test "a rebanned member shows the latest ban's reason", %{moderator: moderator} do
      member = user_fixture()
      {:ok, _, _} = Chat.ban_member(scope_for(moderator), member.id, "first")
      {:ok, _, _} = Chat.unban_member(scope_for(moderator), member.id)
      {:ok, _, _} = Chat.ban_member(scope_for(moderator), member.id, "second")

      assert {:ok, [%{reason: "second"}]} = Chat.list_bans(scope_for(moderator))
    end

    test "needs ban_members; view_audit_log alone is not enough" do
      auditor = user_fixture()

      member_role_fixture(
        auditor,
        role_fixture(%{permissions: PermissionBits.combine([:view_audit_log]), position: 5})
      )

      assert {:error, :forbidden} = Chat.list_bans(scope_for(user_fixture()))
      assert {:error, :forbidden} = Chat.list_bans(scope_for(auditor))
    end
  end

  defp user_fixture_admin do
    admin = user_fixture()

    member_role_fixture(
      admin,
      role_fixture(%{permissions: PermissionBits.combine([:administrator]), position: 60})
    )

    admin
  end
end
