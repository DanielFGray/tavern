defmodule TavernWeb.SettingsLive.Audit do
  @moduledoc """
  The Audit log tab of SettingsLive: a filtered, paged stream of audit entries. `Chat` decides who
  may read; a scope without `view_audit_log` sees an empty page.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [stream: 4]

  alias Tavern.Chat

  @events ~w(filter_audit load_more_audit)
  @filter_keys ~w(actor_user_id action_type from to)

  def events, do: @events

  def init(socket) do
    socket
    |> assign(:audit_form, to_form(%{}, as: :audit))
    |> assign(:audit_filters, %{})
    |> assign(:audit_actors, [])
    |> assign(:audit_cursor, nil)
    |> assign(:audit_loaded?, false)
    |> stream(:audit_entries, [], reset: true)
  end

  @doc "Reads the first page with the current filters. Called when the tab opens."
  def load(socket) do
    scope = socket.assigns.current_scope

    case Chat.list_audit_entries(scope, socket.assigns.audit_filters) do
      {:ok, %{entries: entries, next_cursor: cursor}} ->
        socket
        |> assign(:audit_actors, actors(scope))
        |> assign(:audit_cursor, cursor)
        |> assign(:audit_loaded?, true)
        |> stream(:audit_entries, entries, reset: true)

      {:error, _reason} ->
        socket
        |> assign(:audit_cursor, nil)
        |> stream(:audit_entries, [], reset: true)
    end
  end

  def handle_event("filter_audit", %{"audit" => params}, socket) do
    filters = parse_filters(params)

    {:noreply,
     socket
     |> assign(:audit_form, to_form(Map.take(params, @filter_keys), as: :audit))
     |> assign(:audit_filters, filters)
     |> load()}
  end

  def handle_event("load_more_audit", _params, socket) do
    scope = socket.assigns.current_scope
    cursor = socket.assigns.audit_cursor

    case cursor && Chat.list_audit_entries(scope, socket.assigns.audit_filters, cursor) do
      {:ok, %{entries: entries, next_cursor: next_cursor}} ->
        {:noreply,
         socket
         |> assign(:audit_cursor, next_cursor)
         |> stream(:audit_entries, entries, [])}

      _no_cursor_or_refused ->
        {:noreply, socket}
    end
  end

  # Dates that do not parse are dropped, so a half-typed date input filters nothing.
  defp parse_filters(params) do
    %{
      actor_user_id: params["actor_user_id"],
      action_type: params["action_type"],
      from: parse_date(params["from"]),
      to: parse_date(params["to"])
    }
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp actors(scope) do
    case Chat.list_audit_actors(scope) do
      {:ok, actors} -> actors
      {:error, _reason} -> []
    end
  end
end
