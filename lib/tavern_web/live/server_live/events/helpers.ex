defmodule TavernWeb.ServerLive.Events.Helpers do
  @moduledoc false

  def normalize_message_id(message_id), do: message_id

  def slowmode_message(seconds_left),
    do: "Slowmode is on. You can send again in #{seconds_left}s."
end
