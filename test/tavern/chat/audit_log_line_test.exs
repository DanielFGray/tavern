defmodule Tavern.Chat.AuditLogLineTest do
  use ExUnit.Case, async: true

  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.AuditLogLine
  alias Tavern.Chat.PermissionBits

  @alice %{username: "alice"}
  @bob %{username: "bob"}

  defp entry(action_type, attrs \\ %{}) do
    struct!(
      AuditLogEntry,
      Map.merge(
        %{action_type: action_type, actor_user: @alice, subject_user: @bob, metadata: %{}},
        attrs
      )
    )
  end

  test "every action type with a filter option has a line of its own" do
    for type <- AuditLogLine.action_types() do
      line = AuditLogLine.format(entry(type))
      assert line =~ "@alice", type
      refute line =~ "did #{AuditLogLine.label(type)}", type
    end
  end

  test "member moderation" do
    assert AuditLogLine.format(entry("ban_member", %{reason: "spam"})) ==
             "@alice banned @bob: spam"

    assert AuditLogLine.format(entry("kick_member")) == "@alice kicked @bob"

    assert AuditLogLine.format(entry("unban_member", %{reason: "appeal"})) ==
             "@alice unbanned @bob: appeal"

    assert AuditLogLine.format(entry("timeout_member", %{metadata: %{"duration_minutes" => 10}})) ==
             "@alice timed out @bob for 10 min"
  end

  test "role writes" do
    meta = %{"role_name" => "Mods", "position" => 3}

    assert AuditLogLine.format(entry("role_created", %{metadata: meta})) ==
             "@alice created role Mods"

    assert AuditLogLine.format(entry("role_deleted", %{metadata: meta})) ==
             "@alice deleted role Mods"

    assert AuditLogLine.format(entry("role_moved", %{metadata: meta})) ==
             "@alice moved role Mods to position 3"

    permissions = PermissionBits.combine([:kick_members])

    assert AuditLogLine.format(
             entry("role_updated", %{
               metadata: %{"role_name" => "Mods", "permissions" => permissions}
             })
           ) == "@alice changed role Mods (now: kick_members)"

    assert AuditLogLine.format(entry("role_created", %{metadata: %{}})) ==
             "@alice created role (unknown role)"
  end

  test "member role changes" do
    meta = %{"role_name" => "Mods"}

    assert AuditLogLine.format(entry("member_role_added", %{metadata: meta})) ==
             "@alice gave @bob the role Mods"

    assert AuditLogLine.format(entry("member_role_removed", %{metadata: meta})) ==
             "@alice removed the role Mods from @bob"
  end

  test "channel overwrites name the channel and the bits they touch" do
    meta = %{
      "channel_name" => "general",
      "role_id" => nil,
      "allow" => PermissionBits.combine([:send_messages]),
      "deny" => PermissionBits.combine([:embed_links])
    }

    assert AuditLogLine.format(entry("channel_overwrite_updated", %{metadata: meta})) ==
             "@alice changed permissions for @bob in #general: +send_messages -embed_links"

    assert AuditLogLine.format(
             entry("channel_overwrite_deleted", %{
               channel: %{name: "ops"},
               subject_user: nil,
               metadata: %{"role_id" => Ecto.UUID.generate()}
             })
           ) == "@alice removed permissions for a role in #ops"
  end

  test "bot writes" do
    assert AuditLogLine.format(entry("bot_created")) == "@alice created bot @bob"
    assert AuditLogLine.format(entry("bot_revoked")) == "@alice revoked bot @bob"

    assert AuditLogLine.format(entry("bot_updated", %{metadata: %{"role_ids" => []}})) ==
             "@alice updated bot @bob (roles replaced)"

    assert AuditLogLine.format(entry("bot_token_created")) ==
             "@alice created a token for bot @bob"

    assert AuditLogLine.format(entry("bot_token_revoked")) ==
             "@alice revoked a token of bot @bob"
  end

  test "invite request decisions name the email or the address" do
    assert AuditLogLine.format(
             entry("invite_request_approved", %{
               subject_user: nil,
               metadata: %{"email" => "a@x.test"}
             })
           ) == "@alice approved the invite request from a@x.test"

    assert AuditLogLine.format(
             entry("invite_request_denied", %{
               subject_user: nil,
               metadata: %{"email" => "a@x.test"}
             })
           ) == "@alice denied the invite request from a@x.test"

    assert AuditLogLine.format(
             entry("invite_requests_denied_by_ip", %{
               subject_user: nil,
               metadata: %{"ip_address" => "10.0.0.1", "count" => 3}
             })
           ) == "@alice denied 3 invite requests from 10.0.0.1"
  end

  test "an unknown type gets a generic line, and a missing user is someone" do
    assert AuditLogLine.format(entry("emoji_purged")) == "@alice did emoji purged to @bob"

    assert AuditLogLine.format(entry("emoji_purged", %{actor_user: nil, subject_user: nil})) ==
             "someone did emoji purged"
  end
end
