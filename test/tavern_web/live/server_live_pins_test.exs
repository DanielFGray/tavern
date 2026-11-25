defmodule TavernWeb.ServerLivePinsTest do
  @moduledoc """
  A member who may pin pins a message from its menu. The row shows the pin, a pin line follows,
  and the pins drawer lists the message until it is unpinned. A member who may not pin sees no
  pin action, and other sessions see the change.
  """
  use TavernWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat

  setup do
    Bootstrap.ensure_seed_data!()
    %{general: channel_by_slug!("general")}
  end

  defp open_menu(view, message) do
    view |> element("#open-message-actions-#{message.id}") |> render_click()
  end

  test "pinning marks the row, posts a pin line, and fills the drawer", %{conn: conn} = ctx do
    conn = log_in_owner_user(conn)
    me = current_user_from_conn(conn)
    message = message_fixture(ctx.general, me, %{body: "keep this handy"})

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general")
    refute has_element?(view, "#message-pinned-#{message.id}")

    open_menu(view, message)
    view |> element("#pin-message-#{message.id}") |> render_click()

    assert has_element?(view, "#message-pinned-#{message.id}")
    [line] = pin_lines()
    assert has_element?(view, "#pin-line-open-#{line.id}")

    view |> element("#pin-line-open-#{line.id}") |> render_click()
    assert has_element?(view, "#pins-row-#{message.id}")

    view |> element("#pins-unpin-#{message.id}") |> render_click()
    refute has_element?(view, "#pins-row-#{message.id}")
    assert has_element?(view, "#pins-empty")
    refute has_element?(view, "#message-pinned-#{message.id}")

    view |> element("#close-pins") |> render_click()
    refute has_element?(view, "#pins")
  end

  test "a member without pin_messages sees no pin action or unpin button", %{conn: conn} = ctx do
    conn = log_in_member_user(conn)
    me = current_user_from_conn(conn)
    owner = owner_fixture(%{email: "pins-owner@example.com", username: "pins_owner"})
    {:ok, _} = Chat.create_message(scope_for(owner), ctx.general.id, %{"body" => "theirs"})
    mine = message_fixture(ctx.general, me, %{body: "mine"})
    {:ok, _} = Chat.pin_message(scope_for(owner), mine.id)

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general")
    open_menu(view, mine)
    refute has_element?(view, "#pin-message-#{mine.id}")

    view |> element("#open-channel-pins") |> render_click()
    assert has_element?(view, "#pins-row-#{mine.id}")
    refute has_element?(view, "#pins-unpin-#{mine.id}")
  end

  test "an open drawer follows pins made in another session", %{conn: conn} = ctx do
    conn = log_in_member_user(conn)
    owner = owner_fixture(%{email: "pins-owner@example.com", username: "pins_owner"})
    message = message_fixture(ctx.general, owner, %{body: "breaking news"})

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general")
    view |> element("#open-channel-pins") |> render_click()
    assert has_element?(view, "#pins-empty")

    {:ok, _} = Chat.pin_message(scope_for(owner), message.id)
    assert has_element?(view, "#pins-row-#{message.id}")
    assert has_element?(view, "#message-pinned-#{message.id}")

    {:ok, _} = Chat.delete_message(scope_for(owner), message.id)
    assert has_element?(view, "#pins-empty")
  end

  test "a pin in an open thread lists in the thread's drawer, not the channel's",
       %{conn: conn} = ctx do
    conn = log_in_owner_user(conn)
    me = current_user_from_conn(conn)
    starter = message_fixture(ctx.general, me, %{body: "starter"})
    thread = thread_fixture(ctx.general, starter, me)
    reply = message_fixture(thread, me, %{body: "a reply worth keeping"})

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general&thread=#{thread.id}")
    open_menu(view, reply)
    view |> element("#pin-message-#{reply.id}") |> render_click()

    [line] = pin_lines()
    assert line.channel_id == thread.id
    assert has_element?(view, "#thread-messages-#{starter.id} #pin-line-open-#{line.id}")

    view |> element("#open-thread-pins-#{starter.id}") |> render_click()
    assert has_element?(view, "#pins-row-#{reply.id}")

    view |> element("#close-pins") |> render_click()
    view |> element("#open-channel-pins") |> render_click()
    refute has_element?(view, "#pins-row-#{reply.id}")
    assert has_element?(view, "#pins-empty")
  end

  test "the drawer closes when its conversation is no longer open", %{conn: conn} do
    conn = log_in_owner_user(conn)
    channel_fixture(%{name: "Elsewhere", slug: "elsewhere"})

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general")
    view |> element("#open-channel-pins") |> render_click()
    assert has_element?(view, "#pins")

    render_patch(view, ~p"/?channel=elsewhere")
    refute has_element?(view, "#pins")
  end

  defp pin_lines, do: Tavern.Repo.all(from(m in Tavern.Chat.Message, where: m.kind == :pin))
end
