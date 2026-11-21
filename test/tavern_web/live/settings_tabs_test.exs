defmodule TavernWeb.SettingsTabsTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap

  @server_tabs ~w(server emoji members bots roles audit)

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end

  setup do
    Bootstrap.ensure_seed_data!()
    :ok
  end

  test "the owner sees every tab under both headings", %{conn: conn} do
    owner = owner_fixture(%{email: "tabs-owner@example.com", username: "tabs_owner"})
    {:ok, view, _html} = live(log_in_as(conn, owner), ~p"/settings?tab=profile")

    assert has_element?(view, "#settings-group-you")
    assert has_element?(view, "#settings-group-server")

    for tab <- ["invites" | @server_tabs] do
      assert has_element?(view, "#settings-group-server #settings-tab-#{tab}"), tab
    end
  end

  test "a plain member sees only Invites under the Server heading", %{conn: conn} do
    member = user_fixture(%{email: "tabs-member@example.com", username: "tabs_member"})
    {:ok, view, _html} = live(log_in_as(conn, member), ~p"/settings?tab=profile")

    assert has_element?(view, "#settings-group-server #settings-tab-invites")

    for tab <- @server_tabs do
      refute has_element?(view, "#settings-tab-#{tab}"), tab
    end
  end

  test "a direct link to a tab the member may not open stays on the current tab", %{conn: conn} do
    member = user_fixture(%{email: "tabs-direct@example.com", username: "tabs_direct"})

    for tab <- @server_tabs do
      {:ok, view, _html} = live(log_in_as(conn, member), ~p"/settings?tab=#{tab}")

      refute has_element?(view, "#settings-view-#{tab}"), tab
      assert has_element?(view, "#settings-view-profile"), tab
    end
  end

  test "the old Invite tree address opens nothing", %{conn: conn} do
    member = user_fixture(%{email: "tabs-old@example.com", username: "tabs_old"})
    {:ok, view, _html} = live(log_in_as(conn, member), ~p"/settings?tab=invites_tree")

    assert has_element?(view, "#settings-view-profile")
    refute has_element?(view, "#settings-view-invites")
  end
end
