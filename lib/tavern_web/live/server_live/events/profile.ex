defmodule TavernWeb.ServerLive.Events.Profile do
  @moduledoc """
  The profile card. The client asks for one member's card when a name, an avatar or an @mention
  opens it, and closes it again. The server keeps at most one card, so a newer request replaces
  the older one. Its "Message" button opens the direct message with the member.
  """

  use TavernWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Tavern.Accounts
  alias Tavern.Chat

  @events ~w(show_profile hide_profile message_member)

  def events, do: @events

  def handle_event("show_profile", params, socket) do
    card =
      case ref(params) do
        nil -> nil
        ref -> Accounts.get_profile(socket.assigns.current_scope, ref)
      end

    {:noreply, assign(socket, :profile_card, card)}
  end

  def handle_event("hide_profile", _params, socket),
    do: {:noreply, assign(socket, :profile_card, nil)}

  def handle_event("message_member", %{"user-id" => user_id}, socket) do
    socket = assign(socket, :profile_card, nil)

    case Chat.open_direct_message(socket.assigns.current_scope, user_id) do
      {:ok, dm} ->
        {:noreply, push_patch(socket, to: ~p"/?dm=#{dm.id}")}

      {:error, :not_available} ->
        {:noreply, put_flash(socket, :error, "You can't message this member.")}
    end
  end

  defp ref(%{"user_id" => id}) when is_binary(id), do: {:id, id}
  defp ref(%{"username" => username}) when is_binary(username), do: {:username, username}
  defp ref(_params), do: nil
end
