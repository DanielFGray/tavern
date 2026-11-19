defmodule Tavern.Chat.AuditLogTest do
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.PermissionBits

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()

    viewer_role =
      role_fixture(%{
        name: "Auditors",
        position: 20,
        permissions: PermissionBits.combine([:view_channel, :view_audit_log])
      })

    viewer = user_fixture()
    member_role_fixture(viewer, viewer_role)
    %{owner: owner, viewer: viewer, member: user_fixture()}
  end

  defp entry!(actor, action_type, inserted_at) do
    Repo.insert!(%AuditLogEntry{
      action_type: action_type,
      actor_user_id: actor.id,
      inserted_at: %{inserted_at | microsecond: {0, 6}}
    })
  end

  defp at(day, second \\ 0),
    do: DateTime.new!(Date.new!(2026, 1, day), Time.new!(12, 0, second), "Etc/UTC")

  test "a scope without view_audit_log is forbidden", %{member: member} do
    assert {:error, :forbidden} = Chat.list_audit_entries(scope_for(member))
    assert {:error, :forbidden} = Chat.list_audit_actors(scope_for(member))
  end

  test "entries come newest first with their actor", ctx do
    old = entry!(ctx.owner, "role_created", at(1))
    new = entry!(ctx.member, "role_deleted", at(2))

    assert {:ok, %{entries: [first, second], next_cursor: nil}} =
             Chat.list_audit_entries(scope_for(ctx.viewer))

    assert {first.id, second.id} == {new.id, old.id}
    assert first.actor_user.id == ctx.member.id
  end

  test "filters narrow by actor, action type and date range", ctx do
    keep = entry!(ctx.owner, "role_created", at(10))
    entry!(ctx.member, "role_created", at(10, 1))
    entry!(ctx.owner, "role_deleted", at(10, 2))
    entry!(ctx.owner, "role_created", at(5))
    entry!(ctx.owner, "role_created", at(20))
    scope = scope_for(ctx.viewer)

    filters = %{
      actor_user_id: ctx.owner.id,
      action_type: "role_created",
      from: ~D[2026-01-10],
      to: ~D[2026-01-10]
    }

    assert {:ok, %{entries: [only]}} = Chat.list_audit_entries(scope, filters)
    assert only.id == keep.id

    assert {:ok, %{entries: entries}} = Chat.list_audit_entries(scope, %{from: ~D[2026-01-10]})
    assert length(entries) == 4

    assert {:ok, %{entries: entries}} = Chat.list_audit_entries(scope, %{to: ~D[2026-01-09]})
    assert length(entries) == 1

    assert {:ok, %{entries: all}} =
             Chat.list_audit_entries(scope, %{actor_user_id: "", action_type: nil})

    assert length(all) == 5

    assert {:error, :not_found} = Chat.list_audit_entries(scope, %{actor_user_id: "nope"})
  end

  test "paging crosses a page boundary without a repeat or a gap, even on equal timestamps",
       ctx do
    same = at(3)
    for _ <- 1..30, do: entry!(ctx.owner, "role_created", same)
    for n <- 1..30, do: entry!(ctx.owner, "role_created", at(4, n))
    scope = scope_for(ctx.viewer)

    assert {:ok, %{entries: page_one, next_cursor: cursor}} = Chat.list_audit_entries(scope)
    assert length(page_one) == 50
    assert cursor

    assert {:ok, %{entries: page_two, next_cursor: nil}} =
             Chat.list_audit_entries(scope, %{}, cursor)

    assert length(page_two) == 10

    ids = Enum.map(page_one ++ page_two, & &1.id)
    assert length(Enum.uniq(ids)) == 60
  end

  test "the actor list holds only members who acted", ctx do
    entry!(ctx.owner, "role_created", at(1))
    assert {:ok, [actor]} = Chat.list_audit_actors(scope_for(ctx.viewer))
    assert actor.id == ctx.owner.id
  end
end
