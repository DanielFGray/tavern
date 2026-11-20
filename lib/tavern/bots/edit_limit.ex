defmodule Tavern.Bots.EditLimit do
  @moduledoc """
  Caps how often a bot may edit one message. A bot that streams a reply edits the same message
  many times, so edits are allowed, but only `message_edits_per_second` of them per message in
  each one-second window (`config :tavern, Tavern.Bots`), counted by `Tavern.RateLimit`.

  The check fails closed: with Valkey unreachable no edit passes.
  """

  alias Tavern.RateLimit

  @doc "Counts one edit of `message_id`. `{:error, {:rate_limited, seconds}}` carries the wait."
  def admit(message_id) when is_binary(message_id) do
    RateLimit.hit([{"bot_edit:" <> message_id, limit(), 1}], :refuse)
  end

  defp limit do
    :tavern
    |> Application.fetch_env!(Tavern.Bots)
    |> Keyword.fetch!(:message_edits_per_second)
  end
end
