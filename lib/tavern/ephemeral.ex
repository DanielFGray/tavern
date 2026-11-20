defmodule Tavern.Ephemeral do
  @moduledoc """
  Short-lived state in Valkey: presence, typing and rate-limit counters.

  Every key this module touches starts with the deploy's key prefix (`tavern:` live,
  `tavern-staged:` in a staged copy), because its Valkey user may read and write only keys
  under that prefix. Callers pass keys without it.
  """

  @presence_prefix "presence:user:"
  @typing_prefix "typing:channel:"

  alias Tavern.Valkey

  @presence_online_ttl 300
  @presence_recent_ttl 3600
  @typing_ttl 8

  # A rate-limit check runs inside a send's transaction, so a hung Valkey must not hold it for
  # the client's default 5 s: past this, the call reports Valkey unavailable and the limit applies
  # its outage policy (`Tavern.RateLimit`).
  @rate_limit_timeout_ms 250

  def presence_online_ttl, do: @presence_online_ttl
  def presence_recent_ttl, do: @presence_recent_ttl
  def typing_ttl, do: @typing_ttl

  def heartbeat_presence(user_id, now \\ DateTime.utc_now()) when is_binary(user_id) do
    timestamp = DateTime.to_unix(now, :second)

    case Valkey.command([
           "SET",
           presence_key(user_id),
           Integer.to_string(timestamp),
           "EX",
           "3600"
         ]) do
      {:ok, "OK"} -> :ok
      {:error, _reason} -> :error
    end
  end

  def get_presence_timestamps(user_ids) when is_list(user_ids) do
    keys = Enum.map(user_ids, &presence_key/1)

    case keys do
      [] -> %{}
      _ -> parse_presence_timestamps(user_ids, Valkey.command(["MGET" | keys]))
    end
  end

  def put_typing(channel_id, user_id, now \\ DateTime.utc_now())
      when is_binary(channel_id) and is_binary(user_id) do
    timestamp = DateTime.to_unix(now, :second)
    key = typing_key(channel_id)

    case Valkey.pipeline([
           ["ZADD", key, Integer.to_string(timestamp), user_id],
           ["EXPIRE", key, Integer.to_string(@typing_ttl)]
         ]) do
      {:ok, _results} -> :ok
      {:error, _reason} -> :error
    end
  end

  def remove_typing(channel_id, user_id) when is_binary(channel_id) and is_binary(user_id) do
    case Valkey.command(["ZREM", typing_key(channel_id), user_id]) do
      {:ok, _removed} -> :ok
      {:error, _reason} -> :error
    end
  end

  def list_typing_user_ids(channel_id, now \\ DateTime.utc_now()) when is_binary(channel_id) do
    min_score = DateTime.add(now, -@typing_ttl, :second) |> DateTime.to_unix(:second)

    case Valkey.command([
           "ZRANGEBYSCORE",
           typing_key(channel_id),
           Integer.to_string(min_score),
           "+inf"
         ]) do
      {:ok, user_ids} -> user_ids
      {:error, _reason} -> []
    end
  end

  @doc """
  Counts one hit in the fixed window `key`, and returns the count and when the window ends.
  The window starts at the first hit: `EXPIRE ... NX` sets the expiry only on a key that has
  none, so later hits never extend it.
  """
  def increment_rate_limit(key, window_seconds, now \\ System.system_time(:second))
      when is_binary(key) and is_integer(window_seconds) do
    expires_at = now + window_seconds
    key = namespaced(key)

    case Valkey.pipeline(
           [
             ["INCR", key],
             ["EXPIRE", key, Integer.to_string(window_seconds), "NX"],
             ["TTL", key]
           ],
           timeout: @rate_limit_timeout_ms
         ) do
      {:ok, [count, _expire, ttl]} when is_integer(count) and is_integer(ttl) ->
        {:ok, count, now + max(ttl, 0)}

      {:ok, [count, _expire, -1]} when is_integer(count) ->
        {:ok, count, expires_at}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @doc """
  Takes back one hit counted by `increment_rate_limit/3`, for an action that did not happen.
  When the window ended in between, the DECR makes a new key; the `EXPIRE ... NX` keeps it
  from living forever.
  """
  def release_rate_limit(key, window_seconds)
      when is_binary(key) and is_integer(window_seconds) do
    key = namespaced(key)

    case Valkey.pipeline(
           [
             ["DECR", key],
             ["EXPIRE", key, Integer.to_string(window_seconds), "NX"]
           ],
           timeout: @rate_limit_timeout_ms
         ) do
      {:ok, _results} -> :ok
      {:error, _reason} -> :error
    end
  end

  def clear_rate_limit(key) when is_binary(key) do
    case Valkey.command(["DEL", namespaced(key)]) do
      {:ok, _deleted} -> :ok
      {:error, _reason} -> :error
    end
  end

  def clear_rate_limit_namespace(prefix) when is_binary(prefix) do
    delete_matching(namespaced(prefix) <> "*", "0")
  end

  # SCAN, not KEYS: the deployed Valkey user has no @dangerous commands.
  defp delete_matching(pattern, cursor) do
    with {:ok, [next_cursor, keys]} <-
           Valkey.command(["SCAN", cursor, "MATCH", pattern, "COUNT", "500"]),
         {:ok, _deleted} <- delete_keys(keys) do
      if next_cursor == "0", do: :ok, else: delete_matching(pattern, next_cursor)
    else
      {:error, _reason} -> :error
    end
  end

  defp delete_keys([]), do: {:ok, 0}
  defp delete_keys(keys), do: Valkey.command(["DEL" | keys])

  defp parse_presence_timestamps(user_ids, {:ok, values}) do
    user_ids
    |> Enum.zip(values)
    |> Enum.reduce(%{}, fn
      {user_id, value}, acc when is_binary(value) ->
        Map.put(acc, user_id, DateTime.from_unix!(String.to_integer(value)))

      {_user_id, _value}, acc ->
        acc
    end)
  end

  defp parse_presence_timestamps(_user_ids, {:error, _reason}), do: %{}

  defp presence_key(user_id), do: namespaced(@presence_prefix <> user_id)
  defp typing_key(channel_id), do: namespaced(@typing_prefix <> channel_id)
  defp namespaced(key), do: Application.fetch_env!(:tavern, :valkey_key_prefix) <> key
end
