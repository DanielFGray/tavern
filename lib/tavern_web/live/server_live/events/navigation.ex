defmodule TavernWeb.ServerLive.Events.Navigation do
  @moduledoc false

  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3]

  alias Tavern.Chat
  alias TavernWeb.ServerLive.ForumNav
  alias TavernWeb.ServerLive.State
  alias TavernWeb.ServerLive.ThreadNav

  def handle_params(%{"thread" => thread_id} = params, _uri, socket) do
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

  def handle_params(%{"channel" => slug}, _uri, socket) do
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
             |> State.switch_channel(channel)
             |> reattach_videos(channel)}
          end

        {:error, :not_found} ->
          {:noreply,
           socket
           |> put_flash(:error, "That channel does not exist.")
           |> State.redirect_to_default_channel()}
      end
    end
  end

  def handle_params(_params, _uri, socket) do
    case {socket.assigns.active_channel, List.first(socket.assigns.channels)} do
      {nil, %{} = channel} ->
        {:noreply,
         socket
         |> State.switch_channel(channel)}

      _ ->
        {:noreply, socket}
    end
  end

  # Video tracks received while the reader was in another channel wait in the hook's buffer;
  # returning to the voice channel asks the hook to place them in the tiles again.
  defp reattach_videos(socket, %Tavern.Chat.Channel{kind: :voice} = channel) do
    if socket.assigns.voice_channel && socket.assigns.voice_channel.id == channel.id do
      push_event(socket, "voice_video_reattach", %{})
    else
      socket
    end
  end

  defp reattach_videos(socket, _channel), do: socket

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

  def handle_info(:channels_reordered, socket) do
    {:noreply, State.refresh_channels(socket)}
  end

  # A role change can show or hide channels for this member.
  def handle_info(:roles_changed, socket) do
    {:noreply, State.refresh_channels(socket)}
  end

  # The reload drops the thread from the sidebar, the browser and a forum's post list; the
  # summaries drop the reply pill under its starter.
  defp drop_deleted_thread(socket, thread) do
    socket =
      if match?(%{id: id} when id == thread.id, socket.assigns.active_thread),
        do: socket |> State.leave_thread() |> put_flash(:info, "Thread deleted."),
        else: socket

    socket
    |> State.refresh_channels()
    |> State.maybe_refresh_thread_summaries(thread)
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
