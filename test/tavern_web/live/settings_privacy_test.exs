defmodule TavernWeb.SettingsPrivacyTest do
  @moduledoc """
  Settings → Privacy (docs/design/direct-messages.md): the server's DM privacy line, the
  opt-out from DMs started by new contacts, and the block list.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn, "privacy")
    %{conn: conn, me: current_user_from_conn(conn)}
  end

  test "the tab states who can read DMs on this server", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings?tab=privacy")

    assert has_element?(view, "#settings-tab-privacy")
    assert has_element?(view, "#direct-message-privacy-setting", "Only the two people")
  end

  test "turning off new contacts refuses new DMs and keeps the setting", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings?tab=privacy")
    switch = "#toggle-direct-messages-from-new-contacts"
    assert has_element?(view, ~s(#{switch}[aria-checked="true"]))

    view |> element(switch) |> render_click()

    assert has_element?(view, ~s(#{switch}[aria-checked="false"]))
    refute Tavern.Repo.get!(Tavern.Chat.User, ctx.me.id).direct_messages_from_new_contacts

    assert {:error, :not_available} =
             Chat.open_direct_message(scope_for(user_fixture()), ctx.me.id)

    view |> element(switch) |> render_click()
    assert Tavern.Repo.get!(Tavern.Chat.User, ctx.me.id).direct_messages_from_new_contacts
  end

  test "the block list shows each blocked account, and Unblock removes it", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings?tab=privacy")
    assert has_element?(view, "#blocked-users-empty")

    blocked = user_fixture(%{display_name: "Loud Neighbour"})
    :ok = Chat.block_user(scope_for(ctx.me), blocked.id)
    {:ok, view, _html} = live(ctx.conn, ~p"/settings?tab=privacy")

    assert has_element?(view, "#blocked-user-#{blocked.id}", "Loud Neighbour")

    view |> element("#unblock-user-#{blocked.id}") |> render_click()

    refute has_element?(view, "#blocked-user-#{blocked.id}")
    assert Chat.list_blocked_users(scope_for(ctx.me)) == []
  end
end
