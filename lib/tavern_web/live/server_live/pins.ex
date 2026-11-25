defmodule TavernWeb.ServerLive.Pins do
  @moduledoc """
  The pins drawer and the pin and unpin actions. `:pins` is nil while the drawer is closed, or
  `%{channel, messages}`: the channel or open thread whose pins it lists, and those pins, most
  recently pinned first (`Tavern.Chat.list_pins/2`).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias Tavern.Chat.Pins
  alias TavernWeb.ServerLive.State

  @doc "Opens the drawer for `channel_id`, which must be the open channel or the open thread."
  def open(socket, channel_id) do
    with %{} = channel <- open_conversation(socket, channel_id),
         {:ok, messages} <- Chat.list_pins(socket.assigns.current_scope, channel.id) do
      assign(socket, :pins, %{channel: channel, messages: messages})
    else
      _ -> socket
    end
  end

  def close(socket), do: assign(socket, :pins, nil)

  @doc """
  Closes the drawer when its conversation is no longer the open channel or thread, as after
  browser Back. The drawer's Unpin buttons take the rights of the open conversation.
  """
  def follow_conversation(socket) do
    case socket.assigns.pins do
      %{channel: %{id: id}} -> if open_conversation(socket, id), do: socket, else: close(socket)
      nil -> socket
    end
  end

  @doc "Lists the open drawer's pins again when `message` belongs to its conversation."
  def refresh(socket, %{channel_id: channel_id}) do
    case socket.assigns.pins do
      %{channel: %{id: ^channel_id}} -> open(socket, channel_id)
      _ -> socket
    end
  end

  @doc """
  Pins or unpins (`action`) a message of the open channel or thread, closes the message menu and
  shows the change. An id outside the open conversations does nothing.
  """
  def write(socket, action, message_id) when action in [:pin, :unpin] do
    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         {:ok, written, line} <- write_pin(socket.assigns.current_scope, action, message.id) do
      socket
      |> State.close_message_ui()
      |> State.rerender_messages([written.id])
      |> then(&if(line, do: State.insert_message(&1, line), else: &1))
      |> refresh(written)
    else
      :error ->
        socket

      {:error, {:rate_limited, seconds}} ->
        put_flash(socket, :error, "You are pinning too fast. Try again in #{seconds}s.")

      {:error, :pin_limit} ->
        put_flash(
          socket,
          :error,
          "This conversation already has #{Pins.limit()} pins. Unpin one first."
        )

      {:error, _reason} ->
        put_flash(socket, :error, "You cannot change that message's pin.")
    end
  end

  # This session hears no broadcast of its own write, so it shows the pin line itself.
  defp write_pin(scope, :pin, message_id) do
    with {:ok, %{message: message, line: line}} <- Chat.pin_message(scope, message_id),
         do: {:ok, message, line}
  end

  defp write_pin(scope, :unpin, message_id) do
    with {:ok, message} <- Chat.unpin_message(scope, message_id), do: {:ok, message, nil}
  end

  defp open_conversation(socket, channel_id) do
    Enum.find(
      [socket.assigns.active_thread, socket.assigns.active_channel],
      &match?(%{id: ^channel_id}, &1)
    )
  end
end
