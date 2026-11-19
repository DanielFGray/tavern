defmodule Tavern.Bots.EditLimit do
  @moduledoc """
  Caps how often a bot may edit one message. A bot that streams a reply edits the same message
  many times, so edits are allowed, but only `message_edits_per_second` of them per message in
  each one-second window (`config :tavern, Tavern.Bots`). The count lives in Valkey through
  `Tavern.Ephemeral`, so it holds across nodes.

  The check fails closed: with Valkey unreachable no edit passes.
  """

  alias Tavern.Ephemeral

  @window 1
  @prefix "rate_limit:bot_edit:"

  @doc "Counts one edit of `message_id`. `{:error, {:rate_limited, seconds}}` carries the wait."
  def admit(message_id) when is_binary(message_id) do
    case Ephemeral.increment_rate_limit(@prefix <> message_id, @window) do
      {:ok, count, _reset_at} ->
        if count <= limit(), do: :ok, else: {:error, {:rate_limited, @window}}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  defp limit do
    :tavern
    |> Application.fetch_env!(Tavern.Bots)
    |> Keyword.fetch!(:message_edits_per_second)
  end
end
