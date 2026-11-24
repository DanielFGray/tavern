defmodule TavernWeb.SendLimitTest do
  @moduledoc """
  The per-member send limit (`Tavern.Chat.SendLimit`) as each client sees it: the browser shows
  a flash, and the bot and user APIs answer 429 with Retry-After.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Bots
  alias Tavern.Chat.PermissionBits
  alias Tavern.RateLimit

  # One message an hour: a test finishes far inside one window, so no count crosses a boundary.
  @windows [{1, 3_600}]

  setup do
    previous = Application.fetch_env!(:tavern, Tavern.Chat.SendLimit)
    Application.put_env(:tavern, Tavern.Chat.SendLimit, windows: @windows)

    on_exit(fn ->
      Application.put_env(:tavern, Tavern.Chat.SendLimit, previous)
      RateLimit.reset!("send:")
    end)
  end

  test "the browser refuses a send over the limit with a flash", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    general = channel_by_slug!("general")
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    view |> form("#message-form", %{message: %{body: "first"}}) |> render_submit()
    refute has_element?(view, "#flash-error")
    assert_push_event(view, "composer:clear", %{draft_key: _})

    view |> form("#message-form", %{message: %{body: "second"}}) |> render_submit()

    assert has_element?(view, "#flash-error", "too fast")
    # The composer keeps the draft, so the member can send it once the wait ends.
    refute_push_event(view, "composer:clear", _payload)

    assert [%{body: "first"}] =
             Enum.filter(messages_in(general.id), &(&1.body in ["first", "second"]))
  end

  describe "the APIs answer 429 with Retry-After" do
    setup do
      owner = owner_fixture()
      speaker = PermissionBits.combine([:view_channel, :send_messages])
      role = role_fixture(%{permissions: speaker})
      channel = channel_fixture(%{name: "Limits", slug: unique_slug()})
      bot = bot_fixture(owner, %{"role_ids" => [role.id]})
      {:ok, %{token: token}} = Bots.create_bot_token(scope_for(owner), bot.id, %{"label" => "l"})
      %{owner: owner, channel: channel, token: token}
    end

    test "the bot API", %{channel: channel, token: token} do
      send = fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/v1/channels/#{channel.id}/messages", %{message: %{body: "hi"}})
      end

      assert json_response(send.(), 201)
      assert_rate_limited(send.())
    end

    test "the user API", %{owner: owner, channel: channel} do
      send = fn ->
        build_conn()
        |> init_test_session(%{})
        |> put_session(:user_token, Tavern.Accounts.generate_user_session_token(owner))
        |> post(~p"/api/v1/user/channels/#{channel.id}/messages", %{message: %{body: "hi"}})
      end

      assert json_response(send.(), 201)
      assert_rate_limited(send.())
    end
  end

  defp assert_rate_limited(conn) do
    assert %{"error" => %{"code" => "rate_limited", "retry_after" => seconds}} =
             json_response(conn, 429)

    assert seconds in 1..3_600
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]
  end
end
