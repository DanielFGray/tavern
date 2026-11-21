defmodule TavernWeb.ServerLive.Events.Hydration do
  @moduledoc false

  alias TavernWeb.ServerLive.Events.Navigation
  alias TavernWeb.ServerLive.State
  alias TavernWeb.Live.SharedHelpers

  def handle_info(:hydrate_navigation, socket) do
    scope = socket.assigns.current_scope
    custom_emojis = SharedHelpers.emoji_entries_for_picker(scope)

    socket =
      socket
      |> State.hydrate_navigation()
      |> Phoenix.Component.assign(
        :notification_setting,
        Tavern.Chat.get_user_notification_setting(scope)
      )
      |> Phoenix.Component.assign(:custom_emojis, custom_emojis)
      |> Phoenix.Component.assign(
        :custom_emojis_json,
        Jason.encode!(%{
          custom: custom_emojis,
          branding: SharedHelpers.server_branding()
        })
      )
      |> Phoenix.Component.assign(
        :composer_mentions_json,
        Jason.encode!(Tavern.Chat.composer_mentions(socket.assigns.current_scope))
      )
      |> Phoenix.Component.assign(
        :composer_commands_json,
        Jason.encode!(Tavern.Chat.composer_slash_commands())
      )
      |> TavernWeb.ServerLive.Voice.refresh_occupants()

    send(self(), :hydrate_unread_state)

    # The URL was first handled before navigation existed, so resolve its channel and thread now.
    Navigation.handle_params(socket.assigns.url_params, nil, socket)
  end

  def handle_info(:hydrate_unread_state, socket) do
    socket =
      try do
        State.hydrate_unread_state(socket)
      rescue
        DBConnection.ConnectionError -> socket
      end

    {:noreply, socket}
  end

  def handle_info(:hydrate_members, socket) do
    {:noreply, State.hydrate_members(socket)}
  end
end
