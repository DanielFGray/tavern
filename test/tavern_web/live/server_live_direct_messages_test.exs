defmodule TavernWeb.ServerLiveDirectMessagesTest do
  @moduledoc """
  The chat page side of direct messages (docs/design/direct-messages.md): the profile card opens
  a DM at `/?dm=<id>`, the sidebar lists it, and the header names the peer and the privacy line.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn, "dm")
    viewer = current_user_from_conn(conn)
    peer = user_fixture(%{display_name: "Peer Person"})
    %{conn: conn, viewer: viewer, peer: peer}
  end

  test "the profile card's Message button opens the DM with the peer and lists it", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/")
    await_hydration(view)
    render_hook(view, "show_profile", %{"user_id" => ctx.peer.id})

    view |> element("#profile-card-message") |> render_click()

    {:ok, dm} = Chat.open_direct_message(scope_for(ctx.viewer), ctx.peer.id)
    assert_patch(view, ~p"/?dm=#{dm.id}")
    assert has_element?(view, "#direct-message-title h1", "Peer Person")
    assert has_element?(view, "#direct-message-privacy", "Only the two of you")
    refute has_element?(view, "#open-channel-pins")
    assert has_element?(view, "#dm-link-#{dm.id}")
    refute has_element?(view, "#profile-card")
  end

  test "the viewer's own card has no Message button", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/")
    render_hook(view, "show_profile", %{"user_id" => ctx.viewer.id})

    assert has_element?(view, "#profile-card")
    refute has_element?(view, "#profile-card-message")
  end

  test "a refused DM shows one message, whatever the reason", ctx do
    :ok = Chat.block_user(scope_for(ctx.peer), ctx.viewer.id)
    {:ok, view, _html} = live(ctx.conn, ~p"/")
    render_hook(view, "show_profile", %{"user_id" => ctx.peer.id})

    view |> element("#profile-card-message") |> render_click()

    assert has_element?(view, "#flash-error", "You can't message this member.")
    refute has_element?(view, "#direct-message-title")
  end

  test "a DM the peer opens is listed with an unread badge from its first message", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/")
    await_hydration(view)

    {:ok, dm} = Chat.open_direct_message(scope_for(ctx.peer), ctx.viewer.id)
    _ = render(view)
    refute has_element?(view, "#dm-link-#{dm.id}")

    {:ok, _} = Chat.create_message(scope_for(ctx.peer), dm.id, %{"body" => "hello there"})

    assert has_element?(view, "#dm-link-#{dm.id}", "Peer Person")
    assert has_element?(view, "#dm-unread-#{dm.id}", "1")
  end

  test "a DM opens from its address, and its messages show", ctx do
    {:ok, dm} = Chat.open_direct_message(scope_for(ctx.peer), ctx.viewer.id)
    {:ok, message} = Chat.create_message(scope_for(ctx.peer), dm.id, %{"body" => "in the dm"})

    general_rows = messages_in(channel_by_slug!("general").id)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?dm=#{dm.id}")

    assert has_element?(view, "#direct-message-title h1", "Peer Person")
    assert has_element?(view, "#messages-#{message.id}")
    refute has_element?(view, "#dm-unread-#{dm.id}")
    for row <- general_rows, do: refute(has_element?(view, "#messages-#{row.id}"))
  end

  test "a message link opens an old DM message in place, and the present keeps the DM", ctx do
    {:ok, dm} = Chat.open_direct_message(scope_for(ctx.peer), ctx.viewer.id)
    for n <- 1..120, do: message_fixture(dm, ctx.peer, %{body: "dm history #{n}"})
    rows = messages_in(dm.id)
    target = Enum.at(rows, 40)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?dm=#{dm.id}&message=#{target.id}")

    assert has_element?(view, "#messages-#{target.id}")
    refute has_element?(view, "#messages-#{List.last(rows).id}")

    view |> element("#jump-to-present-channel") |> render_click()
    assert_patch(view, ~p"/?dm=#{dm.id}")
    assert has_element?(view, "#messages-#{List.last(rows).id}")
    assert has_element?(view, "#direct-message-title h1", "Peer Person")

    render_patch(view, ~p"/?dm=#{dm.id}&message=#{target.id}")
    view |> form("#message-form", message: %{body: "back to now"}) |> render_submit()
    assert_patch(view, ~p"/?dm=#{dm.id}")
    assert has_element?(view, "#direct-message-title h1", "Peer Person")
  end

  test "the address of a DM the viewer is not in opens nothing", ctx do
    {:ok, dm} = Chat.open_direct_message(scope_for(ctx.peer), user_fixture().id)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?dm=#{dm.id}")

    assert has_element?(view, "#flash-error", "That conversation does not exist.")
    refute has_element?(view, "#direct-message-title")
  end
end
