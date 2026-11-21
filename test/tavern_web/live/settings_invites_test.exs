defmodule TavernWeb.SettingsInvitesTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Repo
  import Tavern.ChatFixtures

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Tavern.Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end

  setup do
    Bootstrap.ensure_seed_data!()
    :ok
  end

  test "an owner sees the invites panel, creates and revokes an invite", %{conn: conn} do
    owner = owner_fixture(%{email: "invites-owner@example.com", username: "invites_owner"})
    channel_fixture()

    {:ok, view, _html} = live(log_in_as(conn, owner), ~p"/settings?tab=invites")

    assert has_element?(view, "#invite-list")

    view
    |> form("#invite-form", %{
      invite: %{"max_uses" => "5", "expires_in_days" => "7"}
    })
    |> render_submit()

    assert has_element?(view, "#invite-list", "0 uses of 5")
    assert [invite] = Repo.all(Chat.Invite)
    assert invite.max_uses == 5
    assert invite.expires_at
    assert byte_size(invite.code) == 8

    view
    |> element("#revoke-invite-#{invite.id}")
    |> render_click()

    assert has_element?(view, "#invite-list", "revoked")
    assert Repo.reload!(invite).revoked_at
  end

  test "a member without manage_server sees no invites panel", %{conn: conn} do
    member = user_fixture(%{email: "invites-member@example.com", username: "invites_member"})

    {:ok, view, _html} = live(log_in_as(conn, member), ~p"/settings?tab=invites")

    refute has_element?(view, "#invite-list")
  end

  test "the server form offers the registration mode", %{conn: conn} do
    owner = owner_fixture(%{email: "invites-admin@example.com", username: "invites_admin"})

    {:ok, view, _html} = live(log_in_as(conn, owner), ~p"/settings?tab=server")

    assert has_element?(
             view,
             "#server-settings-form select[name='server_settings[registration_mode]']"
           )

    view
    |> form("#server-settings-form", %{
      server_settings: %{"name" => "Invite Gate", "registration_mode" => "invite_only"}
    })
    |> render_submit()

    assert render(view) =~ "Server settings updated."
    assert Chat.get_server_settings().registration_mode == :invite_only

    view
    |> form("#server-settings-form", %{
      server_settings: %{"name" => "Invite Gate", "registration_mode" => "open"}
    })
    |> render_submit()

    assert Chat.get_server_settings().registration_mode == :open
  end
end
