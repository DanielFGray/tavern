defmodule TavernWeb.ServerLiveDeletedStarterTest do
  @moduledoc """
  A deleted starter keeps its thread. In a text channel its row becomes a tombstone under which the
  chip and the open panel stay; the thread is titled "Deleted message", and no deleted text shows.
  A deleted message that starts no thread leaves the channel as before.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    general = channel_by_slug!("general")
    me = current_user_from_conn(conn)

    moderator = user_fixture()

    role =
      role_fixture(%{
        permissions: PermissionBits.combine([:view_channel, :send_messages, :manage_messages])
      })

    member_role_fixture(moderator, role)

    starter = message_fixture(general, me, %{body: "starter words to delete"})
    thread = thread_fixture(general, starter, me)
    reply = message_fixture(thread, me, %{body: "a reply that stays"})

    %{
      conn: conn,
      me: me,
      moderator: moderator,
      general: general,
      starter: starter,
      thread: thread,
      reply: reply
    }
  end

  test "the author's delete leaves a tombstone with the thread open beneath it", ctx do
    path = ~p"/?channel=general&thread=#{ctx.thread.id}"
    {:ok, view, _html} = live_hydrated(ctx.conn, path)
    assert has_element?(view, "#messages-#{ctx.starter.id}", "starter words to delete")

    view |> element("#open-message-actions-#{ctx.starter.id}") |> render_click()
    view |> element("#prompt-delete-message-#{ctx.starter.id}") |> render_click()
    view |> element("#delete-message-#{ctx.starter.id}") |> render_click()

    assert has_element?(view, "#messages-#{ctx.starter.id}")

    assert has_element?(
             view,
             "#deleted-message-#{ctx.starter.id}",
             "Original message was deleted"
           )

    assert has_element?(view, "#thread-summary-#{ctx.starter.id}")
    assert has_element?(view, "#thread-title-#{ctx.starter.id}", "Deleted message")
    assert has_element?(view, "#thread-title-#{ctx.starter.id}.italic.opacity-60")
    assert has_element?(view, "#thread-panel-#{ctx.starter.id}", "a reply that stays")
    refute render(view) =~ "starter words to delete"
    refute render(view) =~ "[message deleted]"
  end

  test "the reply box still posts into the thread of a deleted starter", ctx do
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{ctx.thread.id}")
    {:ok, _} = Chat.delete_message(scope_for(ctx.me), ctx.starter.id)
    _ = :sys.get_state(view.pid)

    view
    |> form("#thread-message-form", %{message: %{body: "posted after the delete"}})
    |> render_submit()

    assert has_element?(view, "#thread-panel-#{ctx.starter.id}", "posted after the delete")
    assert has_element?(view, "#thread-reply-count-#{ctx.starter.id}", "2 replies")
  end

  test "another open view turns its row into the tombstone and retitles the thread", ctx do
    {:ok, watcher, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    assert has_element?(watcher, "#sidebar-thread-#{ctx.thread.id}", "starter words to delete")

    {:ok, _} = Chat.delete_message(scope_for(ctx.me), ctx.starter.id)
    _ = :sys.get_state(watcher.pid)

    assert has_element?(watcher, "#messages-#{ctx.starter.id}")
    assert has_element?(watcher, "#deleted-message-#{ctx.starter.id}")
    assert has_element?(watcher, "#sidebar-thread-#{ctx.thread.id}", "Deleted message")
    refute render(watcher) =~ "starter words to delete"

    watcher |> element("#open-thread-browser") |> render_click()
    assert has_element?(watcher, "#thread-browser-open-#{ctx.thread.id}", "Deleted message")
    assert has_element?(watcher, "#thread-browser-open-#{ctx.thread.id}.italic")
  end

  test "Delete thread removes the tombstone from every open view", ctx do
    {:ok, watcher, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{ctx.thread.id}")
    {:ok, _} = Chat.delete_message(scope_for(ctx.me), ctx.starter.id)
    assert has_element?(watcher, "#messages-#{ctx.starter.id}")

    {:ok, _} = Chat.delete_thread(scope_for(ctx.moderator), ctx.thread.id)
    _ = :sys.get_state(watcher.pid)

    refute has_element?(watcher, "#messages-#{ctx.starter.id}")
    refute has_element?(watcher, "#thread-summary-#{ctx.starter.id}")
    refute has_element?(watcher, "#sidebar-thread-#{ctx.thread.id}")
    assert has_element?(watcher, "#flash-info", "Thread deleted")
  end

  test "a deleted message that starts no thread leaves the channel", ctx do
    plain = message_fixture(ctx.general, ctx.me, %{body: "plain words"})
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    assert has_element?(view, "#messages-#{plain.id}", "plain words")

    {:ok, _} = Chat.delete_message(scope_for(ctx.me), plain.id)
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#messages-#{plain.id}")
    refute render(view) =~ "Original message was deleted"
  end
end
