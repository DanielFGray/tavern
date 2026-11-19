defmodule TavernWeb.ServerLiveEmbedsTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import Tavern.EmbedTestHelpers
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat

  setup do
    Bootstrap.ensure_seed_data!()
    stub_link_previews(self())
    :ok
  end

  test "the card renders when the fetch completes, and its author can remove it", %{conn: conn} do
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    view
    |> form("#message-form", %{message: %{body: "look https://site.test/a"}})
    |> render_submit()

    await_embed_fetches()

    [message] = Chat.get_messages(scope_for(current_user_from_conn(conn)), latest_message_ids())
    [embed] = message.embeds

    assert has_element?(view, "#embed-#{embed.id}")
    assert has_element?(view, "#embed-title-#{embed.id}[href='https://site.test/a']")
    assert has_element?(view, "#embed-image-#{embed.id}[src^='/uploads/embeds/']")

    view |> element("#remove-embed-#{embed.id}") |> render_click()

    refute has_element?(view, "#embed-#{embed.id}")
    assert Chat.get_message(scope_for(current_user_from_conn(conn)), message.id).embeds == []
  end

  test "a video card shows the stored thumbnail and no player until clicked", %{conn: conn} do
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    view
    |> form("#message-form", %{message: %{body: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}})
    |> render_submit()

    await_embed_fetches()

    [message] = Chat.get_messages(scope_for(current_user_from_conn(conn)), latest_message_ids())
    [embed] = message.embeds

    player = "#embed-player-#{embed.id}[phx-hook][data-video-id='dQw4w9WgXcQ']"
    assert has_element?(view, player)
    assert has_element?(view, "#embed-play-#{embed.id} img[src^='/uploads/embeds/']")
    refute has_element?(view, "#embed-#{embed.id} iframe")
  end

  test "another member's card has no remove button", %{conn: conn} do
    author = user_fixture()
    general = channel_by_slug!("general")
    message_fixture(general, author, %{body: "https://site.test/b"})
    await_embed_fetches()

    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    [embed] =
      Chat.get_messages(scope_for(author), latest_message_ids()) |> hd() |> Map.get(:embeds)

    assert has_element?(view, "#embed-#{embed.id}")
    refute has_element?(view, "#remove-embed-#{embed.id}")
  end

  test "pages allow frames only from this origin and the YouTube no-cookie player", %{
    conn: conn
  } do
    [policy] = conn |> get(~p"/login") |> get_resp_header("content-security-policy")

    assert policy =~ "frame-src 'self' https://www.youtube-nocookie.com;"
    assert policy =~ "frame-ancestors 'self';"
  end

  defp latest_message_ids do
    "general"
    |> channel_by_slug!()
    |> Map.fetch!(:id)
    |> messages_in()
    |> List.last()
    |> List.wrap()
    |> Enum.map(& &1.id)
  end
end
