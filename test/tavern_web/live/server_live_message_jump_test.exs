defmodule TavernWeb.ServerLiveMessageJumpTest do
  @moduledoc """
  A URL's `message` param opens that message in place: the pane loads the window around it, and
  keeps it until the reader jumps to the present or sends a message.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat

  @page 50
  @half div(@page, 2)

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    me = current_user_from_conn(conn)
    deep = channel_fixture(%{name: "Deep", slug: "deep"})
    for n <- 1..(3 * @page), do: message_fixture(deep, me, %{body: "history #{n}"})
    %{conn: conn, me: me, deep: deep, rows: messages_in(deep.id)}
  end

  test "an old message opens in a window around it, and newer pages load to the present", ctx do
    target = Enum.at(ctx.rows, @page)
    newest = List.last(ctx.rows)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=deep&message=#{target.id}")

    assert has_element?(view, "#messages-#{target.id}")
    assert has_element?(view, "#messages-#{Enum.at(ctx.rows, @page - @half).id}")
    refute has_element?(view, "#messages-#{Enum.at(ctx.rows, @page - @half - 1).id}")
    assert has_element?(view, "#messages-#{Enum.at(ctx.rows, @page + @half).id}")
    refute has_element?(view, "#messages-#{newest.id}")
    assert has_element?(view, "#load-older-channel")
    assert_push_event(view, "message:focus", %{id: id, highlight: true})
    assert id == "messages-#{target.id}"

    view |> element("#load-newer-channel") |> render_click()
    assert has_element?(view, "#load-newer-channel")
    view |> element("#load-newer-channel") |> render_click()
    assert has_element?(view, "#messages-#{newest.id}")
    refute has_element?(view, "#newer-messages-channel")
  end

  test "a window leaves the read marker alone until it reaches the newest message", ctx do
    scope = scope_for(ctx.me)
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=deep")
    assert Chat.unread_counts(scope, [ctx.deep.id])[ctx.deep.id] == 0
    render_patch(view, ~p"/?channel=general")
    message_fixture(ctx.deep, user_fixture(), %{body: "while away"})

    render_patch(view, ~p"/?channel=deep&message=#{hd(ctx.rows).id}")
    assert Chat.unread_counts(scope, [ctx.deep.id])[ctx.deep.id] == 1
  end

  test "a live message waits for the present, and Jump to present shows it", ctx do
    target = Enum.at(ctx.rows, @page)
    other = user_fixture()

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=deep&message=#{target.id}")
    live = message_fixture(ctx.deep, other, %{body: "fresh off the press"})
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#messages-#{live.id}")

    view |> element("#jump-to-present-channel") |> render_click()
    assert_patch(view, ~p"/?channel=deep")
    assert has_element?(view, "#messages-#{live.id}")
    refute has_element?(view, "#messages-#{target.id}")
    refute has_element?(view, "#newer-messages-channel")
  end

  test "a URL without a message keeps the window, so a thread or Back keeps the place", ctx do
    target = Enum.at(ctx.rows, @page)
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=deep&message=#{target.id}")

    render_patch(view, ~p"/?channel=deep")
    assert has_element?(view, "#messages-#{target.id}")
    assert has_element?(view, "#newer-messages-channel")
  end

  test "sending from a window returns to the present with the sent message", ctx do
    target = Enum.at(ctx.rows, @page)
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=deep&message=#{target.id}")

    view |> form("#message-form", message: %{body: "back to now"}) |> render_submit()
    assert_patch(view, ~p"/?channel=deep")

    [sent] = Enum.filter(messages_in(ctx.deep.id), &(&1.body == "back to now"))
    assert has_element?(view, "#messages-#{sent.id}")
    refute has_element?(view, "#newer-messages-channel")
  end

  test "an unavailable message shows the newest page and says so", ctx do
    elsewhere = message_fixture(channel_by_slug!("general"), ctx.me, %{body: "not here"})

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=deep&message=#{elsewhere.id}")

    assert has_element?(view, "#messages-#{List.last(ctx.rows).id}")
    refute has_element?(view, "#newer-messages-channel")
    assert render(view) =~ "That message is not available."
  end

  test "a change to a message outside the loaded pages does not add it to the end", ctx do
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=deep")
    old = hd(ctx.rows)

    {:ok, _} = Chat.update_message(scope_for(ctx.me), old.id, %{body: "edited long ago"})
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#messages-#{old.id}")
  end

  test "a reply preview and a pinned message open the message they name", ctx do
    target = Enum.at(ctx.rows, 5)
    owner = owner_fixture()

    {:ok, reply} =
      Chat.create_message(scope_for(ctx.me), ctx.deep.id, %{
        "body" => "answering",
        "reply_to_id" => target.id
      })

    {:ok, _pin} = Chat.pin_message(scope_for(owner), target.id)

    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=deep")
    view |> element("#reply-jump-#{reply.id}") |> render_click()
    assert_patch(view, ~p"/?channel=deep&message=#{target.id}")
    assert has_element?(view, "#messages-#{target.id}")

    render_patch(view, ~p"/?channel=deep")
    view |> element("#open-channel-pins") |> render_click()
    view |> element("#pins-open-#{target.id}") |> render_click()
    assert_patch(view, ~p"/?channel=deep&message=#{target.id}")
    refute has_element?(view, "#pins-list")
  end

  test "a message in a thread opens the thread, with its starter in the channel", ctx do
    starter = Enum.at(ctx.rows, 10)
    thread = thread_fixture(ctx.deep, starter, ctx.me)
    hit = message_fixture(thread, ctx.me, %{body: "deep in the thread"})

    {:ok, view, _html} =
      live_hydrated(ctx.conn, ~p"/?channel=deep&thread=#{thread.id}&message=#{hit.id}")

    assert has_element?(view, "#messages-#{starter.id}")
    assert has_element?(view, "#thread_messages-#{hit.id}")
    assert_push_event(view, "message:focus", %{id: id, highlight: true})
    assert id == "thread_messages-#{hit.id}"
  end
end
