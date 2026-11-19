defmodule Tavern.Chat.AuditLog do
  @moduledoc """
  Writes and reads the audit log. These are the only functions that touch `audit_log_entries`.
  The event log design (`docs/design/event-log.md`) moves the log into the events table, and that
  change touches this module alone.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @page_size 50

  @doc """
  One page of the audit log, newest first: `{:ok, %{entries: entries, next_cursor: cursor}}`.
  `next_cursor` is `nil` on the last page; pass it back as `cursor` for the next one. The cursor
  is the `{inserted_at, id}` of the last entry, so a write between two pages never shifts one.
  A scope without `view_audit_log` gets `{:error, :forbidden}`.

  `filters` is a map with any of `:actor_user_id`, `:action_type`, `:from` and `:to` (dates,
  inclusive, in UTC). Blank values are ignored; a malformed actor id is `{:error, :not_found}`.
  """
  def list_entries(%Scope{} = scope, filters \\ %{}, cursor \\ nil) do
    if Visibility.can?(scope, :view_audit_log, :server) do
      with {:ok, query} <- apply_filters(AuditLogEntry, filters) do
        entries =
          query
          |> after_cursor(cursor)
          |> order_by([entry], desc: entry.inserted_at, desc: entry.id)
          |> limit(^(@page_size + 1))
          |> preload([:actor_user, :subject_user, :channel])
          |> Repo.all()

        {page, rest} = Enum.split(entries, @page_size)
        next_cursor = if rest != [], do: cursor_of(List.last(page))

        {:ok, %{entries: page, next_cursor: next_cursor}}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  The members who appear as the actor of an audit entry, by username, for the page's filter. A
  scope without `view_audit_log` gets `{:error, :forbidden}`.
  """
  def list_actors(%Scope{} = scope) do
    if Visibility.can?(scope, :view_audit_log, :server) do
      actors =
        from(user in User,
          where: user.id in subquery(from(entry in AuditLogEntry, select: entry.actor_user_id)),
          order_by: user.username
        )
        |> Repo.all()

      {:ok, actors}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Writes one audit entry and returns it. Callers run it inside the transaction of the change it
  records, so the entry commits or rolls back with that change.

  `actor_id` is who acted and may be `nil` for a system action. `subject_user_id` is the member the
  action concerns, or `nil`. `target` is `{target_type, target_id}`, the thing the action was done
  to. Options: `:metadata` (a map, default `%{}`) and `:reason`. A channel target also sets the
  entry's `channel_id`, which the reader uses to name the channel.
  """
  def record!(actor_id, action_type, subject_user_id, {target_type, target_id}, opts \\ []) do
    %AuditLogEntry{}
    |> AuditLogEntry.changeset(%{
      action_type: action_type,
      actor_user_id: actor_id,
      subject_user_id: subject_user_id,
      channel_id: if(target_type == "channel", do: target_id),
      target_type: target_type,
      target_id: target_id,
      reason: Keyword.get(opts, :reason),
      metadata: Keyword.get(opts, :metadata, %{})
    })
    |> Repo.insert!()
  end

  defp cursor_of(%AuditLogEntry{inserted_at: inserted_at, id: id}), do: {inserted_at, id}

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {inserted_at, id}) do
    where(
      query,
      [entry],
      entry.inserted_at < ^inserted_at or (entry.inserted_at == ^inserted_at and entry.id < ^id)
    )
  end

  defp apply_filters(query, filters) do
    Enum.reduce_while(filters, {:ok, query}, fn
      {_key, value}, acc when value in [nil, ""] ->
        {:cont, acc}

      {:actor_user_id, id}, {:ok, query} ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> {:cont, {:ok, where(query, [entry], entry.actor_user_id == ^id)}}
          :error -> {:halt, {:error, :not_found}}
        end

      {:action_type, type}, {:ok, query} ->
        {:cont, {:ok, where(query, [entry], entry.action_type == ^type)}}

      {:from, %Date{} = from}, {:ok, query} ->
        from = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
        {:cont, {:ok, where(query, [entry], entry.inserted_at >= ^from)}}

      {:to, %Date{} = to}, {:ok, query} ->
        before = DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC")
        {:cont, {:ok, where(query, [entry], entry.inserted_at < ^before)}}

      {_key, _value}, acc ->
        {:cont, acc}
    end)
  end
end
