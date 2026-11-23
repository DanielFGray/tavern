defmodule TavernWeb.ServerLiveDeletedMessagesTest do
  @moduledoc """
  A deleted message has no row: it leaves every open view at once, and a reply that quoted it says
  the original is deleted. A thread whose starter was deleted stays in the thread browser.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)

    %{
      conn: conn,
      me: current_user_from_conn(conn),
      other: user_fixture(),
      general: channel_by_slug!("general")
    }
  end

  test "a message deleted by someone else leaves an open channel", ctx do
    message = message_fixture(ctx.general, ctx.other, %{body: "short-lived words"})
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")
    assert has_element?(view, "#messages-#{message.id}", "short-lived words")

    {:ok, _} = Chat.delete_message(scope_for(ctx.other), message.id)
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#messages-#{message.id}")
    refute render(view) =~ "short-lived words"
  end

  test "the channel header counts only live messages, and drops on a live delete", ctx do
    kept = message_fixture(ctx.general, ctx.other, %{body: "kept"})
    gone = message_fixture(ctx.general, ctx.other, %{body: "gone"})
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")
    before = Chat.message_count(scope_for(ctx.me), ctx.general.id)
    assert has_element?(view, "#channel-message-count", "#{before} messages")

    {:ok, _} = Chat.delete_message(scope_for(ctx.other), gone.id)
    _ = :sys.get_state(view.pid)

    assert Chat.message_count(scope_for(ctx.me), ctx.general.id) == before - 1
    assert has_element?(view, "#channel-message-count", "#{before - 1} messages")
    assert has_element?(view, "#messages-#{kept.id}")
  end

  test "deleting your own message removes its row", ctx do
    message = message_fixture(ctx.general, ctx.me, %{body: "mine to delete"})
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    view |> element("#open-message-actions-#{message.id}") |> render_click()
    view |> element("#prompt-delete-message-#{message.id}") |> render_click()
    view |> element("#delete-message-#{message.id}") |> render_click()

    refute has_element?(view, "#messages-#{message.id}")
  end

  test "a message deleted in an open thread leaves it", ctx do
    starter = message_fixture(ctx.general, ctx.me, %{body: "starter"})
    thread = thread_fixture(ctx.general, starter, ctx.me)
    reply = message_fixture(thread, ctx.other, %{body: "vanishing reply"})

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{thread.id}")
    assert has_element?(view, "#thread-message-list-#{starter.id}", "vanishing reply")

    {:ok, _} = Chat.delete_message(scope_for(ctx.other), reply.id)
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#thread-message-list-#{starter.id}", "vanishing reply")
  end

  test "a reply to a deleted message keeps its quote line, saying the original is deleted", ctx do
    target = message_fixture(ctx.general, ctx.other, %{body: "quoted original"})

    reply =
      message_fixture(ctx.general, ctx.me, %{body: "my answer", reply_to_id: target.id})

    {:ok, _} = Chat.delete_message(scope_for(ctx.other), target.id)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    assert has_element?(view, "#reply-deleted-#{reply.id}", "Original message deleted")
    refute render(view) =~ "quoted original"
    assert has_element?(view, "#messages-#{reply.id}", "my answer")
  end

  test "a thread whose starter was deleted stays in the thread browser", ctx do
    starter = message_fixture(ctx.general, ctx.other, %{body: "starter to delete"})
    thread = thread_fixture(ctx.general, starter, ctx.other)
    {:ok, _} = Chat.delete_message(scope_for(ctx.other), starter.id)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")
    assert has_element?(view, "#deleted-message-#{starter.id}")

    view |> element("#open-thread-browser") |> render_click()

    assert has_element?(view, "#thread-browser-row-#{thread.id}")
  end
end
