defmodule TavernWeb.ServerLive.State do
  @moduledoc false

  use TavernWeb, :html

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [
      connected?: 1,
      push_event: 3,
      push_patch: 2,
      stream: 3,
      stream: 4,
      stream_delete: 3,
      stream_insert: 3,
      stream_insert: 4
    ]

  alias Tavern.Accounts
  alias Tavern.Chat
  alias Tavern.Chat.Channel
  alias TavernWeb.ServerComponents.Helpers
  alias Tavern.Chat.Message
  alias Tavern.Chat.Topics
  alias TavernWeb.ServerLive.ChannelEditor
  alias TavernWeb.ServerLive.ForumNav
  alias TavernWeb.ServerLive.MessageJump
  alias TavernWeb.ServerLive.Pane
  alias TavernWeb.ServerLive.ThreadNav

  # Messages per transcript page: the first load, each "load older" or "load newer" step, and the
  # window around a message a link opens.
  @page_size 50

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
    |> assign_direct_messages()
    |> assign_blocks()
    |> assign(:navigation_ready?, true)
    |> sync_active_channel(channels)
    |> sync_channel_subscriptions()
    |> ThreadNav.refresh_followed_threads()
    |> ChannelEditor.refresh()
  end

  @doc """
  Reads the member's direct messages again: the listed ones for the sidebar, and the ids of all
  of them, so a DM another member opened delivers its first message before it is listed. Then
  subscribes to them (`sync_channel_subscriptions/1`).
  """
  def refresh_direct_messages(socket) do
    socket
    |> assign_direct_messages()
    |> sync_channel_subscriptions()
  end

  @doc """
  Reads the member's blocks again after one changed: the rows of a blocked author collapse, and
  the DM with a blocked account takes no messages. The open panes load again, because a stream
  re-renders only the rows it is given.
  """
  def refresh_blocks(socket) do
    socket =
      socket
      |> assign_blocks()
      |> refresh_direct_messages()
      |> refresh_channels()

    Enum.reduce(Pane.kinds(), socket, &reload_pane(&2, &1, pane(&2, &1).jump))
  end

  defp assign_blocks(socket),
    do:
      assign(
        socket,
        :blocked_user_ids,
        MapSet.new(Chat.blocked_user_ids(socket.assigns.current_scope))
      )

  defp assign_direct_messages(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:direct_messages, Chat.list_direct_messages(scope))
    |> assign(:direct_message_ids, MapSet.new(Chat.direct_message_ids(scope)))
  end

  @doc """
  Subscribes the socket to the topics of its listed channels, its direct messages, the active
  channel and the active thread, and unsubscribes it from all other channel topics.

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
        |> MapSet.union(socket.assigns.direct_message_ids)

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

  # Streams the conversation's messages into the pane of `kind` and reads the pane's rights,
  # typing users and count. The page is the newest one, or the window around the message the URL
  # names (`MessageJump.target/3`); a page that holds the newest message marks the conversation
  # read, and a window does not, because the read marker may be ahead of it. The caller has
  # already subscribed to the conversation, so a message posted while the list loads still
  # arrives, and renders the pane's host itself.
  defp load_pane(socket, kind, conversation),
    do: load_pane(socket, kind, conversation, MessageJump.target(socket, kind, conversation))

  defp load_pane(socket, kind, conversation, jump) do
    scope = socket.assigns.current_scope

    {socket, {messages, older_cursor, newer_cursor}} =
      case jump && message_window(scope, conversation.id, jump) do
        nil ->
          {socket, newest_page(scope, conversation.id)}

        :error ->
          {MessageJump.refuse(socket, jump), newest_page(scope, conversation.id)}

        window ->
          {socket, window}
      end

    if is_nil(newer_cursor),
      do: Chat.mark_channel_read(scope, conversation.id, List.last(messages))

    pane = %{
      Pane.new(kind)
      | abilities: Chat.channel_abilities(scope, conversation.id),
        typing_users: Chat.list_typing_users(scope, conversation.id),
        message_count: Pane.count_messages(scope, kind, conversation.id),
        empty?: messages == [],
        older_cursor: older_cursor,
        newer_cursor: newer_cursor,
        jump: jump
    }

    socket
    |> assign(Pane.assign_key(kind), pane)
    |> stream(Pane.stream_name(kind), messages, reset: true)
  end

  @doc """
  Loads the pane of `kind` again: the window around `jump`'s message
  (`MessageJump.target/3`), or the newest page for nil. The open thread renders inside its
  starter's row of the channel stream, so a new channel page inserts that row again, as opening
  the thread does.
  """
  def reload_pane(socket, kind, jump) do
    case conversation(socket, kind) do
      nil -> socket
      conversation -> socket |> load_pane(kind, conversation, jump) |> rerender_thread_host(kind)
    end
  end

  defp rerender_thread_host(socket, :channel), do: rerender_active_thread_panel(socket)
  defp rerender_thread_host(socket, :thread), do: rerender_pane_host(socket, :thread)

  defp newest_page(scope, conversation_id) do
    {messages, older_cursor} = message_page(scope, conversation_id, nil)
    {messages, older_cursor, nil}
  end

  # The window around the jump's message: up to half a page on each side of it. A message the
  # conversation does not list (deleted, hidden, or in another conversation) is `:error`.
  defp message_window(scope, conversation_id, {_reason, message_id}) do
    half = div(@page_size, 2)

    with {:ok, message_id} <- Chat.Ids.cast(message_id),
         {:ok, messages} <-
           Chat.list_messages(scope, conversation_id, around: message_id, limit: half + 1),
         {older, [%Message{id: ^message_id} = target | newer]} <-
           Enum.split_while(messages, &(&1.id != message_id)) do
      {older, older_cursor} = trim_older(older, half)
      {newer, newer_cursor} = trim_newer(newer, half)
      {older ++ [target | newer], older_cursor, newer_cursor}
    else
      _ -> :error
    end
  end

  # One row more than a side holds is read to learn whether more exist past it; the cursor names
  # the last row kept on that side, or is nil when the side reaches the end of the conversation.
  defp trim_older(older, half) when length(older) > half do
    [_dropped | kept] = older
    {kept, hd(kept).id}
  end

  defp trim_older(older, _half), do: {older, nil}

  defp trim_newer(newer, half) when length(newer) > half do
    kept = Enum.take(newer, half)
    {kept, List.last(kept).id}
  end

  defp trim_newer(newer, _half), do: {newer, nil}

  @doc """
  Adds the page of messages after the newest one the pane of `kind` shows to the end of its
  stream. The page that reaches the conversation's newest message marks it read. A pane that
  already holds the newest message is left alone.
  """
  def load_newer_messages(socket, kind) do
    scope = socket.assigns.current_scope

    with %{id: conversation_id} <- conversation(socket, kind),
         %Pane{newer_cursor: cursor} when not is_nil(cursor) <- pane(socket, kind),
         {:ok, messages} <-
           Chat.list_messages(scope, conversation_id, after: cursor, limit: @page_size + 1) do
      {messages, newer_cursor} = trim_newer(messages, @page_size)

      if is_nil(newer_cursor),
        do: Chat.mark_channel_read(scope, conversation_id, List.last(messages))

      socket
      |> stream(Pane.stream_name(kind), messages)
      |> update_pane(kind, &%{&1 | newer_cursor: newer_cursor})
    else
      _ -> socket
    end
  end

  @doc """
  Adds the page of messages before the oldest one the pane of `kind` shows to the top of its
  stream. A pane already at the start of its conversation is left alone.
  """
  def load_older_messages(socket, kind) do
    with %{id: conversation_id} <- conversation(socket, kind),
         %Pane{older_cursor: cursor} when not is_nil(cursor) <- pane(socket, kind) do
      {messages, older_cursor} =
        message_page(socket.assigns.current_scope, conversation_id, cursor)

      # Inserting at index 0 one by one reverses the list, so the oldest goes in last.
      socket
      |> stream(Pane.stream_name(kind), Enum.reverse(messages), at: 0)
      |> update_pane(kind, &%{&1 | older_cursor: older_cursor})
    else
      _ -> socket
    end
  end

  # One page of a conversation, oldest first: the newest page when `before` is nil, else the page
  # that ends just before message `before`. One extra row is read to learn whether an older page
  # exists; the second element is the cursor for it, or nil at the start of the conversation.
  defp message_page(scope, conversation_id, before) do
    opts = [limit: @page_size + 1] ++ if(before, do: [before: before], else: [])

    case Chat.list_messages(scope, conversation_id, opts) do
      {:ok, [_older | page] = messages} when length(messages) > @page_size ->
        {page, hd(page).id}

      {:ok, messages} ->
        {messages, nil}

      {:error, _reason} ->
        {[], nil}
    end
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
    |> assign(:unread_counts, Chat.unread_counts(scope, conversation_ids(socket)))
    |> assign(:unread_mentions, Chat.unread_mentions(scope, conversation_ids(socket)))
    |> ForumNav.load(channel)
    |> maybe_restore_thread(active_thread)
  end

  def redirect_to_default_channel(socket) do
    case List.first(socket.assigns.channels) do
      nil -> socket
      channel -> push_patch(socket, to: Helpers.channel_path(channel))
    end
  end

  def refresh_channels(socket) do
    visible_channels = Chat.list_channels(socket.assigns.current_scope)
    channels = Enum.filter(visible_channels, &visible_text_channel?/1)

    # A direct message is not in the channel list; it stays open while the member is a
    # participant, which no channel change alters.
    active_channel =
      case socket.assigns.active_channel do
        nil -> nil
        %Channel{kind: :direct} = active -> active
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
  conversations, so each that holds its newest message is marked read up to it.
  """
  def set_tab_visible(socket, visible?) do
    if visible? and not socket.assigns.tab_visible? do
      for kind <- Pane.kinds(),
          %{id: id} <- [conversation(socket, kind)],
          is_nil(pane(socket, kind).newer_cursor) do
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
        insert_at_tail(socket, kind, message)
    end
  end

  # A pane that holds a window around an older message has a gap before the new message, so it
  # counts the message and shows it once the reader reaches the newest page.
  defp insert_at_tail(socket, kind, %Message{channel_id: channel_id} = message) do
    case pane(socket, kind) do
      %Pane{newer_cursor: cursor} when not is_nil(cursor) ->
        update_pane(socket, kind, &%{&1 | message_count: &1.message_count + 1})

      %Pane{} ->
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
        |> stream_message(Pane.stream_name(kind), message, update_only: true)
        |> update_pane(kind, &%{&1 | message_count: count})
    end
  end

  # A message the transcript does not show (a closed permission request, or a deleted message
  # that starts no live thread here) leaves the stream instead of rendering again. The open
  # channel's thread summaries say which messages start a live thread.
  #
  # `update_only: true` leaves out a row the browser does not hold: a change to a message outside
  # the loaded pages must not add it at the end of the transcript.
  defp stream_message(socket, name, %Message{} = message, opts \\ []) do
    if Message.transcript_shown?(message, starts_live_thread?(socket, message)),
      do: stream_insert(socket, name, message, opts),
      else: stream_delete(socket, name, message)
  end

  defp starts_live_thread?(socket, %Message{id: id}),
    do: Map.has_key?(socket.assigns.thread_summaries, id)

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
      Chat.unread_counts(socket.assigns.current_scope, conversation_ids(socket))
    )
  end

  def refresh_unread_mentions(socket) do
    assign(
      socket,
      :unread_mentions,
      Chat.unread_mentions(socket.assigns.current_scope, conversation_ids(socket))
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
  takes the starter with it. A message the transcript no longer shows leaves its stream. Ids of
  messages in neither the open channel nor the open thread are skipped.
  """
  def rerender_messages(socket, message_ids) do
    %{current_scope: scope, active_channel: channel, active_thread: thread} = socket.assigns
    thread_id = thread && thread.id
    channel_id = channel && channel.id

    {thread_rows, other_rows} =
      scope
      |> Chat.get_messages(message_ids)
      |> Enum.split_with(&(&1.channel_id == thread_id))

    starter_rows =
      if thread_rows == [],
        do: [],
        else: Chat.get_messages(scope, [thread.starter_message_id])

    channel_rows = Enum.filter(other_rows ++ starter_rows, &(&1.channel_id == channel_id))

    socket
    |> stream_messages(:thread_messages, thread_rows)
    |> stream_messages(:messages, channel_rows)
  end

  # A re-render changes rows the browser holds; a row outside the loaded pages stays out.
  defp stream_messages(socket, name, messages),
    do: Enum.reduce(messages, socket, &stream_message(&2, name, &1, update_only: true))

  @doc """
  Inserts the open thread's starter row into the channel stream, where the thread renders. A
  starter outside the loaded pages joins the stream, so the thread shows wherever the reader
  opened it from.
  """
  def rerender_active_thread_panel(socket) do
    with %{active_channel: %{id: channel_id}} <- socket.assigns,
         starter_id when not is_nil(starter_id) <- current_thread_starter_id(socket),
         [%Message{channel_id: ^channel_id} = starter] <-
           Chat.get_messages(socket.assigns.current_scope, [starter_id]) do
      stream_message(socket, :messages, starter)
    else
      _ -> socket
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
    |> rerender_messages([previous_starter_message_id])
    |> rerender_active_thread_panel()
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
      %{} = channel -> socket |> close_thread() |> push_patch(to: Helpers.channel_path(channel))
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

  defp visible_text_channel?(channel) do
    channel.kind not in [:category, :thread_public, :thread_private, :thread_announcement]
  end

  defp ids(channels), do: Enum.map(channels, & &1.id)

  # The conversations the sidebar shows a badge for: the listed channels and direct messages.
  defp conversation_ids(socket),
    do: ids(socket.assigns.channels) ++ ids(socket.assigns.direct_messages)
end
