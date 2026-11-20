defmodule TavernWeb.ServerLive.Events.Helpers do
  @moduledoc false

  def slowmode_message(seconds_left),
    do: "Slowmode is on. You can send again in #{seconds_left}s."

  def send_limit_message(seconds_left),
    do: "You are sending messages too fast. You can send again in #{seconds_left}s."
end
