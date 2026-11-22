defmodule TavernWeb.ServerLive.Events.Threads do
  @moduledoc false

  use TavernWeb, :verified_routes

  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]

  alias Tavern.Chat
  alias TavernWeb.ServerLive.Events.Navigation
  alias TavernWeb.ServerLive.ForumNav
  alias TavernWeb.ServerLive.State
  alias TavernWeb.ServerLive.ThreadNav

  @events ~w(
    create_thread
    open_thread
    close_thread
    archive_thread
    unarchive_thread
    rename_thread
    lock_thread
    unlock_thread
    delete_thread
    follow_thread
    unfollow_thread
    open_thread_browser
    close_thread_browser
    thread_browser_tab
    thread_browser_search
    thread_browser_more
    open_browsed_thread
  )

  def events, do: @events

  def handle_info({:thread_message_created, message}, socket) do
    {:noreply,
     socket
     |> ThreadNav.apply_thread_message(message)
     |> refresh_closed_thread_chip(message)
     |> ForumNav.reload_for_post(message.channel)}
  end

  def handle_info({:thread_message_unlisted, message}, socket),
    do: {:noreply, refresh_closed_thread_chip(socket, message)}

  def handle_info({:thread_followers_changed, _thread_id, user_ids}, socket),
    do: {:noreply, ThreadNav.apply_follow_change(socket, user_ids)}

  def handle_event("create_thread", %{"id" => message_id}, socket) do
    with {:ok, thread} <-
           Chat.create_public_thread(socket.assigns.current_scope, message_id) do
      {:noreply,
       socket
       |> State.close_message_ui()
       |> State.refresh_thread_summaries_for_active_channel()
       |> State.open_thread(thread)
       |> State.push_entered([
         State.thread_panel_dom_id(thread),
         "thread-summary-#{thread.starter_message_id}"
       ])
       |> ThreadNav.refresh_followed_threads()}
    else
      :error ->
        {:noreply, socket}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to create threads here.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create that thread.")}
    end
  end

  def handle_event("open_thread", %{"id" => thread_id}, socket) do
    case Chat.get_thread(socket.assigns.current_scope, thread_id) do
      %{} = thread ->
        {:noreply,
         socket
         |> State.open_thread(thread)
         |> State.push_entered([State.thread_panel_dom_id(thread)])}

      nil ->
        {:noreply, put_flash(socket, :error, "That thread no longer exists.")}
    end
  end

  def handle_event("close_thread", _params, socket), do: {:noreply, State.leave_thread(socket)}

  def handle_event(event, _params, socket)
      when event in ["archive_thread", "unarchive_thread", "lock_thread", "unlock_thread"] do
    with %{} = thread <- socket.assigns.active_thread,
         {:ok, thread} <- change_thread(event, socket.assigns.current_scope, thread.id) do
      {:noreply, State.refresh_active_thread(socket, thread.id)}
    else
      nil ->
        {:noreply, socket}

      {:error, _refusal} ->
        {:noreply, put_flash(socket, :error, "You cannot change that thread.")}
    end
  end

  def handle_event("rename_thread", %{"thread_rename" => %{"name" => name}}, socket)
      when is_binary(name) do
    with %{} = thread <- socket.assigns.active_thread,
         {:ok, thread} <- Chat.rename_thread(socket.assigns.current_scope, thread.id, name) do
      # The renamer's own view hears no broadcast, so it runs the handler of
      # `{:channel_updated, _}` itself, as every other session does on receiving it.
      Navigation.handle_info({:channel_updated, thread}, socket)
    else
      nil ->
        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "A thread title takes 1 to 40 characters.")}

      {:error, _refusal} ->
        {:noreply, put_flash(socket, :error, "You cannot rename that thread.")}
    end
  end

  # The deleter's own view hears no broadcast, so it runs the handler of `{:channel_deleted, _}`
  # itself, as every other session does on receiving it.
  def handle_event("delete_thread", _params, socket) do
    with %{} = thread <- socket.assigns.active_thread,
         {:ok, deleted} <- Chat.delete_thread(socket.assigns.current_scope, thread.id) do
      Navigation.handle_info({:channel_deleted, deleted}, socket)
    else
      nil ->
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That thread no longer exists.")}

      {:error, _refusal} ->
        {:noreply, put_flash(socket, :error, "You cannot delete that thread.")}
    end
  end

  def handle_event(event, %{"id" => thread_id}, socket)
      when event in ["follow_thread", "unfollow_thread"] do
    following? = event == "follow_thread"

    result =
      if following?,
        do: Chat.follow_thread(socket.assigns.current_scope, thread_id),
        else: Chat.unfollow_thread(socket.assigns.current_scope, thread_id)

    case result do
      :ok ->
        {:noreply,
         socket
         |> ThreadNav.refresh_followed_threads()
         |> ThreadNav.set_browser_following(thread_id, following?)
         |> State.rerender_active_thread_panel()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That thread no longer exists.")}
    end
  end

  def handle_event("open_thread_browser", %{"channel-id" => channel_id}, socket),
    do: {:noreply, ThreadNav.open_browser(socket, channel_id)}

  def handle_event("close_thread_browser", _params, socket),
    do: {:noreply, ThreadNav.close_browser(socket)}

  def handle_event("thread_browser_tab", %{"tab" => tab}, socket)
      when tab in ["active", "archived"],
      do: {:noreply, ThreadNav.filter_browser(socket, %{tab: String.to_existing_atom(tab)})}

  def handle_event("thread_browser_search", %{"thread_search" => %{"query" => query}}, socket)
      when is_binary(query),
      do: {:noreply, ThreadNav.filter_browser(socket, %{query: query})}

  def handle_event("thread_browser_more", _params, socket),
    do: {:noreply, ThreadNav.load_more(socket)}

  # A row names a thread the browser loaded, so the click acts only on a thread found there.
  def handle_event("open_browsed_thread", %{"id" => thread_id}, socket) do
    with %{entries: entries, channel: channel} <- socket.assigns.thread_browser,
         %{thread: thread} <- Enum.find(entries, &(&1.thread.id == thread_id)) do
      {:noreply,
       socket
       |> ThreadNav.close_browser()
       |> push_patch(to: ~p"/?channel=#{channel.slug}&thread=#{thread.id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  defp change_thread("archive_thread", scope, id), do: Chat.archive_thread(scope, id)
  defp change_thread("unarchive_thread", scope, id), do: Chat.unarchive_thread(scope, id)
  defp change_thread("lock_thread", scope, id), do: Chat.lock_thread(scope, id)
  defp change_thread("unlock_thread", scope, id), do: Chat.unlock_thread(scope, id)

  # The open thread's own events already refresh its chip; a closed thread's chip, which shows the
  # reply count and the latest reply, learns of a change only from the parent-channel event.
  defp refresh_closed_thread_chip(socket, message) do
    case socket.assigns.active_thread do
      %{id: id} when id == message.channel_id -> socket
      _ -> State.maybe_refresh_thread_summaries(socket, message.channel)
    end
  end
end
