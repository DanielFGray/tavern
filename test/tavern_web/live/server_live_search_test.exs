defmodule TavernWeb.ServerLiveSearchTest do
  @moduledoc """
  The message search drawer lists matching messages and opens the conversation that holds one.
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
    %{conn: conn, me: current_user_from_conn(conn), general: channel_by_slug!("general")}
  end

  defp search(view, query) do
    view |> element("#open-message-search") |> render_click()
    view |> form("#message-search-form", message_search: %{query: query}) |> render_change()
  end

  test "a result in a channel opens that channel", ctx do
    other = channel_fixture(%{name: "Elsewhere", slug: "elsewhere"})
    hit = message_fixture(other, ctx.me, %{body: "the kraken wakes"})
    message_fixture(ctx.general, ctx.me, %{body: "nothing to see"})

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    search(view, "krak")

    assert has_element?(view, "#message-search-row-#{hit.id}")
    assert view |> element("#message-search-results li") |> render() =~ "# Elsewhere"

    view |> element("#message-search-open-#{hit.id}") |> render_click()
    assert_patch(view, ~p"/?channel=elsewhere")
    refute has_element?(view, "#message-search")
  end

  test "a result in a thread opens the thread under its channel", ctx do
    starter = message_fixture(ctx.general, ctx.me, %{body: "starter"})
    thread = thread_fixture(ctx.general, starter, ctx.me)
    hit = message_fixture(thread, ctx.me, %{body: "threaded needle"})

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    search(view, "needle")

    view |> element("#message-search-open-#{hit.id}") |> render_click()
    assert_patch(view, ~p"/?channel=general&thread=#{thread.id}")
  end

  test "a result in a forum post opens the post under its forum", ctx do
    forum = channel_fixture(%{name: "Help", slug: "help", kind: :forum})

    {:ok, post} =
      Chat.create_forum_post(scope_for(ctx.me), forum.id, %{
        "title" => "Plan",
        "body" => "starter"
      })

    hit = message_fixture(post, ctx.me, %{body: "forum needle"})

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    search(view, "needle")

    view |> element("#message-search-open-#{hit.id}") |> render_click()
    assert_patch(view, ~p"/?channel=help&thread=#{post.id}")
  end

  test "an empty search and a search with no hits say so; Escape closes", ctx do
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    view |> element("#open-message-search") |> render_click()
    assert has_element?(view, "#message-search-empty")

    search(view, "zzzqqq")
    assert has_element?(view, "#message-search-empty")

    render_keydown(view, "close_message_search", %{"key" => "Escape"})
    refute has_element?(view, "#message-search")
  end
end
