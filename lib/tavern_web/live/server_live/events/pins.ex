defmodule TavernWeb.ServerLive.Events.Pins do
  @moduledoc false

  alias TavernWeb.ServerLive.Pins

  @events ~w(open_pins close_pins pin_message unpin_message)

  def events, do: @events

  def handle_event("open_pins", %{"channel-id" => channel_id}, socket),
    do: {:noreply, Pins.open(socket, channel_id)}

  def handle_event("close_pins", _params, socket), do: {:noreply, Pins.close(socket)}

  def handle_event("pin_message", %{"id" => message_id}, socket),
    do: {:noreply, Pins.write(socket, :pin, message_id)}

  def handle_event("unpin_message", %{"id" => message_id}, socket),
    do: {:noreply, Pins.write(socket, :unpin, message_id)}
end
