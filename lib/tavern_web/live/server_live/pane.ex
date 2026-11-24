defmodule TavernWeb.ServerLive.Pane do
  @moduledoc """
  One transcript on screen: the open channel's (`:channel`) or the open thread's (`:thread`).
  ServerLive keeps one pane of each kind, in the assign `assign_key/1`, and shows the
  conversation in the assign `conversation_key/1`. A pane's messages live in the LiveView stream
  `stream_name/1`, because a stream cannot sit inside an assign; the stream name prefixes each
  row's DOM id.

  `abilities` is `Tavern.Chat.channel_abilities/2` for the conversation, `form` the composer's
  form, `message_count` the count its header shows and `empty?` whether the stream loaded empty.
  `older_cursor` is the id of the oldest message the stream holds while older ones exist, and nil
  once the stream reaches the start of the conversation.
  """

  import Phoenix.Component, only: [to_form: 2]

  alias Tavern.Chat
  alias Tavern.Chat.Message

  @enforce_keys [:kind, :form, :abilities]
  defstruct [
    :kind,
    :form,
    :abilities,
    :older_cursor,
    typing_users: [],
    message_count: 0,
    empty?: true
  ]

  @kinds [:channel, :thread]

  def kinds, do: @kinds

  @doc "A pane with no conversation loaded."
  def new(kind) when kind in @kinds,
    do: %__MODULE__{kind: kind, form: blank_form(), abilities: Chat.no_channel_abilities()}

  def blank_form, do: %Message{} |> Chat.change_message(%{body: ""}) |> to_form(as: :message)

  def assign_key(:channel), do: :channel_pane
  def assign_key(:thread), do: :thread_pane

  def conversation_key(:channel), do: :active_channel
  def conversation_key(:thread), do: :active_thread

  def stream_name(:channel), do: :messages
  def stream_name(:thread), do: :thread_messages

  def noun(:channel), do: "channel"
  def noun(:thread), do: "thread"

  @doc "Whether the viewer may post in the pane's conversation. A thread reply takes its own bit."
  def can_send?(%__MODULE__{kind: :channel, abilities: abilities}), do: abilities.send_messages

  def can_send?(%__MODULE__{kind: :thread, abilities: abilities}),
    do: abilities.send_messages_in_threads

  @doc """
  The count the pane's header shows. A thread counts its replies, which leave out a forum post's
  opening message.
  """
  def count_messages(scope, :channel, channel_id), do: Chat.message_count(scope, channel_id)
  def count_messages(scope, :thread, thread_id), do: Chat.thread_reply_count(scope, thread_id)
end
