defmodule TavernWeb.AccountDeletionLiveTest do
  @moduledoc """
  The pages around account deletion: Settings > Server kicks a member with deletion scheduled and
  cancels it, the removed page names the date, and a deleted author's messages show as
  "Deleted user" in the chat and in the bot API.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Bots
  alias Tavern.Chat
  alias Tavern.Chat.Membership
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture(%{email: "deletion-owner@example.com", username: "deletion_owner"})
    member = user_fixture(%{email: "deletion-member@example.com", username: "deletion_member"})
    %{owner: owner, member: member}
  end

  describe "Settings > Server" do
    test "kicks a member with deletion scheduled, lists it, and cancels it", ctx do
      {:ok, view, _html} = live(log_in_as(build_conn(), ctx.owner), ~p"/settings?tab=members")

      render_click(element(view, "#open-member-actions-#{ctx.member.id}"))
      assert has_element?(view, "#kick-schedule-deletion-#{ctx.member.id}")

      view
      |> form("#member-action-form-#{ctx.member.id}", %{"moderation" => %{"reason" => "spam"}})
      |> render_submit(%{"moderation" => %{"action" => "kick_schedule_deletion"}})

      refute has_element?(view, "#member-presence-#{ctx.member.id}")
      assert has_element?(view, "#scheduled-deletion-#{ctx.member.id}", "Deletion scheduled for")
      assert Repo.get_by!(Membership, user_id: ctx.member.id).deletion_scheduled_at

      render_click(element(view, "#cancel-deletion-#{ctx.member.id}"))

      refute has_element?(view, "#scheduled-deletion-#{ctx.member.id}")
      assert has_element?(view, "#scheduled-deletion-list-empty")
      assert is_nil(Repo.get_by!(Membership, user_id: ctx.member.id).deletion_scheduled_at)
    end

    test "a member without kick_members sees no scheduled deletions", ctx do
      {:ok, _, _} = Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), ctx.member.id)
      viewer = user_fixture()

      member_role_fixture(
        viewer,
        role_fixture(%{permissions: PermissionBits.combine([:ban_members]), position: 30})
      )

      {:ok, view, _html} = live(log_in_as(build_conn(), viewer), ~p"/settings?tab=members")

      refute has_element?(view, "#scheduled-deletions-panel")
    end
  end

  test "the removed page names the deletion date", ctx do
    {:ok, subject, _} =
      Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), ctx.member.id)

    date = Calendar.strftime(subject.membership.deletion_scheduled_at, "%B %-d, %Y")
    {:ok, view, _html} = live(log_in_as(build_conn(), ctx.member), ~p"/banned")

    assert has_element?(view, "#deletion-scheduled", date)
  end

  test "a deleted author's message shows as Deleted user in the chat", %{conn: conn} do
    conn = log_in_member_user(conn)
    author = user_fixture(%{display_name: "Soon Gone"})
    message = message_fixture(channel_by_slug!("general"), author, %{body: "words that stay"})
    {:ok, _deleted} = Accounts.delete_account(author.id, nil)

    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    assert has_element?(view, "#messages-#{message.id}", "Deleted user")
    assert has_element?(view, "#messages-#{message.id}", "words that stay")
    refute render(view) =~ "Soon Gone"
  end

  test "the bot API serializes a deleted author as Deleted user", ctx do
    role = role_fixture(%{permissions: PermissionBits.combine([:view_channel])})
    bot = bot_fixture(ctx.owner, %{"role_ids" => [role.id]})

    {:ok, %{token: token}} =
      Bots.create_bot_token(scope_for(ctx.owner), bot.id, %{"label" => "read"})

    message = message_fixture(channel_by_slug!("general"), ctx.member, %{body: "kept"})
    {:ok, deleted} = Accounts.delete_account(ctx.member.id, ctx.owner.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/messages/#{message.id}")

    assert %{"data" => %{"body" => "kept", "author" => author}} = json_response(conn, 200)
    assert author["id"] == ctx.member.id
    assert author["display_name"] == "Deleted user"
    assert author["username"] == deleted.username
  end

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end
end
