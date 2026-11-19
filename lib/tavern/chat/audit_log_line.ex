defmodule Tavern.Chat.AuditLogLine do
  @moduledoc """
  One readable line for an `AuditLogEntry`, from its `action_type` and `metadata`. The entry's
  `actor_user`, `subject_user` and `channel` associations must be preloaded.

  Each action type that is written today has a clause; any other type gets a generic line, so a
  new type never crashes the audit page.
  """

  import Bitwise

  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.PermissionBits

  @action_types ~w(timeout_member kick_member ban_member unban_member
                   role_created role_updated role_moved role_deleted
                   member_role_added member_role_removed
                   channel_overwrite_updated channel_overwrite_deleted
                   bot_created bot_updated bot_revoked bot_token_created bot_token_revoked)

  @doc "Action types with their own line, for the page's filter."
  def action_types, do: @action_types

  @doc "The label of an action type: `\"member_role_added\"` is `\"member role added\"`."
  def label(action_type), do: String.replace(action_type, "_", " ")

  def format(%AuditLogEntry{} = entry) do
    actor = handle(entry.actor_user)
    subject = handle(entry.subject_user)
    meta = entry.metadata || %{}
    base = line(entry.action_type, actor, subject, meta, entry)
    base <> reason_suffix(entry.reason)
  end

  defp line("timeout_member", actor, subject, meta, _entry) do
    minutes = meta["duration_minutes"]
    "#{actor} timed out #{subject}" <> if(minutes, do: " for #{minutes} min", else: "")
  end

  defp line("kick_member", actor, subject, _meta, _entry), do: "#{actor} kicked #{subject}"
  defp line("ban_member", actor, subject, _meta, _entry), do: "#{actor} banned #{subject}"
  defp line("unban_member", actor, subject, _meta, _entry), do: "#{actor} unbanned #{subject}"

  defp line("role_created", actor, _subject, meta, _entry),
    do: "#{actor} created role #{role_name(meta)}"

  defp line("role_updated", actor, _subject, meta, _entry) do
    "#{actor} changed role #{role_name(meta)}" <> permissions_suffix(meta["permissions"])
  end

  defp line("role_moved", actor, _subject, meta, _entry) do
    "#{actor} moved role #{role_name(meta)}" <>
      if(meta["position"], do: " to position #{meta["position"]}", else: "")
  end

  defp line("role_deleted", actor, _subject, meta, _entry),
    do: "#{actor} deleted role #{role_name(meta)}"

  defp line("member_role_added", actor, subject, meta, _entry),
    do: "#{actor} gave #{subject} the role #{role_name(meta)}"

  defp line("member_role_removed", actor, subject, meta, _entry),
    do: "#{actor} removed the role #{role_name(meta)} from #{subject}"

  defp line("channel_overwrite_updated", actor, _subject, meta, entry) do
    "#{actor} changed permissions for #{overwrite_target(meta, entry)} in #{channel_name(entry)}" <>
      overwrite_suffix(meta)
  end

  defp line("channel_overwrite_deleted", actor, _subject, meta, entry),
    do:
      "#{actor} removed permissions for #{overwrite_target(meta, entry)} in #{channel_name(entry)}"

  defp line("bot_created", actor, subject, _meta, _entry), do: "#{actor} created bot #{subject}"
  defp line("bot_revoked", actor, subject, _meta, _entry), do: "#{actor} revoked bot #{subject}"

  defp line("bot_updated", actor, subject, meta, _entry) do
    "#{actor} updated bot #{subject}" <>
      if(is_list(meta["role_ids"]), do: " (roles replaced)", else: "")
  end

  defp line("bot_token_created", actor, subject, _meta, _entry),
    do: "#{actor} created a token for bot #{subject}"

  defp line("bot_token_revoked", actor, subject, _meta, _entry),
    do: "#{actor} revoked a token of bot #{subject}"

  defp line(action_type, actor, subject, _meta, _entry) do
    "#{actor} did #{label(action_type)}" <>
      if(subject == "someone", do: "", else: " to #{subject}")
  end

  defp handle(nil), do: "someone"
  defp handle(user), do: "@#{user.username}"

  defp role_name(%{"role_name" => name}) when is_binary(name), do: name
  defp role_name(_meta), do: "(unknown role)"

  defp channel_name(%AuditLogEntry{channel: %{name: name}}), do: "##{name}"
  defp channel_name(%AuditLogEntry{metadata: %{"channel_name" => name}}), do: "##{name}"
  defp channel_name(_entry), do: "a deleted channel"

  defp overwrite_target(%{"role_id" => role_id}, _entry) when is_binary(role_id), do: "a role"
  defp overwrite_target(_meta, %AuditLogEntry{subject_user: nil}), do: "a member"
  defp overwrite_target(_meta, %AuditLogEntry{subject_user: user}), do: handle(user)

  # A role update records the role's permissions after the change, not the change itself.
  defp permissions_suffix(bits) when is_integer(bits) do
    case flags_text(bits, "") do
      "" -> " (no permissions)"
      text -> " (now: #{text})"
    end
  end

  defp permissions_suffix(_bits), do: ""

  defp overwrite_suffix(%{"allow" => allow, "deny" => deny})
       when is_integer(allow) and is_integer(deny) do
    text = [flags_text(allow, "+"), flags_text(deny, "-")] |> Enum.reject(&(&1 == ""))
    if text == [], do: "", else: ": " <> Enum.join(text, " ")
  end

  defp overwrite_suffix(_meta), do: ""

  defp flags_text(bits, sign) do
    PermissionBits.flags()
    |> Enum.filter(fn {_name, bit} -> (bits &&& bit) != 0 end)
    |> Enum.map_join(" ", fn {name, _bit} -> "#{sign}#{name}" end)
  end

  defp reason_suffix(reason) when is_binary(reason) and reason != "", do: ": " <> reason
  defp reason_suffix(_reason), do: ""
end
