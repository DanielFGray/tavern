defmodule TavernWeb.ServerLiveThreadFollowTest do
  @moduledoc """
  Followed threads in the sidebar, the Follow button in the thread pane, and the thread browser.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Topics

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

  describe "sidebar" do
    test "lists a followed thread under its channel and counts replies live", ctx do
      thread = new_thread(ctx.general, ctx.me, "Sidebar thread")
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      assert has_element?(view, "#sidebar-threads-general #sidebar-thread-#{thread.id}")
      refute has_element?(view, "#sidebar-thread-unread-#{thread.id}")

      message_fixture(thread, ctx.other, %{body: "first reply"})
      message_fixture(thread, ctx.other, %{body: "second reply"})

      assert has_element?(view, "#sidebar-thread-unread-#{thread.id}", "2")
    end

    test "a reply that reopens an archived thread brings it back with one unread", ctx do
      thread = new_thread(ctx.general, ctx.me, "Reopened")
      {:ok, _} = Chat.archive_thread(scope_for(ctx.me), thread.id)
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      refute has_element?(view, "#sidebar-thread-#{thread.id}")

      message_fixture(thread, ctx.other, %{body: "waking it up"})

      assert has_element?(view, "#sidebar-thread-unread-#{thread.id}", "1")
    end

    test "shows a thread once a mention follows the member", ctx do
      starter = message_fixture(ctx.general, ctx.other, %{body: "their starter"})
      thread = thread_fixture(ctx.general, starter, ctx.other)
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      refute has_element?(view, "#sidebar-thread-#{thread.id}")

      message_fixture(thread, ctx.other, %{body: "look @#{ctx.me.username}"})

      assert has_element?(view, "#sidebar-thread-#{thread.id}")
      assert has_element?(view, "#sidebar-thread-unread-#{thread.id}", "1")
    end

    test "replies read in the open thread stay read after a reload", ctx do
      thread = new_thread(ctx.general, ctx.me, "Read while open")
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{thread.id}")

      message_fixture(thread, ctx.other, %{body: "seen live"})
      message_fixture(thread, ctx.other, %{body: "also seen live"})
      render(view)
      refute has_element?(view, "#sidebar-thread-unread-#{thread.id}")

      Topics.broadcast_server(:roles_changed)

      assert has_element?(view, "#sidebar-thread-#{thread.id}")
      refute has_element?(view, "#sidebar-thread-unread-#{thread.id}")
    end

    test "shows five threads per channel and opens the browser for the rest", ctx do
      threads = for n <- 1..7, do: new_thread(ctx.general, ctx.me, "Many #{n}")
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      shown = Enum.count(threads, &has_element?(view, "#sidebar-thread-#{&1.id}"))
      assert shown == 5
      assert has_element?(view, "#sidebar-threads-more-general", "2 more")

      view |> element("#sidebar-threads-more-general") |> render_click()

      for thread <- threads, do: assert(has_element?(view, "#thread-browser-row-#{thread.id}"))
    end
  end

  describe "follow button" do
    test "unfollow removes the thread from the sidebar and follow brings it back", ctx do
      thread = new_thread(ctx.general, ctx.me, "Toggle thread")
      starter_id = thread.starter_message_id
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{thread.id}")

      assert has_element?(view, "#toggle-follow-thread-#{starter_id}[aria-pressed=true]")

      view |> element("#toggle-follow-thread-#{starter_id}") |> render_click()

      assert has_element?(view, "#toggle-follow-thread-#{starter_id}[aria-pressed=false]")
      refute has_element?(view, "#sidebar-thread-#{thread.id}")
      refute Chat.following_thread?(scope_for(ctx.me), thread.id)

      view |> element("#toggle-follow-thread-#{starter_id}") |> render_click()

      assert has_element?(view, "#toggle-follow-thread-#{starter_id}[aria-pressed=true]")
      assert has_element?(view, "#sidebar-thread-#{thread.id}")
    end

    test "turns to Following when a mention follows the member while the thread is open", ctx do
      thread = new_thread(ctx.general, ctx.other, "Their thread")
      starter_id = thread.starter_message_id
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{thread.id}")

      assert has_element?(view, "#toggle-follow-thread-#{starter_id}[aria-pressed=false]")

      message_fixture(thread, ctx.other, %{body: "over to you @#{ctx.me.username}"})

      assert has_element?(view, "#toggle-follow-thread-#{starter_id}[aria-pressed=true]")
    end
  end

  describe "notifications" do
    test "a mention in a followed thread notifies", ctx do
      thread = new_thread(ctx.general, ctx.me, "Followed")
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      message_fixture(thread, ctx.other, %{body: "hi @#{ctx.me.username}"})

      thread_id = thread.id
      assert_push_event(view, "notify:mention", %{channel_id: ^thread_id})
    end

    test "a muted parent channel silences its followed threads", ctx do
      thread = new_thread(ctx.general, ctx.me, "Muted")
      {:ok, _} = mute(ctx.me, ctx.general)
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      message_fixture(thread, ctx.other, %{body: "hi @#{ctx.me.username}"})
      render(view)

      refute_push_event(view, "notify:mention", %{})
    end

    test "an unfollowed thread notifies on a direct mention only", ctx do
      thread = new_thread(ctx.general, ctx.me, "Unfollowed")
      :ok = Chat.unfollow_thread(scope_for(ctx.me), thread.id)
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      message_fixture(thread, ctx.other, %{body: "no mention here"})
      render(view)
      refute_push_event(view, "notify:mention", %{})

      message_fixture(thread, ctx.other, %{body: "but @#{ctx.me.username} here"})

      thread_id = thread.id
      assert_push_event(view, "notify:mention", %{channel_id: ^thread_id})
      refute has_element?(view, "#sidebar-thread-#{thread.id}")
    end
  end

  describe "thread browser" do
    test "switches tabs, searches titles and follows from a row", ctx do
      active = new_thread(ctx.general, ctx.other, "Dragon tales")
      archived = new_thread(ctx.general, ctx.other, "Dragon archive")
      {:ok, _} = Chat.archive_thread(scope_for(ctx.other), archived.id)
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      view |> element("#open-thread-browser") |> render_click()

      assert has_element?(view, "#thread-browser-row-#{active.id}")
      refute has_element?(view, "#thread-browser-row-#{archived.id}")

      view |> element("#thread-browser-tab-archived") |> render_click()

      assert has_element?(view, "#thread-browser-row-#{archived.id}")
      refute has_element?(view, "#thread-browser-row-#{active.id}")

      view |> element("#thread-browser-tab-active") |> render_click()

      view
      |> form("#thread-browser-search", %{thread_search: %{query: "nothing like it"}})
      |> render_change()

      assert has_element?(view, "#thread-browser-empty")

      view
      |> form("#thread-browser-search", %{thread_search: %{query: "dragon"}})
      |> render_change()

      assert has_element?(view, "#thread-browser-follow-#{active.id}[aria-pressed=false]")

      view |> element("#thread-browser-follow-#{active.id}") |> render_click()

      assert has_element?(view, "#thread-browser-follow-#{active.id}[aria-pressed=true]")
      assert has_element?(view, "#sidebar-thread-#{active.id}")
    end

    test "opens a thread from its row", ctx do
      thread = new_thread(ctx.general, ctx.other, "Open me")
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      view |> element("#open-thread-browser") |> render_click()
      view |> element("#thread-browser-open-#{thread.id}") |> render_click()

      assert_patch(view, ~p"/?channel=general&thread=#{thread.id}")
      refute has_element?(view, "#thread-browser")
    end

    test "opens an archived thread whose starter is older than the loaded page", ctx do
      thread = new_thread(ctx.general, ctx.other, "Old archived")
      {:ok, _} = Chat.archive_thread(scope_for(ctx.other), thread.id)
      for n <- 1..55, do: message_fixture(ctx.general, ctx.other, %{body: "filler #{n}"})
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")

      view |> element("#open-thread-browser") |> render_click()
      view |> element("#thread-browser-tab-archived") |> render_click()
      view |> element("#thread-browser-open-#{thread.id}") |> render_click()
      _html = await_hydration(view)

      assert has_element?(view, "#thread-panel-#{thread.starter_message_id}")
    end

    test "closes when the member can no longer view the channel", ctx do
      _thread = new_thread(ctx.general, ctx.other, "Soon hidden")
      {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
      view |> element("#open-thread-browser") |> render_click()
      assert has_element?(view, "#thread-browser")

      channel_permission_overwrite_fixture(ctx.general, %{
        user_id: ctx.me.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      Topics.broadcast_server(:roles_changed)

      refute has_element?(view, "#thread-browser")
    end
  end

  defp mute(user, channel),
    do:
      Chat.update_channel_membership_notification(user, channel.id, %{
        notification_level: :nothing
      })

  defp new_thread(channel, author, body) do
    starter = message_fixture(channel, author, %{body: body})
    thread_fixture(channel, starter, author)
  end
end
