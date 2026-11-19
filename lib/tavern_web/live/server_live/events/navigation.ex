defmodule TavernWeb.ServerLive.Events.Navigation do
  @moduledoc false

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias TavernWeb.ServerLive.ForumNav
  alias TavernWeb.ServerLive.State
  alias TavernWeb.ServerLive.ThreadNav

  def handle_params(%{"thread" => thread_id} = params, _uri, socket) do
    if not socket.assigns.navigation_ready? do
      {:noreply, socket}
    else
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
          {:noreply, State.open_thread(socket, thread)}

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

  def handle_info({:channel_created, channel}, socket) do
    if Chat.thread_channel?(channel) do
      {:noreply,
       socket
       |> State.maybe_refresh_thread_summaries(channel)
       |> ThreadNav.reload()
       |> ForumNav.reload_for_post(channel)}
    else
      {:noreply, State.refresh_channels(socket)}
    end
  end

  def handle_info({:channel_updated, channel}, socket) do
    {:noreply, socket |> State.refresh_channels() |> State.refresh_active_thread(channel.id)}
  end

  # The active channel is read before the refresh, which drops a channel that is no longer visible.
  def handle_info({:channel_deleted, channel}, socket) do
    viewing? = match?(%{id: id} when id == channel.id, socket.assigns.active_channel)
    socket = State.refresh_channels(socket)

    cond do
      viewing? ->
        {:noreply,
         socket
         |> put_flash(:info, "Channel deleted.")
         |> State.redirect_to_default_channel()}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(:channels_reordered, socket) do
    {:noreply, State.refresh_channels(socket)}
  end

  # A role change can show or hide channels for this member.
  def handle_info(:roles_changed, socket) do
    {:noreply, State.refresh_channels(socket)}
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
