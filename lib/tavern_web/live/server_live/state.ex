defmodule TavernWeb.ServerLive.State do
  @moduledoc false

  use TavernWeb, :html

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  import Phoenix.LiveView,
    only: [
      connected?: 1,
      push_event: 3,
      push_patch: 2,
      stream: 4,
      stream_delete: 3,
      stream_insert: 3
    ]

  alias Tavern.Accounts
  alias Tavern.Chat
  alias Tavern.Chat.Message
  alias Tavern.Chat.Topics
  alias TavernWeb.ServerLive.ChannelEditor
  alias TavernWeb.ServerLive.ForumNav
  alias TavernWeb.ServerLive.ThreadNav

  def queue_initial_hydration(socket) do
    if connected?(socket) do
      send(self(), :hydrate_navigation)
      send(self(), :hydrate_members)
      socket
    else
      socket
    end
  end

  def hydrate_navigation(socket) do
    visible_channels = Chat.list_channels(socket.assigns.current_scope)
    channels = Enum.filter(visible_channels, &visible_text_channel?/1)
    :ok = Chat.ensure_channel_memberships(socket.assigns.current_scope, channels)

    socket
    |> assign(:channels, channels)
    |> assign(:channel_sections, Chat.build_channel_tree(visible_channels))
    |> assign(:navigation_ready?, true)
    |> sync_active_channel(channels)
    |> sync_channel_subscriptions()
    |> ThreadNav.refresh_followed_threads()
    |> ChannelEditor.refresh()
  end

  @doc """
  Subscribes the socket to the topics of its listed channels, the active channel and the active
  thread, and unsubscribes it from all other channel topics.

  The subscription set is the only filter between channel events and this socket, so each
  function that changes `:channels`, `:active_channel` or `:active_thread` calls this.
  """
  def sync_channel_subscriptions(socket) do
    if connected?(socket) do
      %{channels: channels, active_channel: active_channel, active_thread: active_thread} =
        socket.assigns

      wanted =
        [active_channel, active_thread | channels]
        |> Enum.reject(&is_nil/1)
        |> MapSet.new(& &1.id)

      assign(
        socket,
        :subscribed_channel_ids,
        Topics.sync_channel_subscriptions(socket.assigns.subscribed_channel_ids, wanted)
      )
    else
      socket
    end
  end

  def hydrate_unread_state(socket) do
    socket
    |> refresh_unread_counts()
    |> refresh_unread_mentions()
  end

  def hydrate_members(socket) do
    socket
    |> assign(:member_presence, Accounts.list_members(socket.assigns.current_scope))
    |> assign(:members_ready?, true)
  end

  def assign_message_form(socket) do
    form =
      %Message{}
      |> Chat.change_message(%{body: ""})
      |> to_form(as: :message)

    assign(socket, :message_form, form)
  end

  def assign_thread_message_form(socket) do
    form =
      %Message{}
      |> Chat.change_message(%{body: ""})
      |> to_form(as: :message)

    assign(socket, :thread_message_form, form)
  end

  def load_channel(socket, channel, opts \\ []) do
    messages =
      case Chat.list_messages(socket.assigns.current_scope, channel.id) do
        {:ok, messages} -> messages
        {:error, :not_found} -> []
      end

    last_message = List.last(messages)
    Chat.mark_channel_read(socket.assigns.current_user, channel, last_message)
    thread_summaries = Chat.thread_summaries_for_channel(socket.assigns.current_scope, channel.id)

    visible_channels = Keyword.get(opts, :visible_channels)
    refreshed_channels = Keyword.get(opts, :channels)

    visible_channels =
      visible_channels || Chat.list_channels(socket.assigns.current_scope)

    refreshed_channels =
      refreshed_channels || Enum.filter(visible_channels, &visible_text_channel?/1)

    refreshed_active_channel = Enum.find(refreshed_channels, &(&1.id == channel.id)) || channel

    unread_counts =
      Keyword.get(opts, :unread_counts) ||
        Chat.unread_counts_for_user(socket.assigns.current_user, refreshed_channels)

    unread_mentions =
      Keyword.get(opts, :unread_mentions) ||
        Chat.unread_mentions_for_user(socket.assigns.current_user, refreshed_channels)

    active_thread = reloaded_active_thread(socket, refreshed_active_channel)

    socket
    |> assign(:channels, refreshed_channels)
    |> assign(:channel_sections, Chat.build_channel_tree(visible_channels))
    |> assign(:navigation_ready?, true)
    |> assign(:mobile_sidebar_open?, false)
    |> assign(:mobile_members_open?, false)
    |> close_message_ui()
    |> assign(:active_channel, refreshed_active_channel)
    |> assign(:thread_summaries, thread_summaries)
    |> assign(
      :typing_users,
      Chat.list_typing_users(socket.assigns.current_scope, refreshed_active_channel.id)
    )
    |> assign(
      :channel_abilities,
      Chat.channel_abilities(socket.assigns.current_scope, refreshed_active_channel.id)
    )
    |> assign(
      :message_count,
      Chat.message_count(socket.assigns.current_scope, refreshed_active_channel.id)
    )
    |> assign(:messages_empty?, messages == [])
    |> assign(:unread_counts, unread_counts)
    |> assign(:unread_mentions, unread_mentions)
    |> stream(:messages, messages, reset: true)
    |> ForumNav.load(refreshed_active_channel)
    |> sync_channel_subscriptions()
    |> maybe_restore_thread(active_thread)
  end

  def redirect_to_default_channel(socket) do
    case List.first(socket.assigns.channels) do
      nil -> socket
      channel -> push_patch(socket, to: channel_path(channel))
    end
  end

  def refresh_channels(socket) do
    visible_channels = Chat.list_channels(socket.assigns.current_scope)
    channels = Enum.filter(visible_channels, &visible_text_channel?/1)

    active_channel =
      case socket.assigns.active_channel do
        nil -> nil
        active -> Enum.find(channels, &(&1.id == active.id))
      end

    socket
    |> assign(:channels, channels)
    |> assign(:channel_sections, Chat.build_channel_tree(visible_channels))
    |> assign(:navigation_ready?, true)
    |> assign(:active_channel, active_channel)
    |> close_message_ui()
    |> assign(:channel_abilities, active_channel_abilities(socket, active_channel))
    |> sync_channel_subscriptions()
    |> ThreadNav.reload()
    |> ForumNav.reload()
    |> ChannelEditor.refresh()
  end

  @doc """
  Tells the browser that these DOM ids entered while the member watches (a live message, an
  opened thread panel, a new thread pill), so it animates them. Loads, channel switches,
  restored threads and re-renders never call this, so they never animate.
  """
  def push_entered(socket, ids), do: push_event(socket, "entered", %{ids: ids})

  def thread_panel_dom_id(thread), do: "thread-panel-#{thread.starter_message_id}"

  def maybe_insert_message(socket, message) do
    active_channel = socket.assigns.active_channel

    cond do
      is_nil(active_channel) ->
        socket

      active_channel.id != message.channel_id ->
        socket

      true ->
        socket
        |> assign(:messages_empty?, false)
        |> assign(:message_count, socket.assigns.message_count + 1)
        |> stream_insert(:messages, message)
        |> push_entered(["messages-#{message.id}"])
    end
  end

  def maybe_insert_thread_message(socket, message) do
    active_thread = socket.assigns.active_thread

    cond do
      is_nil(active_thread) ->
        socket

      active_thread.id != message.channel_id ->
        socket

      true ->
        starter_message_id = active_thread.starter_message_id
        # The member is reading the open thread, so its sidebar badge must not return on reload.
        Chat.mark_channel_read(socket.assigns.current_user, active_thread, message)

        socket
        |> assign(:thread_messages_empty?, false)
        |> assign(:thread_message_count, socket.assigns.thread_message_count + 1)
        |> stream_insert(:thread_messages, message)
        |> push_entered(["thread_messages-#{message.id}"])
        |> refresh_thread_summaries_for_active_channel()
        |> rerender_messages([starter_message_id])
    end
  end

  @doc """
  Shows a changed message in the stream that lists it: the open thread's or the open channel's.
  A change to a thread message can change the reply count (a delete), so the count and the
  channel's thread summaries are read again, and the starter's row, which holds the thread,
  renders again.
  """
  def stream_update_message(socket, %Message{channel_id: channel_id} = message) do
    case socket.assigns do
      %{active_thread: %{id: ^channel_id} = thread} ->
        socket
        |> stream_message(:thread_messages, message)
        |> assign(
          :thread_message_count,
          Chat.thread_reply_count(socket.assigns.current_scope, thread.id)
        )
        |> refresh_thread_summaries_for_active_channel()
        |> rerender_active_thread_panel()

      %{active_channel: %{id: ^channel_id}} ->
        socket
        |> stream_message(:messages, message)
        |> assign(:message_count, Chat.message_count(socket.assigns.current_scope, channel_id))

      _other ->
        socket
    end
  end

  # A deleted message has no row in any list: it leaves the stream instead of rendering again.
  defp stream_message(socket, name, %Message{} = message) do
    if Message.deleted?(message),
      do: stream_delete(socket, name, message),
      else: stream_insert(socket, name, message)
  end

  def maybe_refresh_thread_summaries(socket, channel) do
    active_channel = socket.assigns.active_channel

    cond do
      is_nil(active_channel) ->
        socket

      channel.parent_channel_id == active_channel.id ->
        socket
        |> refresh_thread_summaries_for_active_channel()
        |> rerender_messages([channel.starter_message_id])

      true ->
        socket
    end
  end

  def refresh_unread_counts(socket) do
    assign(
      socket,
      :unread_counts,
      Chat.unread_counts_for_user(socket.assigns.current_user, socket.assigns.channels)
    )
  end

  def refresh_unread_mentions(socket) do
    assign(
      socket,
      :unread_mentions,
      Chat.unread_mentions_for_user(socket.assigns.current_user, socket.assigns.channels)
    )
  end

  def refresh_member_presence(socket) do
    socket
    |> assign(:member_presence, Accounts.list_members(socket.assigns.current_scope))
    |> assign(:members_ready?, true)
  end

  def close_message_ui(socket) do
    socket
    |> assign(:reaction_picker_message_id, nil)
    |> assign(:active_message_controls_id, nil)
    |> assign(:message_action_menu_id, nil)
    |> assign(:delete_confirmation_message_id, nil)
  end

  @doc """
  The message a client event names, when it belongs to the channel or thread the user has open.
  The client can send any id, and the open conversation is one the user can view, so a message
  event acts only on a message found here.
  """
  def fetch_open_message(socket, message_id) do
    open_ids =
      [socket.assigns.active_channel, socket.assigns[:active_thread]]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)

    with %Message{} = message <- Chat.get_message(socket.assigns.current_scope, message_id),
         true <- message.channel_id in open_ids do
      {:ok, message}
    else
      _ -> :error
    end
  end

  @doc """
  Inserts the messages again into the stream that lists them, so their rows render with the
  current UI assigns (controls, menu, picker, edit form). A stream renders a row only when it is
  inserted. In a text channel the thread's rows render inside its starter's row, so a thread row
  takes the starter with it. Ids of messages in neither the open channel nor the open thread are
  skipped.
  """
  def rerender_messages(socket, message_ids) do
    %{current_scope: scope, active_channel: channel, active_thread: thread} = socket.assigns
    thread_id = thread && thread.id
    channel_id = channel && channel.id

    {thread_rows, other_rows} =
      scope
      |> Chat.get_messages(message_ids)
      |> Enum.reject(&Message.deleted?/1)
      |> Enum.split_with(&(&1.channel_id == thread_id))

    starter_rows =
      if thread_rows == [],
        do: [],
        else:
          scope
          |> Chat.get_messages([thread.starter_message_id])
          |> Enum.reject(&Message.deleted?/1)

    channel_rows = Enum.filter(other_rows ++ starter_rows, &(&1.channel_id == channel_id))

    socket
    |> stream_insert_all(:thread_messages, thread_rows)
    |> stream_insert_all(:messages, channel_rows)
  end

  defp stream_insert_all(socket, name, messages),
    do: Enum.reduce(messages, socket, &stream_insert(&2, name, &1))

  def rerender_active_thread_panel(socket) do
    case current_thread_starter_id(socket) do
      nil -> socket
      starter_message_id -> rerender_messages(socket, [starter_message_id])
    end
  end

  def maybe_push_mention_notification(socket, message) do
    current_user = socket.assigns.current_user
    active_channel = socket.assigns.active_channel
    channel = Enum.find(socket.assigns.channels, &(&1.id == message.channel_id))

    cond do
      message.author_id == current_user.id ->
        socket

      active_channel && active_channel.id == message.channel_id ->
        socket

      is_nil(channel) ->
        socket

      not Chat.message_mentions_user?(message, current_user) ->
        socket

      not Chat.mention_notifications_enabled?(current_user, channel) ->
        socket

      true ->
        push_event(socket, "notify:mention", %{
          channel_id: message.channel_id,
          channel_name: channel && channel.name,
          author_name: message.author.display_name,
          body: message.body,
          message_id: message.id
        })
    end
  end

  def refresh_thread_summaries_for_active_channel(socket) do
    case socket.assigns.active_channel do
      %{} = channel ->
        assign(
          socket,
          :thread_summaries,
          Chat.thread_summaries_for_channel(socket.assigns.current_scope, channel.id)
        )

      nil ->
        assign(socket, :thread_summaries, %{})
    end
  end

  def maybe_restore_thread(socket, nil), do: close_thread(socket)

  def maybe_restore_thread(socket, thread), do: open_thread(socket, thread)

  @doc """
  Opens `thread` under its starter: subscribes to it, streams its messages and marks it read.
  The thread's composer replaces the channel's, so a reply target in the channel is dropped.
  """
  def open_thread(socket, thread) do
    previous_starter_message_id = current_thread_starter_id(socket)

    # Subscribe before listing, so a message posted between the two is not lost.
    socket =
      socket
      |> assign(:active_thread, thread)
      |> sync_channel_subscriptions()

    thread_messages =
      case Chat.list_messages(socket.assigns.current_scope, thread.id) do
        {:ok, messages} -> messages
        _ -> []
      end

    last_message = List.last(thread_messages)
    Chat.ensure_channel_memberships(socket.assigns.current_scope, [thread])
    Chat.mark_channel_read(socket.assigns.current_user, thread, last_message)

    socket
    |> assign(
      :thread_typing_users,
      Chat.list_typing_users(socket.assigns.current_scope, thread.id)
    )
    |> keep_reply_in(thread.id)
    |> assign(:poll_form, nil)
    |> assign_thread_controls(thread)
    |> assign(
      :thread_message_count,
      Chat.thread_reply_count(socket.assigns.current_scope, thread.id)
    )
    |> assign(:thread_messages_empty?, thread_messages == [])
    |> assign_thread_message_form()
    |> stream(:thread_messages, thread_messages, reset: true)
    |> ThreadNav.mark_thread_seen(thread.id)
    |> ThreadNav.refresh_thread_following()
    |> rerender_messages([previous_starter_message_id, thread.starter_message_id])
  end

  @doc """
  Sets the open thread to `thread` and decides again what the viewer may do in it: reply, react,
  manage messages, archive or unarchive, lock or unlock. A lock or archive by anyone changes them.
  """
  def assign_thread_controls(socket, thread) do
    socket
    |> assign(:active_thread, thread)
    |> assign(:thread_abilities, Chat.channel_abilities(socket.assigns.current_scope, thread.id))
  end

  defp active_channel_abilities(_socket, nil), do: Chat.no_channel_abilities()

  defp active_channel_abilities(socket, channel),
    do: Chat.channel_abilities(socket.assigns.current_scope, channel.id)

  @doc "Reloads the open thread when `channel_id` is it, so its header and controls follow."
  def refresh_active_thread(socket, channel_id) do
    with %{id: ^channel_id} <- socket.assigns.active_thread,
         %{} = thread <- Chat.get_thread(socket.assigns.current_scope, channel_id) do
      socket
      |> assign_thread_controls(thread)
      |> refresh_thread_summaries_for_active_channel()
      |> rerender_active_thread_panel()
    else
      _ -> socket
    end
  end

  def close_thread(socket) do
    previous_starter_message_id = current_thread_starter_id(socket)

    case socket.assigns.active_thread do
      %{} = thread ->
        Chat.clear_typing(socket.assigns.current_scope, thread.id)

      nil ->
        :ok
    end

    socket
    |> assign(:active_thread, nil)
    |> assign(:thread_typing_users, [])
    |> keep_reply_in(socket.assigns.active_channel && socket.assigns.active_channel.id)
    |> assign(:poll_form, nil)
    |> assign(:thread_abilities, Chat.no_channel_abilities())
    |> assign(:thread_following?, false)
    |> assign(:thread_message_count, 0)
    |> assign(:thread_messages_empty?, true)
    |> assign_thread_message_form()
    |> stream(:thread_messages, [], reset: true)
    |> rerender_messages([previous_starter_message_id])
    |> sync_channel_subscriptions()
    |> ForumNav.reload()
  end

  @doc """
  Closes the open thread and returns the URL to its channel, since a thread URL reopens its thread
  on load.
  """
  def leave_thread(socket) do
    case socket.assigns.active_channel do
      %{} = channel -> socket |> close_thread() |> push_patch(to: channel_path(channel))
      nil -> close_thread(socket)
    end
  end

  def current_thread_starter_id(socket) do
    case socket.assigns.active_thread do
      %{} = thread -> thread.starter_message_id
      _ -> nil
    end
  end

  def maybe_put_reply(socket, message_params) do
    case socket.assigns.reply_to_message do
      nil -> message_params
      reply_to_message -> Map.put(message_params, "reply_to_id", reply_to_message.id)
    end
  end

  def clear_reply_to_message(socket), do: assign(socket, :reply_to_message, nil)

  # One composer shows at a time and `:reply_to_message` is its target, so a target outside the
  # conversation that composer writes to is dropped.
  defp keep_reply_in(socket, conversation_id) do
    case socket.assigns.reply_to_message do
      %{channel_id: ^conversation_id} -> socket
      _other -> assign(socket, :reply_to_message, nil)
    end
  end

  @doc """
  Makes `channel` the active channel and loads it in the same step, so the next render shows its
  messages and the previous content stays until then. State scoped to the previous channel (open
  thread, reply target, poll draft, edit) is dropped first.
  """
  def switch_channel(socket, channel) do
    socket
    |> assign(:active_channel, channel)
    |> assign(:reply_to_message, nil)
    |> assign(:poll_form, nil)
    |> assign(:editing_message_id, nil)
    |> assign(:editing_form, nil)
    |> close_thread()
    |> load_channel(channel)
  end

  def refresh_typing_users(socket) do
    case socket.assigns.active_channel do
      %{} = channel ->
        assign(
          socket,
          :typing_users,
          Chat.list_typing_users(socket.assigns.current_scope, channel.id)
        )

      nil ->
        assign(socket, :typing_users, [])
    end
  end

  def refresh_thread_typing_users(socket) do
    case socket.assigns.active_thread do
      %{} = thread ->
        assign(
          socket,
          :thread_typing_users,
          Chat.list_typing_users(socket.assigns.current_scope, thread.id)
        )

      nil ->
        assign(socket, :thread_typing_users, [])
    end
  end

  defp sync_active_channel(socket, channels) do
    case socket.assigns.active_channel do
      nil ->
        socket

      active_channel ->
        assign(
          socket,
          :active_channel,
          Enum.find(channels, &(&1.id == active_channel.id)) || active_channel
        )
    end
  end

  # The open thread read again, when it is still one the member may view under `channel`.
  defp reloaded_active_thread(socket, channel) do
    channel_id = channel.id

    with %{id: thread_id} <- socket.assigns.active_thread,
         %{parent_channel_id: ^channel_id} = thread <-
           Chat.get_thread(socket.assigns.current_scope, thread_id) do
      thread
    else
      _ -> nil
    end
  end

  defp channel_path(channel), do: ~p"/?channel=#{channel.slug}"

  defp visible_text_channel?(channel) do
    channel.kind not in [:category, :thread_public, :thread_private, :thread_announcement]
  end
end
