defmodule TavernWeb.SettingsOwnerDirectMessagesTest do
  @moduledoc """
  Settings → Direct messages, the owner's audited reader (docs/design/direct-messages.md). Not
  async: the privacy setting is cached in `:persistent_term`, which every test shares.
  """
  use TavernWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.ServerSettings
  alias Tavern.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    on_exit(&Chat.reset_server_settings_cache/0)
    ada = user_fixture(%{display_name: "Ada Okapi"})
    bo = user_fixture()
    {:ok, dm} = Chat.open_direct_message(scope_for(ada), bo.id)
    {:ok, message} = Chat.create_message(scope_for(ada), dm.id, %{"body" => "between us"})
    %{owner: owner_fixture(), dm: dm, message: message}
  end

  test "a private server has no Direct messages tab, even by address", ctx do
    {:ok, view, _html} = live(log_in_as(ctx.conn, ctx.owner), ~p"/settings?tab=direct_messages")

    refute has_element?(view, "#settings-tab-direct-messages")
    refute has_element?(view, "#settings-view-direct-messages")
  end

  test "an administrator who is not the owner gets no tab", ctx do
    allow_owner_reading()
    admin = user_fixture()

    member_role_fixture(
      admin,
      role_fixture(%{permissions: PermissionBits.combine([:administrator])})
    )

    {:ok, view, _html} = live(log_in_as(ctx.conn, admin), ~p"/settings?tab=direct_messages")

    refute has_element?(view, "#settings-tab-direct-messages")
    refute has_element?(view, "#settings-view-direct-messages")
  end

  test "the owner lists DMs, and reading one shows it and writes an audit entry", ctx do
    allow_owner_reading()
    {:ok, view, _html} = live(log_in_as(ctx.conn, ctx.owner), ~p"/settings?tab=direct_messages")

    assert has_element?(view, "#owner-dm-#{ctx.dm.id}", "Ada Okapi")
    refute has_element?(view, "#owner-transcript")
    assert reading_count() == 0

    view |> element("#owner-read-dm-#{ctx.dm.id}") |> render_click()

    assert has_element?(view, "#owner-transcript-message-#{ctx.message.id}", "between us")
    assert reading_count() == 1

    view |> element("#owner-transcript-close") |> render_click()
    assert has_element?(view, "#owner-dm-#{ctx.dm.id}")
  end

  defp allow_owner_reading do
    Repo.update_all(ServerSettings, set: [direct_message_privacy: :owner_can_read])
    Chat.reset_server_settings_cache()
  end

  defp reading_count do
    Repo.aggregate(
      from(e in AuditLogEntry, where: e.action_type == "view_direct_message"),
      :count
    )
  end

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end
end
