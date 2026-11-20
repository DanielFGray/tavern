defmodule TavernWeb.ServerLiveThreadRenameTest do
  @moduledoc """
  Renaming a thread from its panel: the creator or a `manage_messages` holder sees the control,
  and the new title shows live in every open view of the thread.
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

    bystander = user_fixture()

    role =
      role_fixture(%{permissions: PermissionBits.combine([:view_channel, :send_messages])})

    member_role_fixture(bystander, role)

    starter = message_fixture(general, bystander, %{body: "an old title"})
    thread = thread_fixture(general, starter, bystander)

    %{conn: conn, me: me, bystander: bystander, starter: starter, thread: thread}
  end

  test "the creator renames, and every view shows the new title", ctx do
    :ok = Chat.follow_thread(scope_for(ctx.bystander), ctx.thread.id)
    path = ~p"/?channel=general&thread=#{ctx.thread.id}"

    {:ok, renamer, _html} = live_hydrated(conn_for(ctx.bystander), path)
    {:ok, watcher, _html} = live_hydrated(ctx.conn, path)
    {:ok, channel_view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    channel_view |> element("#open-thread-browser") |> render_click()

    assert has_element?(renamer, "#rename-thread-#{ctx.starter.id}")
    assert has_element?(renamer, "#sidebar-thread-#{ctx.thread.id}", "an old title")
    assert has_element?(channel_view, "#thread-summary-#{ctx.starter.id}")
    refute has_element?(channel_view, "#thread-summary-title-#{ctx.starter.id}")
    refute has_element?(watcher, "#rename-thread-#{ctx.starter.id}")

    renamer
    |> form("#thread-rename-form-#{ctx.starter.id}", thread_rename: %{name: "A better title"})
    |> render_submit()

    for view <- [renamer, watcher, channel_view], do: _ = :sys.get_state(view.pid)

    for view <- [renamer, watcher] do
      assert has_element?(view, "#thread-title-#{ctx.starter.id}", "A better title")
    end

    assert has_element?(renamer, "#sidebar-thread-#{ctx.thread.id}", "A better title")

    assert has_element?(channel_view, "#thread-summary-title-#{ctx.starter.id}", "A better title")
    assert has_element?(channel_view, "#thread-browser-row-#{ctx.thread.id}", "A better title")
  end

  test "a member who is neither creator nor manager has no control and is refused", ctx do
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{ctx.thread.id}")

    refute has_element?(view, "#thread-rename-form-#{ctx.starter.id}")

    render_hook(view, "rename_thread", %{"thread_rename" => %{"name" => "Hijacked"}})

    assert has_element?(view, "#flash-error", "cannot rename")
    assert Chat.get_thread(scope_for(ctx.me), ctx.thread.id).name == nil
  end

  test "a blank title is refused with a message", ctx do
    {:ok, view, _html} =
      live_hydrated(conn_for(ctx.bystander), ~p"/?channel=general&thread=#{ctx.thread.id}")

    render_hook(view, "rename_thread", %{"thread_rename" => %{"name" => "  "}})

    assert has_element?(view, "#flash-error", "1 to 40")
    assert has_element?(view, "#thread-title-#{ctx.starter.id}", "an old title")
  end

  defp conn_for(user) do
    token = Tavern.Accounts.generate_user_session_token(user)

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end
end
