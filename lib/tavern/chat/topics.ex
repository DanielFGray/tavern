defmodule Tavern.Chat.Topics do
  @moduledoc """
  Owns the PubSub topics for chat events.

  Server-structure events (`:channel_created`, `:channel_updated`, `:channel_deleted`,
  `:channels_reordered`, `:roles_changed`, `{:email_confirmed, user_id}`) go to one server
  topic. Message, reaction and typing events go to the topic of the channel or thread they
  happen in, so only processes subscribed to that channel receive them. A subscriber is
  responsible for subscribing only to channels its user can view.

  Broadcasts skip the calling process: the caller has already applied its own change. The
  server settings event is the exception (see `broadcast_server_settings_changed/0`).

  Callers broadcast after their transaction commits, so each server and channel broadcast also
  goes to `Tavern.ProductEvents`, which emits the product event it stands for, if any. Each
  broadcast happens once, on the writing node, so each event is counted once.
  """

  alias Tavern.ProductEvents

  @pubsub Tavern.PubSub
  @server_topic "chat:server"
  @server_settings_topic "chat:server_settings"

  def subscribe_server, do: Phoenix.PubSub.subscribe(@pubsub, @server_topic)

  def broadcast_server(event) do
    result = Phoenix.PubSub.broadcast_from(@pubsub, self(), @server_topic, event)
    ProductEvents.record(event)
    result
  end

  def broadcast_channel(channel_id, event) do
    result = Phoenix.PubSub.broadcast_from(@pubsub, self(), channel_topic(channel_id), event)
    ProductEvents.record(event)
    result
  end

  @doc """
  Tells every node, the writer's own included, that the committed server settings changed.
  Each node drops its cached copy, so the next read loads the new settings.

  This is a plain broadcast, not `broadcast_from/4`, so a process that subscribes to the topic
  (a test, for one) receives it too. The event carries no settings, so a receiver cannot apply a
  copy that is older than the committed row.
  """
  def broadcast_server_settings_changed do
    Phoenix.PubSub.broadcast(@pubsub, @server_settings_topic, :server_settings_changed)
  end

  def subscribe_server_settings, do: Phoenix.PubSub.subscribe(@pubsub, @server_settings_topic)

  @doc """
  Moves the calling process from the channel topics in `subscribed` to those in `wanted`.

  Returns `wanted`, which the caller keeps as its next `subscribed` set. A topic is subscribed at
  most once, because `Phoenix.PubSub` delivers an event once per subscription.
  """
  def sync_channel_subscriptions(%MapSet{} = subscribed, %MapSet{} = wanted) do
    for channel_id <- MapSet.difference(wanted, subscribed) do
      :ok = Phoenix.PubSub.subscribe(@pubsub, channel_topic(channel_id))
    end

    for channel_id <- MapSet.difference(subscribed, wanted) do
      :ok = Phoenix.PubSub.unsubscribe(@pubsub, channel_topic(channel_id))
    end

    wanted
  end

  defp channel_topic(channel_id), do: "chat:channel:" <> channel_id
end
