defmodule TavernWeb.SettingsLive.OwnerDirectMessages do
  @moduledoc """
  The Direct messages tab of SettingsLive: the owner's audited reader
  (docs/design/direct-messages.md, Owner reading). It shows only on an `owner_can_read` server,
  to the owner. `Chat` checks both again on every call, and writes an audit entry for every page
  of messages it returns.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat

  @events ~w(read_direct_message load_older_direct_messages close_direct_message)

  def events, do: @events

  def init(socket) do
    socket
    |> assign(:owner_direct_messages, [])
    |> assign(:owner_transcript, nil)
  end

  @doc "Lists every DM with its participants. Reads no message. Called when the tab opens."
  def load(socket) do
    list =
      case Chat.list_direct_messages_for_owner(socket.assigns.current_scope) do
        {:ok, list} -> list
        {:error, :forbidden} -> []
      end

    socket
    |> assign(:owner_direct_messages, list)
    |> assign(:owner_transcript, nil)
  end

  def handle_event("read_direct_message", %{"id" => dm_id}, socket) do
    case Chat.read_direct_message_for_owner(socket.assigns.current_scope, dm_id) do
      {:ok, transcript} ->
        {:noreply, assign(socket, :owner_transcript, transcript)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not open that conversation.")}
    end
  end

  # The cursor stays in the assigns: the client names no position, so it cannot read a page
  # that `Chat` did not just audit.
  def handle_event("load_older_direct_messages", _params, socket) do
    %{dm: dm, next_cursor: cursor, messages: shown} = socket.assigns.owner_transcript

    case cursor && Chat.read_direct_message_for_owner(socket.assigns.current_scope, dm.id, cursor) do
      {:ok, older} ->
        {:noreply,
         assign(socket, :owner_transcript, %{older | messages: older.messages ++ shown})}

      _none ->
        {:noreply, socket}
    end
  end

  def handle_event("close_direct_message", _params, socket),
    do: {:noreply, assign(socket, :owner_transcript, nil)}
end
