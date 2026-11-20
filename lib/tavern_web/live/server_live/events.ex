defmodule TavernWeb.ServerLive.Events do
  @moduledoc false

  alias TavernWeb.ServerLive.ChannelEditor
  alias TavernWeb.ServerLive.Events.Forums
  alias TavernWeb.ServerLive.Events.Hydration
  alias TavernWeb.ServerLive.Events.Messages
  alias TavernWeb.ServerLive.Events.Mobile
  alias TavernWeb.ServerLive.Events.Navigation
  alias TavernWeb.ServerLive.Events.Notifications
  alias TavernWeb.ServerLive.Events.Polls
  alias TavernWeb.ServerLive.Events.Reactions
  alias TavernWeb.ServerLive.Events.Threads
  alias TavernWeb.ServerLive.Events.Verification

  require Logger

  @event_modules [
    ChannelEditor,
    Forums,
    Messages,
    Mobile,
    Notifications,
    Polls,
    Reactions,
    Threads,
    Verification
  ]

  # Each event module lists the client events it handles in `events/0`, and an event name routes
  # to the one module that lists it.
  routes = for module <- @event_modules, event <- module.events(), do: {event, module}

  case for({event, count} <- Enum.frequencies_by(routes, &elem(&1, 0)), count > 1, do: event) do
    [] -> :ok
    events -> raise ArgumentError, "events listed by two modules: #{inspect(events)}"
  end

  @event_routes Map.new(routes)

  def handle_params(params, uri, socket) do
    socket = Phoenix.Component.assign(socket, :url_params, params)
    Navigation.handle_params(params, uri, socket)
  end

  def handle_info({:typing_expired, _key, _user_id, _token} = message, socket),
    do: Messages.handle_info(message, socket)

  def handle_info(message, socket)
      when (is_tuple(message) and tuple_size(message) == 2 and
              elem(message, 0) in [:message_created, :message_updated, :message_deleted]) or
             (is_tuple(message) and tuple_size(message) == 3 and
                elem(message, 0) in [:typing_started, :typing_stopped]) do
    Messages.handle_info(message, socket)
  end

  def handle_info(message, socket)
      when message in [:hydrate_navigation, :hydrate_members, :hydrate_unread_state] do
    Hydration.handle_info(message, socket)
  end

  def handle_info(message, socket)
      when message in [:channels_reordered, :roles_changed] or
             (is_tuple(message) and tuple_size(message) == 2 and
                elem(message, 0) in [:channel_created, :channel_updated, :channel_deleted]) do
    Navigation.handle_info(message, socket)
  end

  def handle_info(message, socket)
      when (is_tuple(message) and tuple_size(message) == 2 and
              elem(message, 0) in [:thread_message_created, :thread_message_deleted]) or
             (is_tuple(message) and tuple_size(message) == 3 and
                elem(message, 0) == :thread_followers_changed) do
    Threads.handle_info(message, socket)
  end

  def handle_info(message, socket)
      when is_tuple(message) and tuple_size(message) == 3 and
             elem(message, 0) in [:poll_voted, :poll_closed] do
    Polls.handle_info(message, socket)
  end

  def handle_info({:email_confirmed, _user_id} = message, socket),
    do: Verification.handle_info(message, socket)

  # Only the bot stream reads these; views re-render from the `:message_updated` sent with them.
  def handle_info({event, _message, _reaction}, socket)
      when event in [:reaction_added, :reaction_removed],
      do: {:noreply, socket}

  def handle_event(event, params, socket) do
    case Map.fetch(@event_routes, event) do
      {:ok, module} ->
        module.handle_event(event, params, socket)

      # A client can send any name, and a stale page can send one no longer handled.
      :error ->
        Logger.warning("ServerLive ignored an unknown event: #{inspect(event)}")
        {:noreply, socket}
    end
  end
end
