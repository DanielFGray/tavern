defmodule TavernWeb.ServerLive.State do
  @moduledoc false

  use TavernWeb, :html

  import Phoenix.Component, only: [assign: 3]

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
  alias TavernWeb.ServerLive.Pane
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

  def pane(socket, kind), do: Map.fetch!(socket.assigns, Pane.assign_key(kind))

  def conversation(socket, kind), do: Map.fetch!(socket.assigns, Pane.conversation_key(kind))

  @doc "The kind of the pane showing conversation `channel_id`, or nil when no pane shows it."
  def pane_showing(socket, channel_id) do
    Enum.find(Pane.kinds(), &match?(%{id: ^channel_id}, conversation(socket, &1)))
  end

  @doc """
  Changes the pane of `kind` with `fun`. In a text channel the thread pane renders inside its
  starter's row of the channel stream, and a stream row renders only when it is inserted, so a
  thread pane change inserts that row again, with the thread summaries its reply pill reads.
  """
  def update_pane(socket, kind, fun) do
    socket
    |> assign(Pane.assign_key(kind), fun.(pane(socket, kind)))
    |> rerender_pane_host(kind)
  end

  def reset_form(socket, kind), do: update_pane(socket, kind, &%{&1 | form: Pane.blank_form()})

  def refresh_typing_users(socket, kind) do
    users =
      case conversation(socket, kind) do
        %{id: id} -> Chat.list_typing_users(socket.assigns.current_scope, id)
        nil -> []
      end

    update_pane(socket, kind, &%{&1 | typing_users: users})
  end

  defp rerender_pane_host(socket, :channel), do: socket

  defp rerender_pane_host(socket, :thread) do
    socket
    |> refresh_thread_summaries_for_active_channel()
    |> rerender_active_thread_panel()
  end

  # Streams the conversation's messages into the pane of `kind`, marks them read and reads the
  # pane's rights, typing users and count. The caller has already subscribed to the conversation,
  # so a message posted while the list loads still arrives, and renders the pane's host itself.
  defp load_pane(socket, kind, conversation) do
    scope = socket.assigns.current_scope

    messages =
      case Chat.list_messages(scope, conversation.id) do
        {:ok, messages} -> messages
        {:error, :not_found} -> []
      end

    Chat.mark_channel_read(scope, conversation.id, List.last(messages))

    pane = %{
      Pane.new(kind)
      | abilities: Chat.channel_abilities(scope, conversation.id),
        typing_users: Chat.list_typing_users(scope, conversation.id),
        message_count: Pane.count_messages(scope, kind, conversation.id),
        empty?: messages == []
    }

    socket
    |> assign(Pane.assign_key(kind), pane)
    |> stream(Pane.stream_name(kind), messages, reset: true)
  end

  defp reset_pane(socket, kind) do
    socket
    |> assign(Pane.assign_key(kind), Pane.new(kind))
    |> stream(Pane.stream_name(kind), [], reset: true)
  end

  def load_channel(socket, channel) do
    scope = socket.assigns.current_scope
    visible_channels = Chat.list_channels(scope)
    channels = Enum.filter(visible_channels, &visible_text_channel?/1)
    channel = Enum.find(channels, &(&1.id == channel.id)) || channel
    active_thread = reloaded_active_thread(socket, channel)

    socket =
      socket
      |> assign(:channels, channels)
      |> assign(:channel_sections, Chat.build_channel_tree(visible_channels))
      |> assign(:navigation_ready?, true)
      |> assign(:mobile_sidebar_open?, false)
      |> assign(:mobile_members_open?, false)
      |> close_message_ui()
      |> assign(:active_channel, channel)
      |> sync_channel_subscriptions()
      |> load_pane(:channel, channel)

    # The unread counts are read after the load marks the channel read.
    socket
    |> assign(:thread_summaries, Chat.thread_summaries_for_channel(scope, channel.id))
    |> assign(:unread_counts, Chat.unread_counts(scope, ids(channels)))
    |> assign(:unread_mentions, Chat.unread_mentions(scope, ids(channels)))
    |> ForumNav.load(channel)
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
    |> update_pane(:channel, &%{&1 | abilities: active_channel_abilities(socket, active_channel)})
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

  @doc """
  Records whether the view's tab is visible. A tab that becomes visible again shows its open
  conversations, so each is marked read up to its latest message.
  """
  def set_tab_visible(socket, visible?) do
    if visible? and not socket.assigns.tab_visible? do
      for kind <- Pane.kinds(), %{id: id} <- [conversation(socket, kind)] do
        Chat.mark_channel_read(socket.assigns.current_scope, id)
      end
    end

    assign(socket, :tab_visible?, visible?)
  end

  @doc """
  Adds a new message to the pane showing its conversation, and animates it in. While the tab is
  visible the member is reading that conversation, so it is marked read up to the message, and
  its sidebar badge does not return on reload. In a hidden tab it stays unread, so the member's
  other devices keep the badge, until `set_tab_visible/2` marks it read.
  """
  def insert_message(socket, %Message{channel_id: channel_id} = message) do
    case pane_showing(socket, channel_id) do
      nil ->
        socket

      kind ->
        if socket.assigns.tab_visible?,
          do: Chat.mark_channel_read(socket.assigns.current_scope, channel_id, message)

        stream_name = Pane.stream_name(kind)

        socket
        |> stream_insert(stream_name, message)
        |> push_entered(["#{stream_name}-#{message.id}"])
        |> update_pane(kind, &%{&1 | empty?: false, message_count: &1.message_count + 1})
    end
  end

  @doc """
  Shows a changed message in the pane that lists it. A change can change the count (a delete), so
  the count is read again.
  """
  def stream_update_message(socket, %Message{channel_id: channel_id} = message) do
    case pane_showing(socket, channel_id) do
      nil ->
        socket

      kind ->
        count = Pane.count_messages(socket.assigns.current_scope, kind, channel_id)

        socket
        |> stream_message(Pane.stream_name(kind), message)
        |> update_pane(kind, &%{&1 | message_count: count})
    end
  end

  # A message no list shows (deleted, or a closed permission request) leaves the stream instead
  # of rendering again.
  defp stream_message(socket, name, %Message{} = message) do
    if Message.listed?(message),
      do: stream_insert(socket, name, message),
      else: stream_delete(socket, name, message)
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
      Chat.unread_counts(socket.assigns.current_scope, ids(socket.assigns.channels))
    )
  end

  def refresh_unread_mentions(socket) do
    assign(
      socket,
      :unread_mentions,
      Chat.unread_mentions(socket.assigns.current_scope, ids(socket.assigns.channels))
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
    with %Message{} = message <- Chat.get_message(socket.assigns.current_scope, message_id),
         kind when not is_nil(kind) <- pane_showing(socket, message.channel_id) do
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

      not Chat.mention_notifications_enabled?(socket.assigns.current_scope, channel) ->
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

    Chat.ensure_channel_memberships(socket.assigns.current_scope, [thread])

    socket
    |> keep_reply_in(thread.id)
    |> assign(:poll_form, nil)
    |> load_pane(:thread, thread)
    |> ThreadNav.mark_thread_seen(thread.id)
    |> ThreadNav.refresh_thread_following()
    |> rerender_messages([previous_starter_message_id, thread.starter_message_id])
  end

  defp active_channel_abilities(_socket, nil), do: Chat.no_channel_abilities()

  defp active_channel_abilities(socket, channel),
    do: Chat.channel_abilities(socket.assigns.current_scope, channel.id)

  @doc """
  Reloads the open thread when `channel_id` is it, so its header follows, and decides again what
  the viewer may do in it: a lock or archive by anyone changes that.
  """
  def refresh_active_thread(socket, channel_id) do
    with %{id: ^channel_id} <- socket.assigns.active_thread,
         %{} = thread <- Chat.get_thread(socket.assigns.current_scope, channel_id) do
      abilities = Chat.channel_abilities(socket.assigns.current_scope, thread.id)

      socket
      |> assign(:active_thread, thread)
      |> update_pane(:thread, &%{&1 | abilities: abilities})
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
    |> keep_reply_in(socket.assigns.active_channel && socket.assigns.active_channel.id)
    |> assign(:poll_form, nil)
    |> assign(:thread_following?, false)
    |> reset_pane(:thread)
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

  defp ids(channels), do: Enum.map(channels, & &1.id)
end
