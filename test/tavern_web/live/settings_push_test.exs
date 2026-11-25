defmodule TavernWeb.SettingsPushTest do
  @moduledoc "The Push alerts card in Settings (docs/design/push-notifications.md)."
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat.PushSubscription
  alias Tavern.Repo
  alias Tavern.WebPush

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    member = user_fixture()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, Accounts.generate_user_session_token(member))

    %{conn: conn, member: member}
  end

  test "the card carries the server's public key for the browser", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings?tab=notifications")
    {:ok, public_key} = WebPush.public_key()
    encoded = Base.url_encode64(public_key, padding: false)

    assert has_element?(view, "#push-alerts[data-public-key='#{encoded}']")
    refute has_element?(view, "#notification-form input[name='notification[push_enabled]']")
  end

  test "the hook's subscription is stored for the member, and removed on turn off", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings?tab=notifications")
    params = push_subscription_params("https://push.site.test/settings")

    render_hook(view, "push_subscribe", params)
    assert [%PushSubscription{user_id: user_id}] = Repo.all(PushSubscription)
    assert user_id == ctx.member.id

    render_hook(view, "push_unsubscribe", %{"endpoint" => "https://push.site.test/settings"})
    assert Repo.all(PushSubscription) == []
  end

  test "the chat page's hook sends the subscription again under its session", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/")
    params = push_subscription_params("https://push.site.test/chat")

    render_hook(view, "push_subscribe", params)

    assert [_live] = Repo.all(Tavern.Chat.PushSubscriptions.live())
  end
end
