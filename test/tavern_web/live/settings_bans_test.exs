defmodule TavernWeb.SettingsBansTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end

  setup do
    Accounts.LoginRateLimiter.reset!()
    on_exit(&Accounts.LoginRateLimiter.reset!/0)
    Bootstrap.ensure_seed_data!()
    :ok
  end

  test "the Bans section lists a banned member and unban returns them", %{conn: conn} do
    owner = owner_fixture(%{email: "bans-owner@example.com", username: "bans_owner"})

    member =
      user_fixture(%{
        email: "bans-member@example.com",
        username: "bans_member",
        display_name: "Bans Member"
      })

    {:ok, _banned, _case} = Chat.ban_member(scope_for(owner), member.id, "spam")

    {:ok, view, _html} = live(log_in_as(conn, owner), ~p"/settings?tab=server")

    assert has_element?(view, "#ban-#{member.id}", "bans_member")
    assert has_element?(view, "#ban-#{member.id}", "spam")
    refute has_element?(view, "#ban-list-empty")

    view
    |> form("#unban-form-#{member.id}", %{"reason" => "appeal granted"})
    |> render_submit()

    refute has_element?(view, "#ban-#{member.id}")
    assert has_element?(view, "#ban-list-empty")
    refute Accounts.excluded?(user_with_membership!(member.id))
  end

  test "an unbanned member can log in again", %{conn: conn} do
    owner = owner_fixture(%{email: "bans-owner2@example.com", username: "bans_owner2"})

    member =
      user_fixture(%{email: "bans-login@example.com", username: "bans_login"})

    {:ok, _banned, _case} = Chat.ban_member(scope_for(owner), member.id)
    credentials = %{user: %{email: member.email, password: "supersecurepass"}}

    assert redirected_to(post(conn, ~p"/login", credentials)) == ~p"/banned"

    {:ok, _subject, _case} = Chat.unban_member(scope_for(owner), member.id)

    assert redirected_to(post(build_conn(), ~p"/login", credentials)) == ~p"/"
  end

  test "a member without ban_members sees no Bans section", %{conn: conn} do
    member = user_fixture(%{email: "bans-plain@example.com", username: "bans_plain"})

    {:ok, view, _html} = live(log_in_as(conn, member), ~p"/settings?tab=server")

    refute has_element?(view, "#bans-panel")
  end
end
