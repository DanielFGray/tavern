defmodule TavernWeb.ServerLiveHistoryTest do
  @moduledoc """
  A transcript opens on its newest page, and "Load older messages" adds the page before it until
  the start of the conversation, in a channel and in a thread.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap

  @page 50

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    %{conn: conn, me: current_user_from_conn(conn), general: channel_by_slug!("general")}
  end

  test "older pages load one at a time until the channel's first message", ctx do
    fill(ctx.general, ctx.me, 2 * @page + 20)
    [first | _] = rows = messages_in(ctx.general.id)
    {older, newest} = Enum.split(rows, length(rows) - @page)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    assert Enum.all?(newest, &has_element?(view, "#messages-#{&1.id}"))
    refute has_element?(view, "#messages-#{List.last(older).id}")

    view |> element("#load-older-channel") |> render_click()
    assert has_element?(view, "#messages-#{List.last(older).id}")
    refute has_element?(view, "#messages-#{first.id}")

    view |> element("#load-older-channel") |> render_click()
    assert has_element?(view, "#messages-#{first.id}")
    refute has_element?(view, "#load-older-channel")
    assert row_ids(view, "#message-list", "messages") == Enum.map(rows, & &1.id)
  end

  test "a channel that fits on one page offers no older page", ctx do
    fill(ctx.general, ctx.me, @page - length(messages_in(ctx.general.id)))

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    assert has_element?(view, "#messages-#{hd(messages_in(ctx.general.id)).id}")
    refute has_element?(view, "#load-older-channel")
  end

  test "an open thread loads its older replies", ctx do
    starter = message_fixture(ctx.general, ctx.me, %{body: "starter"})
    thread = thread_fixture(ctx.general, starter, ctx.me)
    fill(thread, ctx.me, @page + 5)
    [first | _] = messages_in(thread.id)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{thread.id}")
    refute has_element?(view, "#thread_messages-#{first.id}")

    view |> element("#load-older-thread") |> render_click()
    assert has_element?(view, "#thread_messages-#{first.id}")
    refute has_element?(view, "#load-older-thread")

    assert row_ids(view, "#thread-message-list-#{starter.id}", "thread_messages") ==
             Enum.map(messages_in(thread.id), & &1.id)
  end

  # The message ids of a stream's rows, in DOM order.
  defp row_ids(view, list_selector, stream) do
    view
    |> element(list_selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{list_selector} > [id^='#{stream}-']")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "#{stream}-", ""))
  end

  defp fill(conversation, author, count) do
    for n <- 1..count//1, do: message_fixture(conversation, author, %{body: "history #{n}"})
  end
end
