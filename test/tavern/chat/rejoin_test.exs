defmodule Tavern.Chat.RejoinTest do
  use Tavern.DataCase, async: false

  import Ecto.Query

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.AuditLogLine
  alias Tavern.Chat.InviteTree
  alias Tavern.Chat.MemberRole
  alias Tavern.Repo

  import Tavern.ChatFixtures

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    channel = channel_fixture()
    member = user_fixture()
    member_role_fixture(member, role_fixture(%{position: 10}))
    {:ok, _, _} = Chat.kick_member(scope_for(owner), member.id, "noise")
    %{owner: owner, channel: channel, member: member}
  end

  defp invite!(owner, channel, attrs \\ %{}) do
    {:ok, invite} =
      Chat.create_invite(scope_for(owner), Map.merge(%{"channel_id" => channel.id}, attrs))

    invite
  end

  describe "rejoin_with_invite/2" do
    test "a kicked member rejoins with default role only, and the audit line names the code",
         ctx do
      invite = invite!(ctx.owner, ctx.channel)

      assert {:ok, membership} = Chat.rejoin_with_invite(scope_for(ctx.member), invite.code)
      assert is_nil(membership.deactivated_at)

      user = user_with_membership!(ctx.member.id)
      refute Accounts.excluded?(user)
      assert Repo.all(from(role in MemberRole, where: role.user_id == ^ctx.member.id)) == []
      assert Repo.reload!(invite).uses == 1

      entry =
        AuditLogEntry
        |> Repo.get_by!(action_type: "member_rejoined", subject_user_id: ctx.member.id)
        |> Repo.preload([:actor_user, :subject_user, :channel])

      assert entry.metadata["invite_code"] == invite.code
      assert AuditLogLine.format(entry) == "@#{ctx.member.username} rejoined via #{invite.code}"
    end

    test "the invite tree lists the later use as a rejoin", ctx do
      original = invite!(ctx.owner, ctx.channel)
      Repo.transaction(fn -> Chat.Invites.redeem(original.code, ctx.member) end)
      first = invite!(ctx.owner, ctx.channel)
      {:ok, _} = Chat.rejoin_with_invite(scope_for(ctx.member), first.code)

      assert {:ok, nodes} = InviteTree.search(scope_for(ctx.owner), ctx.member.username)
      node = Enum.find(nodes, &(&1.user.id == ctx.member.id))
      assert [%{code: code}] = node.rejoins
      assert code == first.code
      refute code == original.code
    end

    test "a banned member is refused", ctx do
      banned = user_fixture()
      {:ok, _, _} = Chat.ban_member(scope_for(ctx.owner), banned.id, "abuse")
      invite = invite!(ctx.owner, ctx.channel)

      assert {:error, :banned} = Chat.rejoin_with_invite(scope_for(banned), invite.code)
      assert Accounts.banned?(user_with_membership!(banned.id))
      assert Repo.reload!(invite).uses == 0
    end

    test "an active member is refused", ctx do
      active = user_fixture()
      invite = invite!(ctx.owner, ctx.channel)

      assert {:error, :not_kicked} = Chat.rejoin_with_invite(scope_for(active), invite.code)
      assert Repo.reload!(invite).uses == 0
    end

    test "unknown, revoked, expired and exhausted codes are refused", ctx do
      revoked = invite!(ctx.owner, ctx.channel)
      {:ok, _} = Chat.revoke_invite(scope_for(ctx.owner), revoked.id)

      expired = invite!(ctx.owner, ctx.channel)

      Repo.update_all(from(i in Chat.Invite, where: i.id == ^expired.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      spent = invite!(ctx.owner, ctx.channel, %{"max_uses" => "1"})
      other = user_fixture()
      {:ok, _, _} = Chat.kick_member(scope_for(ctx.owner), other.id, nil)
      {:ok, _} = Chat.rejoin_with_invite(scope_for(other), spent.code)

      for code <- ["nosuchcode", revoked.code, expired.code, spent.code] do
        assert {:error, :invalid_invite} =
                 Chat.rejoin_with_invite(scope_for(ctx.member), code)
      end

      assert Accounts.excluded?(user_with_membership!(ctx.member.id))

      assert Repo.all(from(e in AuditLogEntry, where: e.action_type == "member_rejoined"))
             |> length() == 1
    end

    test "two kicked members racing for a one-use code: exactly one gets in", ctx do
      other = user_fixture()
      {:ok, _, _} = Chat.kick_member(scope_for(ctx.owner), other.id, nil)
      invite = invite!(ctx.owner, ctx.channel, %{"max_uses" => "1"})

      results =
        [ctx.member, other]
        |> Task.async_stream(
          fn user ->
            Chat.rejoin_with_invite(scope_for(user), invite.code)
          end,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid_invite}, &1)) == 1
      assert Repo.reload!(invite).uses == 1
    end
  end
end
