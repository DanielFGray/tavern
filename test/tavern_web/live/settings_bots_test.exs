defmodule TavernWeb.SettingsBotsTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat.BotToken
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.User
  alias Tavern.Repo

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

  test "an owner creates a bot, mints a token and revokes it", %{conn: conn} do
    owner = owner_fixture()
    {:ok, view, _html} = live(log_in_as(conn, owner), ~p"/settings?tab=server")

    view
    |> form("#bot-form", %{
      bot: %{display_name: "Helper", username: "settings_helper", email: "helper@example.com"}
    })
    |> render_submit()

    bot = Repo.get_by!(User, username: "settings_helper", bot: true)
    assert has_element?(view, "#bot-card-#{bot.id}")

    view
    |> form("#bot-token-form-#{bot.id}", %{token: %{label: "primary"}})
    |> render_submit()

    assert has_element?(view, "#revealed-bot-token-#{bot.id}")
    token = Repo.get_by!(BotToken, user_id: bot.id)

    view |> element("#revoke-bot-token-#{token.id}") |> render_click()

    assert Repo.reload!(token).revoked_at
    refute has_element?(view, "#revoke-bot-token-#{token.id}")
  end

  test "a bot write from a page opened before manage_bots was taken away is refused", %{
    conn: conn
  } do
    owner = owner_fixture()
    bot = bot_fixture(owner)
    manager_role = role_fixture(%{permissions: PermissionBits.combine([:manage_bots])})
    manager = user_fixture()
    member_role = member_role_fixture(manager, manager_role)

    {:ok, view, _html} = live(log_in_as(conn, manager), ~p"/settings?tab=server")
    assert has_element?(view, "#bot-token-form-#{bot.id}")

    Repo.delete!(member_role)

    view
    |> form("#bot-token-form-#{bot.id}", %{token: %{label: "stale"}})
    |> render_submit()

    assert render(view) =~ "You cannot mint tokens for this bot."
    refute Repo.get_by(BotToken, user_id: bot.id)

    view
    |> form("#bot-form", %{
      bot: %{display_name: "Late", username: "settings_late", email: "late@example.com"}
    })
    |> render_submit()

    assert render(view) =~ "You do not have permission to create that bot."
    refute Repo.get_by(User, username: "settings_late")
  end
end
