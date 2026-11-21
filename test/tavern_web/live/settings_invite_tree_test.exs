defmodule TavernWeb.SettingsInviteTreeTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat.Invite
  alias Tavern.Chat.InviteUse
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  # root ── alice ── carol, root ── bob
  setup do
    Bootstrap.ensure_seed_data!()
    channel = channel_fixture()

    root = user_fixture(%{username: "rooty", display_name: "Rooty"})
    alice = user_fixture(%{username: "alice", display_name: "Alice"})
    bob = user_fixture(%{username: "bobby", display_name: "Bobby"})
    carol = user_fixture(%{username: "carol", display_name: "Carol"})

    invite!(channel, root, alice, "AAAA1111", ~U[2026-01-01 10:00:00.000000Z])
    invite!(channel, root, bob, "BBBB1111", ~U[2026-01-02 10:00:00.000000Z])
    invite!(channel, alice, carol, "CCCC1111", ~U[2026-01-03 10:00:00.000000Z])

    role =
      role_fixture(%{
        name: "Auditors",
        position: 20,
        permissions: PermissionBits.combine([:view_channel, :view_audit_log])
      })

    mod = user_fixture(%{username: "moddy"})
    member_role_fixture(mod, role)

    %{root: root, alice: alice, bob: bob, carol: carol, mod: mod}
  end

  defp invite!(channel, inviter, invitee, code, used_at) do
    invite =
      Repo.insert!(%Invite{code: code, channel_id: channel.id, inviter_id: inviter.id})

    Repo.insert!(%InviteUse{invite_id: invite.id, user_id: invitee.id, used_at: used_at})
  end

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Tavern.Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end

  test "the tab shows for a plain member and lists their own branch", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.carol), ~p"/settings?tab=invites")

    assert has_element?(view, "#settings-tab-invites")
    assert has_element?(view, "#invite-node-#{ctx.alice.id}")
    refute has_element?(view, "#invite-node-#{ctx.root.id}")
    refute has_element?(view, "#invite-node-#{ctx.bob.id}")
    refute has_element?(view, "#invite-status-#{ctx.alice.id}")

    view |> element("#invite-toggle-#{ctx.alice.id}") |> render_click()
    assert has_element?(view, "#invite-node-#{ctx.carol.id}")
    refute has_element?(view, "#invite-node-#{ctx.bob.id}")
  end

  test "a member with nobody above them sees only their own subtree", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.alice), ~p"/settings?tab=invites")

    assert has_element?(view, "#invite-node-#{ctx.root.id}")
    assert has_element?(view, "#invite-node-#{ctx.alice.id}") == false
    refute has_element?(view, "#invite-node-#{ctx.carol.id}")

    view |> element("#invite-toggle-#{ctx.root.id}") |> render_click()
    assert has_element?(view, "#invite-node-#{ctx.alice.id}")
    refute has_element?(view, "#invite-node-#{ctx.bob.id}")

    view |> element("#invite-toggle-#{ctx.alice.id}") |> render_click()
    assert has_element?(view, "#invite-node-#{ctx.carol.id}")
  end

  test "a moderator expands the whole tree and collapses a branch", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.mod), ~p"/settings?tab=invites")

    assert has_element?(view, "#invite-node-#{ctx.root.id}")
    refute has_element?(view, "#invite-node-#{ctx.alice.id}")

    view |> element("#invite-toggle-#{ctx.root.id}") |> render_click()
    assert has_element?(view, "#invite-node-#{ctx.alice.id}")
    assert has_element?(view, "#invite-node-#{ctx.bob.id}")
    refute has_element?(view, "#invite-toggle-#{ctx.bob.id}")

    view |> element("#invite-toggle-#{ctx.root.id}") |> render_click()
    refute has_element?(view, "#invite-node-#{ctx.alice.id}")
  end

  test "search jumps to a member, opening the branches above them", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.mod), ~p"/settings?tab=invites")

    view |> form("#invite-tree-search-form", tree: %{q: "carol"}) |> render_change()
    assert has_element?(view, "#invite-tree-result-#{ctx.carol.id}")
    refute has_element?(view, "#invite-tree-result-#{ctx.bob.id}")

    view |> element("#invite-tree-result-#{ctx.carol.id} button") |> render_click()
    assert has_element?(view, "#invite-node-#{ctx.carol.id}")
    assert has_element?(view, "#invite-node-row-#{ctx.carol.id}.border-primary")
    refute has_element?(view, "#invite-tree-results")
  end

  test "search says when nothing matches and never leaves a member's branch",
       %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.carol), ~p"/settings?tab=invites")

    view |> form("#invite-tree-search-form", tree: %{q: "bobby"}) |> render_change()
    assert has_element?(view, "#invite-tree-no-results")
  end
end
