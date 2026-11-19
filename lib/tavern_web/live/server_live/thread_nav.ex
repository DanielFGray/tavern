defmodule TavernWeb.ServerLive.ThreadNav do
  @moduledoc """
  The followed threads in the sidebar and the thread browser panel.

  `:followed_threads` holds the entries of `Chat.followed_threads/1`, each with an
  `:unread_count`. It is reloaded from the database when the follow set or the visible channels
  change, and updated in memory when a `{:thread_message_created, message}` arrives on a parent
  channel's topic (docs/design/threads.md, "Live updates").

  `:thread_browser` is nil when the panel is closed, or `%{channel, tab, query, form, entries,
  next}`, where `form` is the title search form.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Tavern.Chat
  alias TavernWeb.ServerLive.State

  @doc "Reloads the followed threads, their unread counts and the open thread's follow state."
  def refresh_followed_threads(socket) do
    %{current_scope: scope, current_user: user} = socket.assigns
    entries = Chat.followed_threads(scope)
    unread = Chat.unread_counts_for_user(user, Enum.map(entries, & &1.thread))

    entries =
      Enum.map(entries, fn entry ->
        Map.put(entry, :unread_count, shown_unread(socket, entry.thread.id, unread))
      end)

    socket
    |> assign(:followed_threads, entries)
    |> refresh_thread_following()
  end

  @doc "Sets `:thread_following?` for the open thread."
  def refresh_thread_following(socket) do
    following? =
      case socket.assigns.active_thread do
        %{id: id} -> Chat.following_thread?(socket.assigns.current_scope, id)
        nil -> false
      end

    assign(socket, :thread_following?, following?)
  end

  @doc "Clears the unread count of `thread_id` in the sidebar, for a thread the member opened."
  def mark_thread_seen(socket, thread_id) do
    update_entry(socket, thread_id, &Map.put(&1, :unread_count, 0))
  end

  @doc """
  Applies a message posted in a thread under a listed channel: moves a followed thread to the top
  and counts the message unread, and pushes a desktop notification when the rules allow one.
  """
  def apply_thread_message(socket, message) do
    socket
    |> bump_entry(message)
    |> maybe_notify(message)
  end

  @doc """
  Reloads the follow state when the change names the signed-in member, and redraws the open
  thread's pane, whose Follow button lives in a stream item.
  """
  def apply_follow_change(socket, user_ids) do
    if socket.assigns.current_user.id in user_ids,
      do: socket |> refresh_followed_threads() |> State.rerender_active_thread_panel(),
      else: socket
  end

  @doc """
  Reloads the sidebar threads and the open browser's first page, after a change to the channels
  or threads the member may view. The browser closes when its channel is no longer visible.
  """
  def reload(socket) do
    socket
    |> refresh_followed_threads()
    |> filter_browser(%{})
  end

  @doc "Opens the browser on the threads of `channel_id`, a channel the sidebar lists."
  def open_browser(socket, channel_id) do
    case Enum.find(socket.assigns.channels, &(&1.id == channel_id)) do
      nil -> socket
      channel -> load_browser(socket, channel, :active, "")
    end
  end

  def close_browser(socket), do: assign(socket, :thread_browser, nil)

  @doc "Reloads the open browser's first page with a new tab or title search."
  def filter_browser(socket, changes) do
    case socket.assigns.thread_browser do
      nil ->
        socket

      browser ->
        browser = Map.merge(browser, changes)
        load_browser(socket, browser.channel, browser.tab, browser.query)
    end
  end

  @doc "Appends the next page to the open browser."
  def load_more(socket) do
    with %{next: next} = browser when not is_nil(next) <- socket.assigns.thread_browser,
         {:ok, page} <- browse(socket, browser, after: next) do
      assign(socket, :thread_browser, %{
        browser
        | entries: browser.entries ++ page.entries,
          next: page.next
      })
    else
      _ -> socket
    end
  end

  @doc "Sets the follow state of `thread_id` in the open browser's rows."
  def set_browser_following(socket, thread_id, following?) do
    case socket.assigns.thread_browser do
      nil ->
        socket

      browser ->
        entries =
          Enum.map(browser.entries, fn
            %{thread: %{id: ^thread_id}} = entry -> %{entry | following?: following?}
            entry -> entry
          end)

        assign(socket, :thread_browser, %{browser | entries: entries})
    end
  end

  defp load_browser(socket, channel, tab, query) do
    browser = %{
      channel: channel,
      tab: tab,
      query: query,
      form: to_form(%{"query" => query}, as: :thread_search),
      entries: [],
      next: nil
    }

    case browse(socket, browser, []) do
      {:ok, page} ->
        assign(socket, :thread_browser, %{browser | entries: page.entries, next: page.next})

      {:error, :not_found} ->
        close_browser(socket)
    end
  end

  defp browse(socket, browser, opts) do
    Chat.browse_threads(
      socket.assigns.current_scope,
      browser.channel.id,
      [tab: browser.tab, query: browser.query] ++ opts
    )
  end

  defp bump_entry(socket, message) do
    case Enum.split_with(socket.assigns.followed_threads, &(&1.thread.id == message.channel_id)) do
      {[entry], rest} ->
        unread =
          if counts_unread?(socket, message), do: entry.unread_count + 1, else: entry.unread_count

        entry = %{entry | last_activity_at: message.inserted_at, unread_count: unread}
        assign(socket, :followed_threads, [entry | rest])

      _not_followed ->
        socket
    end
  end

  # A followed thread notifies like a channel: any mention the member's settings allow. Any other
  # thread notifies on a direct mention only, and only after a read confirms the member may view
  # it, because this event reached the session through the parent channel's topic.
  defp maybe_notify(socket, message) do
    %{current_user: user, current_scope: scope} = socket.assigns
    thread = message.channel

    notify? =
      counts_unread?(socket, message) and
        if followed?(socket, thread.id) do
          Chat.message_mentions_user?(message, user) and
            Chat.mention_notifications_enabled?(user, thread)
        else
          Chat.message_mentions_user_directly?(message, user) and
            not is_nil(Chat.get_thread(scope, thread.id)) and
            Chat.mention_notifications_enabled?(user, thread)
        end

    if notify? do
      push_event(socket, "notify:mention", %{
        channel_id: thread.id,
        channel_name: thread.name,
        author_name: message.author.display_name,
        body: message.body,
        message_id: message.id
      })
    else
      socket
    end
  end

  defp counts_unread?(socket, message) do
    message.author_id != socket.assigns.current_user.id and
      not thread_open?(socket, message.channel_id)
  end

  defp followed?(socket, thread_id),
    do: Enum.any?(socket.assigns.followed_threads, &(&1.thread.id == thread_id))

  defp thread_open?(socket, thread_id),
    do: match?(%{id: ^thread_id}, socket.assigns.active_thread)

  defp shown_unread(socket, thread_id, unread) do
    if thread_open?(socket, thread_id), do: 0, else: Map.get(unread, thread_id, 0)
  end

  defp update_entry(socket, thread_id, fun) do
    entries =
      Enum.map(socket.assigns.followed_threads, fn
        %{thread: %{id: ^thread_id}} = entry -> fun.(entry)
        entry -> entry
      end)

    assign(socket, :followed_threads, entries)
  end
end
