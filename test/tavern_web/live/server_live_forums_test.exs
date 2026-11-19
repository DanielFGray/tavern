defmodule TavernWeb.ServerLiveForumsTest do
  @moduledoc """
  A forum channel shows its posts instead of a transcript: as a list or a gallery, sorted by
  activity or creation, filtered by a tag chip or the search, with a New post form that opens the
  new post.
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
    forum = channel_fixture(%{name: "Help", slug: "help", kind: :forum})

    %{conn: conn, me: current_user_from_conn(conn), other: user_fixture(), forum: forum}
  end

  test "lists posts with their author, replies and tags, and no composer", ctx do
    post = new_post(ctx, ctx.other, "Crash on start", "it crashes #bug")
    message_fixture(post, ctx.me, %{body: "same here"})

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")

    assert has_element?(view, "#forum-posts[data-layout=list] #forum-post-#{post.id}")
    assert has_element?(view, "#forum-post-#{post.id}", ctx.other.display_name)
    assert has_element?(view, "#forum-post-replies-#{post.id}", "1 reply")
    assert has_element?(view, "#forum-post-tag-#{post.id}-bug")
    refute has_element?(view, "#message-form")
  end

  test "shows the first message's top reaction", ctx do
    post = new_post(ctx, ctx.other, "Liked", "a good one")
    {:ok, _} = Chat.toggle_reaction(scope_for(ctx.other), post.starter_message_id, "🔥")

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")

    assert has_element?(view, "#forum-post-reaction-#{post.id}", "🔥")
  end

  test "switches to the gallery and remembers it", ctx do
    new_post(ctx, ctx.other, "A post")
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")

    view |> element("#forum-layout-gallery") |> render_click()

    assert has_element?(view, "#forum-posts[data-layout=gallery]")
    assert has_element?(view, "#forum-layout-gallery[aria-pressed=true]")

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")
    assert has_element?(view, "#forum-posts[data-layout=gallery]")
  end

  test "sorts by creation instead of activity", ctx do
    older = new_post(ctx, ctx.other, "Older")
    newer = new_post(ctx, ctx.other, "Newer")
    message_fixture(older, ctx.other, %{body: "bump"})

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")
    assert post_ids(view) == [older.id, newer.id]

    view |> element("#forum-sort-created") |> render_click()
    assert post_ids(view) == [newer.id, older.id]
  end

  test "clicking a tag filters to it, and the search takes #tags and title words", ctx do
    bug = new_post(ctx, ctx.other, "Crash on start", "#bug")
    idea = new_post(ctx, ctx.other, "Dark theme", "#idea")

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")

    view |> element("#forum-post-tag-#{bug.id}-bug") |> render_click()
    assert post_ids(view) == [bug.id]
    assert has_element?(view, "#forum-search input[value='#bug']")

    view |> form("#forum-search", forum_search: %{query: "theme"}) |> render_change()
    assert post_ids(view) == [idea.id]

    view |> form("#forum-search", forum_search: %{query: "#nothing"}) |> render_change()
    assert has_element?(view, "#forum-empty")
  end

  test "a new post opens its thread", ctx do
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")

    view |> element("#new-forum-post") |> render_click()

    view
    |> form("#forum-post-form", post: %{title: "", body: ""})
    |> render_submit()

    assert has_element?(view, "#forum-post-form")

    view
    |> form("#forum-post-form", post: %{title: "How do I #deploy?", body: "Steps please #ops"})
    |> render_submit()

    [_, thread_id] = Regex.run(~r/thread=([0-9a-f-]+)/, assert_patch(view))
    render(view)

    post = Chat.get_thread(scope_for(ctx.me), thread_id)
    assert post.hashtags == ["deploy", "ops"]
    assert has_element?(view, "#thread-panel-#{post.starter_message_id}")
    assert has_element?(view, "#thread-message-list-#{post.starter_message_id}", "Steps please")
    assert has_element?(view, "#thread-reply-count-#{post.starter_message_id}", "0 replies")
  end

  test "the first message of an open post takes a reaction", ctx do
    post = new_post(ctx, ctx.other, "React to me")
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help&thread=#{post.id}")

    id = post.starter_message_id
    view |> element("#open-reaction-picker-#{id}") |> render_click()
    thumbs = Base.url_encode64("👍", padding: false)
    view |> element("#reaction-picker-default-#{id}-#{thumbs}") |> render_click()

    assert [%{emoji_unicode: "👍"}] =
             Chat.get_message(scope_for(ctx.me), post.starter_message_id).reactions
  end

  test "the list shows active posts and the Archived tab shows archived ones", ctx do
    open = new_post(ctx, ctx.other, "Still open")
    closed = new_post(ctx, ctx.other, "Wrapped up")
    {:ok, _} = Chat.archive_thread(scope_for(ctx.other), closed.id)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")

    assert post_ids(view) == [open.id]
    assert has_element?(view, "#forum-tab-active[aria-pressed=true]")

    view |> element("#forum-tab-archived") |> render_click()

    assert post_ids(view) == [closed.id]
    assert has_element?(view, "#forum-tab-archived[aria-pressed=true]")

    view |> form("#forum-search", forum_search: %{query: "still"}) |> render_change()
    assert has_element?(view, "#forum-empty", "No posts match")
  end

  test "an empty Archived tab says so", ctx do
    new_post(ctx, ctx.other, "Still open")
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")

    view |> element("#forum-tab-archived") |> render_click()

    assert has_element?(view, "#forum-empty", "No archived posts")
  end

  test "a post archived or unarchived live moves between the tabs", ctx do
    post = new_post(ctx, ctx.other, "Moving")
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")
    assert post_ids(view) == [post.id]

    {:ok, _} = Chat.archive_thread(scope_for(ctx.other), post.id)
    _ = :sys.get_state(view.pid)
    assert post_ids(view) == []

    view |> element("#forum-tab-archived") |> render_click()
    assert post_ids(view) == [post.id]

    {:ok, _} = Chat.unarchive_thread(scope_for(ctx.other), post.id)
    _ = :sys.get_state(view.pid)
    assert post_ids(view) == []
  end

  test "a post whose first message was deleted stays in the list and hides that message", ctx do
    post = new_post(ctx, ctx.other, "Orphaned", "secret first words")
    message_fixture(post, ctx.me, %{body: "a reply"})
    {:ok, _} = Chat.delete_message(scope_for(ctx.other), post.starter_message_id)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help")
    assert post_ids(view) == [post.id]

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help&thread=#{post.id}")
    assert has_element?(view, "#thread-message-list-#{post.starter_message_id}", "a reply")
    refute render(view) =~ "secret first words"
  end

  defp new_post(ctx, author, title, body \\ "first message") do
    {:ok, post} =
      Chat.create_forum_post(scope_for(author), ctx.forum.id, %{"title" => title, "body" => body})

    post
  end

  defp post_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#forum-posts > li")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "forum-post-", ""))
  end
end
