defmodule TavernWeb.ServerLive.Events.Navigation do
  @moduledoc false

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias TavernWeb.ServerLive.ForumNav
  alias TavernWeb.ServerLive.MessageJump
  alias TavernWeb.ServerLive.State
  alias TavernWeb.ServerLive.ThreadNav

  @doc """
  Opens the URL's channel and thread, then the message it names in place (`MessageJump`).
  Before navigation is hydrated there is nothing to open; hydration calls this again.
  """
  def handle_params(params, uri, socket) do
    {:noreply, socket} = open_url_conversation(params, uri, socket)

    if socket.assigns.navigation_ready?,
      do: {:noreply, MessageJump.follow(socket)},
      else: {:noreply, socket}
  end

  defp open_url_conversation(%{"thread" => thread_id} = params, _uri, socket) do
    if not socket.assigns.navigation_ready? do
      {:noreply, socket}
    else
      # A panel animates only when the reader opens a thread in the channel already on screen.
      watching = socket.assigns.active_channel
      already_open = socket.assigns.active_thread

      socket =
        case params do
          %{"channel" => slug} ->
            case resolve_channel_for_socket(socket, slug) do
              {:ok, %{id: id}} when id == socket.assigns.active_channel.id ->
                socket

              {:ok, channel} ->
                State.switch_channel(socket, channel)

              _ ->
                socket
            end

          _ ->
            socket
        end

      case Chat.get_thread(socket.assigns.current_scope, thread_id) do
        %{} = thread ->
          {:noreply,
           socket
           |> State.open_thread(thread)
           |> push_panel_entered(thread, watching, already_open)}

        nil ->
          {:noreply, put_flash(socket, :error, "That thread does not exist.")}
      end
    end
  end

  defp open_url_conversation(%{"dm" => id}, _uri, socket) do
    if not socket.assigns.navigation_ready? do
      {:noreply, socket}
    else
      active_id = socket.assigns.active_channel && socket.assigns.active_channel.id

      case Chat.get_direct_message(socket.assigns.current_scope, id) do
        %{id: ^active_id} ->
          {:noreply, socket}

        %{} = dm ->
          {:noreply, State.switch_channel(socket, dm)}

        nil ->
          {:noreply,
           socket
           |> put_flash(:error, "That conversation does not exist.")
           |> State.redirect_to_default_channel()}
      end
    end
  end

  defp open_url_conversation(%{"channel" => slug}, _uri, socket) do
    if not socket.assigns.navigation_ready? do
      {:noreply, socket}
    else
      case resolve_channel_for_socket(socket, slug) do
        {:ok, channel} ->
          if socket.assigns.active_channel && socket.assigns.active_channel.id == channel.id do
            {:noreply, State.close_thread(socket)}
          else
            {:noreply,
             socket
             |> State.switch_channel(channel)}
          end

        {:error, :not_found} ->
          {:noreply,
           socket
           |> put_flash(:error, "That channel does not exist.")
           |> State.redirect_to_default_channel()}
      end
    end
  end

  defp open_url_conversation(_params, _uri, socket) do
    case {socket.assigns.active_channel, List.first(socket.assigns.channels)} do
      {nil, %{} = channel} ->
        {:noreply,
         socket
         |> State.switch_channel(channel)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:channel_created, channel}, socket) do
    if Chat.thread_channel?(channel) do
      {:noreply,
       socket
       |> State.maybe_refresh_thread_summaries(channel)
       |> State.push_entered(["thread-summary-#{channel.starter_message_id}"])
       |> ThreadNav.reload()
       |> ForumNav.reload_for_post(channel)}
    else
      {:noreply, State.refresh_channels(socket)}
    end
  end

  # A thread's reply pill under its starter shows its title and state, so a change to the thread
  # refreshes the summaries as well.
  def handle_info({:channel_updated, channel}, socket) do
    {:noreply,
     socket
     |> State.refresh_channels()
     |> State.refresh_active_thread(channel.id)
     |> State.maybe_refresh_thread_summaries(channel)}
  end

  def handle_info({:channel_deleted, channel}, socket) do
    if Chat.Channel.thread?(channel),
      do: {:noreply, drop_deleted_thread(socket, channel)},
      else: drop_deleted_channel(socket, channel)
  end

  # A DM another member opened, or one this member opened in another tab: subscribe to it, so its
  # first message arrives, and list it once it is listed.
  def handle_info({:direct_message_opened, _channel}, socket),
    do: {:noreply, State.refresh_direct_messages(socket)}

  # A block changes whether this member may send in the DM with the blocked account.
  def handle_info(:blocks_changed, socket),
    do: {:noreply, socket |> State.refresh_direct_messages() |> State.refresh_channels()}

  def handle_info(:channels_reordered, socket) do
    {:noreply, State.refresh_channels(socket)}
  end

  # A role change can show or hide channels for this member.
  def handle_info(:roles_changed, socket) do
    {:noreply, State.refresh_channels(socket)}
  end

  # The reload drops the thread from the sidebar, the browser and a forum's post list; the
  # summaries drop the reply pill under its starter, or the starter's row when it was deleted.
  # The summaries go first: leaving the thread re-renders the starter's row, and a row inserted
  # and then deleted in one render stays, because the client applies a stream's deletes before
  # its inserts.
  defp drop_deleted_thread(socket, thread) do
    socket =
      socket
      |> State.refresh_channels()
      |> State.maybe_refresh_thread_summaries(thread)

    if match?(%{id: id} when id == thread.id, socket.assigns.active_thread),
      do: socket |> State.leave_thread() |> put_flash(:info, "Thread deleted."),
      else: socket
  end

  # The active channel is read before the refresh, which drops a channel that is no longer visible.
  defp drop_deleted_channel(socket, channel) do
    viewing? = match?(%{id: id} when id == channel.id, socket.assigns.active_channel)
    socket = State.refresh_channels(socket)

    if viewing? do
      {:noreply,
       socket
       |> put_flash(:info, "Channel deleted.")
       |> State.redirect_to_default_channel()}
    else
      {:noreply, socket}
    end
  end

  defp push_panel_entered(socket, thread, watching, already_open) do
    if watching && watching.id == thread.parent_channel_id &&
         (is_nil(already_open) or already_open.id != thread.id),
       do: State.push_entered(socket, [State.thread_panel_dom_id(thread)]),
       else: socket
  end

  defp resolve_channel_for_socket(socket, slug) do
    case Enum.find(socket.assigns.channels, &(&1.slug == slug)) do
      %{} = channel ->
        {:ok, channel}

      nil ->
        # A slug outside the visible list is either hidden from this user or missing.
        case Chat.get_channel_by_slug(socket.assigns.current_scope, slug) do
          nil -> {:error, :not_found}
          channel -> {:ok, channel}
        end
    end
  end
end
