defmodule Tavern.Chat.InviteTreeTest do
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Invite
  alias Tavern.Chat.InviteUse
  alias Tavern.Chat.Membership
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  # root ── alice ── carol ── dave
  #      └─ bob
  # outsider is a second root.
  setup do
    Bootstrap.ensure_seed_data!()
    channel = channel_fixture()

    root = user_fixture(%{username: "rooty"})
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bobby"})
    carol = user_fixture(%{username: "carol"})
    dave = user_fixture(%{username: "dave"})
    outsider = user_fixture(%{username: "outsider"})

    invite!(channel, root, alice, "AAAA1111", ~U[2026-01-01 10:00:00.000000Z])
    invite!(channel, root, bob, "BBBB1111", ~U[2026-01-02 10:00:00.000000Z])
    invite!(channel, alice, carol, "CCCC1111", ~U[2026-01-03 10:00:00.000000Z])
    invite!(channel, carol, dave, "DDDD1111", ~U[2026-01-04 10:00:00.000000Z])

    role =
      role_fixture(%{
        name: "Auditors",
        position: 20,
        permissions: PermissionBits.combine([:view_channel, :view_audit_log])
      })

    mod = user_fixture(%{username: "moddy"})
    member_role_fixture(mod, role)

    %{
      channel: channel,
      root: root,
      alice: alice,
      bob: bob,
      carol: carol,
      dave: dave,
      outsider: outsider,
      mod: mod
    }
  end

  defp invite!(channel, inviter, invitee, code, used_at) do
    invite =
      Repo.get_by(Invite, code: code) ||
        Repo.insert!(%Invite{code: code, channel_id: channel.id, inviter_id: inviter.id})

    Repo.insert!(%InviteUse{invite_id: invite.id, user_id: invitee.id, used_at: used_at})
  end

  defp ids({:ok, nodes}), do: Enum.map(nodes, & &1.user.id)

  test "roots are members with no invite use; a moderator sees all of them", ctx do
    {:ok, nodes} = Chat.invite_tree_children(scope_for(ctx.mod), :roots)
    root_ids = Enum.map(nodes, & &1.user.id)

    assert ctx.root.id in root_ids
    assert ctx.outsider.id in root_ids
    refute ctx.alice.id in root_ids

    root_node = Enum.find(nodes, &(&1.user.id == ctx.root.id))
    assert root_node.child_count == 2
    assert root_node.code == nil
    assert root_node.status == :active
  end

  test "children are the direct invitees with code, inviter and counts", ctx do
    {:ok, [alice, bob]} = Chat.invite_tree_children(scope_for(ctx.mod), ctx.root.id)

    assert alice.user.id == ctx.alice.id
    assert alice.code == "AAAA1111"
    assert alice.inviter.id == ctx.root.id
    assert alice.child_count == 1
    assert alice.joined_at == ~U[2026-01-01 10:00:00.000000Z]
    assert bob.child_count == 0
  end

  test "a later invite use is listed and does not move the member", ctx do
    channel = ctx.channel
    invite!(channel, ctx.bob, ctx.carol, "EEEE1111", ~U[2026-02-01 10:00:00.000000Z])

    assert ids(Chat.invite_tree_children(scope_for(ctx.mod), ctx.alice.id)) == [ctx.carol.id]
    assert ids(Chat.invite_tree_children(scope_for(ctx.mod), ctx.bob.id)) == []

    {:ok, [carol]} = Chat.invite_tree_children(scope_for(ctx.mod), ctx.alice.id)
    assert [%{code: "EEEE1111", inviter: inviter}] = carol.rejoins
    assert inviter.id == ctx.bob.id

    {:ok, [carol]} = Chat.invite_tree_children(scope_for(ctx.alice), ctx.alice.id)
    assert [%{code: "EEEE1111", inviter: nil}] = carol.rejoins
  end

  test "a moderator sees kicked and banned status", ctx do
    deactivate!(ctx.alice, %{})
    deactivate!(ctx.bob, %{"banned" => true})

    {:ok, [alice, bob]} = Chat.invite_tree_children(scope_for(ctx.mod), ctx.root.id)
    assert alice.status == :kicked
    assert bob.status == :banned

    {:ok, [alice, _bob]} = Chat.invite_tree_children(scope_for(ctx.root), ctx.root.id)
    assert alice.status == nil
  end

  test "a member's top level is their inviter, who shows only the member", ctx do
    {:ok, [top]} = Chat.invite_tree_children(scope_for(ctx.carol), :roots)
    assert top.user.id == ctx.alice.id
    assert top.code == nil
    assert top.inviter == nil
    assert top.child_count == 1

    assert ids(Chat.invite_tree_children(scope_for(ctx.carol), ctx.alice.id)) == [ctx.carol.id]
    assert ids(Chat.invite_tree_children(scope_for(ctx.carol), ctx.carol.id)) == [ctx.dave.id]
    assert ids(Chat.invite_tree_children(scope_for(ctx.carol), ctx.dave.id)) == []
  end

  test "a member with no inviter starts at themselves", ctx do
    assert ids(Chat.invite_tree_children(scope_for(ctx.outsider), :roots)) == [ctx.outsider.id]
  end

  test "a member cannot read outside their own branch", ctx do
    scope = scope_for(ctx.carol)

    for outside <- [ctx.root, ctx.bob, ctx.outsider] do
      assert {:error, :not_found} = Chat.invite_tree_children(scope, outside.id)
      assert {:error, :not_found} = Chat.invite_tree_path_to(scope, outside.id)
    end

    assert {:error, :not_found} = Chat.invite_tree_children(scope, Ecto.UUID.generate())
    assert {:error, :not_found} = Chat.invite_tree_children(scope, "not-a-uuid")
  end

  test "a scope that is not a member is forbidden", ctx do
    deactivate!(ctx.carol, %{})
    assert {:error, :forbidden} = Chat.invite_tree_children(scope_for(ctx.carol), :roots)
    assert {:error, :forbidden} = Chat.invite_tree_search(%Tavern.Accounts.Scope{}, "a")
  end

  test "path_to runs from the root to the member", ctx do
    assert {:ok, chain} = Chat.invite_tree_path_to(scope_for(ctx.mod), ctx.dave.id)
    assert chain == [ctx.root.id, ctx.alice.id, ctx.carol.id, ctx.dave.id]

    assert {:ok, [id]} = Chat.invite_tree_path_to(scope_for(ctx.mod), ctx.outsider.id)
    assert id == ctx.outsider.id

    assert {:error, :not_found} =
             Chat.invite_tree_path_to(scope_for(ctx.mod), Ecto.UUID.generate())
  end

  test "path_to for a member starts at their inviter", ctx do
    assert {:ok, [alice, carol, dave]} =
             Chat.invite_tree_path_to(scope_for(ctx.carol), ctx.dave.id)

    assert [alice, carol, dave] == [ctx.alice.id, ctx.carol.id, ctx.dave.id]

    assert {:ok, [alice_id]} = Chat.invite_tree_path_to(scope_for(ctx.carol), ctx.alice.id)
    assert alice_id == ctx.alice.id

    assert {:ok, [_, own]} = Chat.invite_tree_path_to(scope_for(ctx.carol), ctx.carol.id)
    assert own == ctx.carol.id
  end

  test "path_to ends on a loop instead of running forever", ctx do
    invite!(ctx.channel, ctx.dave, ctx.root, "LOOP1111", ~U[2025-12-01 10:00:00.000000Z])
    invite!(ctx.channel, ctx.root, ctx.dave, "LOOP2222", ~U[2025-11-01 10:00:00.000000Z])

    assert {:ok, chain} = Chat.invite_tree_path_to(scope_for(ctx.mod), ctx.dave.id)
    assert List.last(chain) == ctx.dave.id
  end

  test "search finds by username or name inside what the scope may see", ctx do
    assert ids(Chat.invite_tree_search(scope_for(ctx.mod), "ali")) == [ctx.alice.id]
    assert ids(Chat.invite_tree_search(scope_for(ctx.mod), "ROOT")) == [ctx.root.id]
    assert {:ok, []} = Chat.invite_tree_search(scope_for(ctx.mod), "  ")
    assert {:ok, []} = Chat.invite_tree_search(scope_for(ctx.mod), "%")

    scope = scope_for(ctx.carol)
    assert ids(Chat.invite_tree_search(scope, "ali")) == [ctx.alice.id]
    assert ids(Chat.invite_tree_search(scope, "dav")) == [ctx.dave.id]
    assert {:ok, []} = Chat.invite_tree_search(scope, "bob")
    assert {:ok, []} = Chat.invite_tree_search(scope, "outsider")
  end

  defp deactivate!(user, flags) do
    membership = Repo.get_by!(Membership, user_id: user.id)

    membership
    |> Membership.deactivate_changeset(DateTime.utc_now(), flags)
    |> Repo.update!()
  end
end
