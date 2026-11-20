defmodule Tavern.Chat.SendLimit do
  @moduledoc """
  The per-member message rate limit (docs/design/rate-limits.md). Every message a member writes
  counts, in any channel or thread and from any client: the browser, a poll, a forum post, the
  bot API or the user API all reach `Tavern.Chat.Messages.write_message/3`, which asks here
  first. Slowmode (`Tavern.Chat.Slowmode`) is a separate rule that one channel sets.

  The windows live in `config :tavern, Tavern.Chat.SendLimit, windows: [{messages, seconds}]`,
  counted by `Tavern.RateLimit`. They count locally through a Valkey outage: Valkey must not be
  able to stop the chat.
  """

  alias Tavern.RateLimit

  @doc "Counts one message by `user_id`. Returns `:ok` or `{:error, {:rate_limited, seconds}}`."
  def admit(user_id) when is_binary(user_id) do
    :tavern
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:windows)
    |> Enum.map(fn {messages, seconds} ->
      {"send:#{user_id}:#{seconds}", messages, seconds}
    end)
    |> RateLimit.hit(:count_locally)
  end
end
