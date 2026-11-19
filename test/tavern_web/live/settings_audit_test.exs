defmodule TavernWeb.SettingsAuditTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  setup do
    Bootstrap.ensure_seed_data!()

    role =
      role_fixture(%{
        name: "Auditors",
        position: 20,
        permissions: PermissionBits.combine([:view_channel, :view_audit_log])
      })

    auditor = user_fixture()
    member_role_fixture(auditor, role)
    %{auditor: auditor, member: user_fixture(), actor: user_fixture()}
  end

  defp entry!(actor, action_type, offset) do
    base = DateTime.new!(~D[2026-01-01], ~T[12:00:00], "Etc/UTC")

    Repo.insert!(%AuditLogEntry{
      action_type: action_type,
      actor_user_id: actor.id,
      reason: "r#{offset}",
      inserted_at: %{DateTime.add(base, offset, :second) | microsecond: {0, 6}}
    })
  end

  test "the Audit tab is hidden from a member without view_audit_log", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.member), ~p"/settings?tab=audit")

    refute has_element?(view, "#settings-tab-audit")
    refute has_element?(view, "#settings-view-audit")
  end

  test "an auditor sees the log, narrows it with a filter, and loads more", %{conn: conn} = ctx do
    kept = entry!(ctx.actor, "role_created", 0)
    for n <- 1..54, do: entry!(ctx.actor, "role_deleted", n)

    {:ok, view, _html} = live(log_in_as(conn, ctx.auditor), ~p"/settings?tab=audit")
    assert has_element?(view, "#settings-tab-audit")
    assert has_element?(view, "#audit-entries li[id^=audit_entries-]", "deleted role")
    assert has_element?(view, "#audit-load-more")
    refute has_element?(view, "#audit_entries-#{kept.id}")

    view |> element("#audit-load-more") |> render_click()
    assert has_element?(view, "#audit_entries-#{kept.id}")
    refute has_element?(view, "#audit-load-more")

    view
    |> form("#audit-filter-form", audit: %{action_type: "role_created"})
    |> render_change()

    assert has_element?(view, "#audit_entries-#{kept.id}")
    refute has_element?(view, "#audit-entries li", "deleted role")

    view
    |> form("#audit-filter-form", audit: %{action_type: "ban_member"})
    |> render_change()

    refute has_element?(view, "#audit_entries-#{kept.id}")
    assert has_element?(view, "#audit-empty")
  end

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Tavern.Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end
end
