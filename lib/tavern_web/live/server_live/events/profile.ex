defmodule TavernWeb.ServerLive.Events.Profile do
  @moduledoc """
  The profile card. The client asks for one member's card when a name, an avatar or an @mention
  opens it, and closes it again. The server keeps at most one card, so a newer request replaces
  the older one.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tavern.Accounts

  @events ~w(show_profile hide_profile)

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

  defp ref(%{"user_id" => id}) when is_binary(id), do: {:id, id}
  defp ref(%{"username" => username}) when is_binary(username), do: {:username, username}
  defp ref(_params), do: nil
end
