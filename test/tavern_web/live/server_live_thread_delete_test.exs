defmodule TavernWeb.ServerLiveThreadDeleteTest do
  @moduledoc """
  Deleting a thread from its panel menu: a `manage_messages` holder may, and every open view drops
  the thread. Deleting only the starter message keeps it.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

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

    starter = message_fixture(general, me, %{body: "doomed starter"})
    thread = thread_fixture(general, starter, me)
    message_fixture(thread, me, %{body: "a doomed reply"})

    %{
      conn: conn,
      me: me,
      moderator: moderator,
      general: general,
      starter: starter,
      thread: thread
    }
  end

  test "a manager's delete drops the thread from the deleter's and a follower's views", ctx do
    :ok = Chat.follow_thread(scope_for(ctx.moderator), ctx.thread.id)
    path = ~p"/?channel=general&thread=#{ctx.thread.id}"

    {:ok, deleter, _html} = live_hydrated(conn_for(ctx.moderator), path)
    {:ok, follower, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    {:ok, watcher, _html} = live_hydrated(ctx.conn, path)
    follower |> element("#open-thread-browser") |> render_click()

    for view <- [deleter, follower] do
      assert has_element?(view, "#sidebar-thread-#{ctx.thread.id}")
    end

    assert has_element?(follower, "#thread-summary-#{ctx.starter.id}")
    assert has_element?(follower, "#thread-browser-row-#{ctx.thread.id}")
    assert has_element?(watcher, "#thread-panel-#{ctx.starter.id}")

    deleter |> element("#delete-thread-#{ctx.starter.id}") |> render_click()
    for view <- [deleter, follower, watcher], do: _ = :sys.get_state(view.pid)

    for view <- [deleter, follower, watcher] do
      refute has_element?(view, "#sidebar-thread-#{ctx.thread.id}")
      refute has_element?(view, "#thread-summary-#{ctx.starter.id}")
      refute has_element?(view, "#thread-panel-#{ctx.starter.id}")
      refute has_element?(view, "#thread-browser-row-#{ctx.thread.id}")
    end

    assert has_element?(watcher, "#flash-info", "Thread deleted")
    assert Chat.get_thread(scope_for(ctx.me), ctx.thread.id) == nil
  end

  test "a member without manage_messages sees no Delete thread and is refused", ctx do
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{ctx.thread.id}")

    refute has_element?(view, "#prompt-delete-thread-#{ctx.starter.id}")
    refute has_element?(view, "#delete-thread-#{ctx.starter.id}")

    render_hook(view, "delete_thread", %{})

    assert has_element?(view, "#flash-error", "cannot delete")
    assert Chat.get_thread(scope_for(ctx.me), ctx.thread.id)
  end

  test "deleting only the starter keeps the thread in the sidebar", ctx do
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general")
    {:ok, _} = Chat.delete_message(scope_for(ctx.moderator), ctx.starter.id)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#sidebar-thread-#{ctx.thread.id}")
    assert Chat.get_thread(scope_for(ctx.me), ctx.thread.id)
  end

  describe "Chat.delete_thread/2" do
    test "refuses the thread's creator, who is no manager", ctx do
      assert {:error, :forbidden} = Chat.delete_thread(scope_for(ctx.me), ctx.thread.id)
    end

    test "refuses a channel", ctx do
      assert {:error, :forbidden} = Chat.delete_thread(scope_for(ctx.moderator), ctx.general.id)
    end

    test "records an audit entry and is not restorable", ctx do
      assert {:ok, _} = Chat.delete_thread(scope_for(ctx.moderator), ctx.thread.id)

      assert %AuditLogEntry{action_type: "thread_deleted", actor_user_id: actor_id} =
               Repo.get_by!(AuditLogEntry, channel_id: ctx.thread.id)

      assert actor_id == ctx.moderator.id
      assert {:error, :not_found} = Chat.delete_thread(scope_for(ctx.moderator), ctx.thread.id)

      owner = Repo.get_by!(Tavern.Chat.User, email: "owner-serverlive-default@example.com")
      refute Enum.any?(Chat.list_deleted_channels(scope_for(owner)), &(&1.id == ctx.thread.id))
    end
  end

  defp conn_for(user) do
    token = Tavern.Accounts.generate_user_session_token(user)

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end
end
