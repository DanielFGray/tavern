defmodule TavernWeb.SettingsLive.Privacy do
  @moduledoc """
  The Privacy tab of SettingsLive (docs/design/direct-messages.md): who can read direct messages
  on this server, whether members with no DM with the viewer yet may start one, and the accounts
  the viewer blocks, with Unblock.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat

  @events ~w(toggle_direct_messages_from_new_contacts unblock_user)

  def events, do: @events

  def init(socket) do
    socket
    |> assign(:blocked_users, [])
    |> assign(:direct_message_privacy, :private)
  end

  @doc "Reads the block list and the server's DM privacy setting. Called when the tab opens."
  def load(socket) do
    socket
    |> assign(:blocked_users, Chat.list_blocked_users(socket.assigns.current_scope))
    |> assign(:direct_message_privacy, Chat.get_server_settings().direct_message_privacy)
  end

  def handle_event("toggle_direct_messages_from_new_contacts", _params, socket) do
    allowed? = not socket.assigns.current_user.direct_messages_from_new_contacts

    case Chat.set_direct_messages_from_new_contacts(socket.assigns.current_scope, allowed?) do
      {:ok, user} ->
        {:noreply,
         assign(
           socket,
           :current_user,
           %{
             socket.assigns.current_user
             | direct_messages_from_new_contacts: user.direct_messages_from_new_contacts
           }
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save that setting.")}
    end
  end

  def handle_event("unblock_user", %{"id" => user_id}, socket) do
    case Chat.unblock_user(socket.assigns.current_scope, user_id) do
      :ok -> {:noreply, load(socket)}
      {:error, :not_found} -> {:noreply, socket}
    end
  end
end
