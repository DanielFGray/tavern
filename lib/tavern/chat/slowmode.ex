defmodule Tavern.Chat.Slowmode do
  @moduledoc """
  The slowmode rule: a channel with `slowmode_seconds` spaces each member's writes at least that
  far apart. A message in a channel and a post in a forum are both writes the rule spaces; each
  caller says what counts as the member's last write there.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @doc """
  `:ok` when the scope may write to `channel` now, else `{:error, {:slowmode, seconds_left}}`.
  `last_write_at` is a query that selects the time of the scope's last write there (one
  `max(...)` value, or nil for none). A scope with `:bypass_slowmode` is never refused.
  """
  def enforce(%Scope{}, %Channel{slowmode_seconds: 0}, _last_write_at), do: :ok

  def enforce(%Scope{} = scope, %Channel{slowmode_seconds: seconds} = channel, last_write_at) do
    left =
      case Repo.one(last_write_at) do
        nil -> 0
        last -> seconds - DateTime.diff(DateTime.utc_now(), last, :millisecond) / 1000
      end

    cond do
      left <= 0 -> :ok
      Visibility.can?(scope, :bypass_slowmode, channel) -> :ok
      true -> {:error, {:slowmode, ceil(left)}}
    end
  end
end
