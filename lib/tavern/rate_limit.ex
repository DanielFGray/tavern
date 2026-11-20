defmodule Tavern.RateLimit do
  @moduledoc """
  The one rate-limit mechanism (docs/design/rate-limits.md). Each limit in the app is a module
  that names its buckets; this module counts them.

  A bucket is `{key, limit, window_seconds}`: at most `limit` hits in a fixed window that starts
  at the key's first hit. The count lives in Valkey (`Tavern.Ephemeral`), so it holds across
  nodes. Every key sits under `rate_limit:`.

  A limit chooses what a Valkey outage does:

    * `:refuse` — the hit is refused with `{:error, :unavailable}`. For actions that must not
      ride an outage, such as mail to strangers.
    * `:count_locally` — the hit is counted in this node's ETS table instead. For actions that
      Valkey must not be able to stop, such as logging in and sending messages. Each node then
      counts on its own, so a member may get one allowance per node until Valkey returns.

  This process only owns that ETS table.
  """

  use GenServer

  alias Tavern.Ephemeral

  @prefix "rate_limit:"
  @table :tavern_rate_limit

  @type bucket :: {key :: String.t(), limit :: pos_integer(), window_seconds :: pos_integer()}
  @type outage :: :refuse | :count_locally

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one hit in every bucket. Returns `:ok` when each is within its limit. Over any limit it
  returns `{:error, {:rate_limited, seconds}}`, where `seconds` is the longest wait among the
  buckets over their limit, and hands the hit back to every bucket that was within its limit, so
  a refused action spends no allowance. `{:error, :unavailable}` comes only with
  `outage: :refuse`.
  """
  @spec hit([bucket()], outage()) ::
          :ok | {:error, {:rate_limited, pos_integer()}} | {:error, :unavailable}
  def hit(buckets, outage) when outage in [:refuse, :count_locally] do
    now = System.system_time(:second)
    counts = Enum.map(buckets, &count(&1, outage, now))

    waits =
      for {_store, {_key, limit, _window}, count, reset_at} <- counts, count > limit do
        max(reset_at - now, 1)
      end

    cond do
      :unavailable in counts ->
        hand_back(counts)
        {:error, :unavailable}

      waits == [] ->
        :ok

      true ->
        hand_back(counts)
        {:error, {:rate_limited, Enum.max(waits)}}
    end
  end

  @doc """
  Hands back one hit in each bucket, for an action that `hit/2` admitted but that did not
  happen. It reaches Valkey only: a limit that releases uses `outage: :refuse`.
  """
  @spec release([bucket()]) :: :ok
  def release(buckets) do
    Enum.each(buckets, fn {key, _limit, window} ->
      Ephemeral.release_rate_limit(@prefix <> key, window)
    end)
  end

  @doc "Ends the window of the bucket `key` now, in Valkey and in this node's table."
  def clear(key) when is_binary(key) do
    _ = Ephemeral.clear_rate_limit(@prefix <> key)
    :ets.delete(@table, @prefix <> key)
    :ok
  end

  @doc "Ends every window whose key starts with `namespace`. Tests only."
  def reset!(namespace) when is_binary(namespace) do
    prefix = @prefix <> namespace
    _ = Ephemeral.clear_rate_limit_namespace(prefix)

    fn {key, _, _}, keys -> [key | keys] end
    |> :ets.foldl([], @table)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.each(&:ets.delete(@table, &1))

    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  defp count({key, _limit, window} = bucket, outage, now) do
    case Ephemeral.increment_rate_limit(@prefix <> key, window, now) do
      {:ok, count, reset_at} ->
        {:valkey, bucket, count, reset_at}

      {:error, :unavailable} when outage == :count_locally ->
        {count, reset_at} = count_locally(@prefix <> key, window, now)
        {:local, bucket, count, reset_at}

      {:error, :unavailable} ->
        :unavailable
    end
  end

  # Each step is one atomic ets call: the delete removes only windows that have ended (every
  # key's, so the table stays small through a long outage), and update_counter inserts a fresh
  # window when the row is missing, so concurrent callers never read a row another deletes.
  defp count_locally(key, window, now) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])

    [count, reset_at] =
      :ets.update_counter(@table, key, [{2, 1}, {3, 0}], {key, 0, now + window})

    {count, reset_at}
  end

  # Only a bucket that was within its limit gets its hit back. A bucket over its limit keeps the
  # extra count, which admits nothing more in a fixed window, and so never meets the race where a
  # hand-back lands after its window ended and starts the next window one below zero.
  defp hand_back(counts) do
    Enum.each(counts, fn
      {:valkey, {key, limit, window}, count, _reset_at} when count <= limit ->
        Ephemeral.release_rate_limit(@prefix <> key, window)

      {:local, {key, limit, _window}, count, _reset_at} when count <= limit ->
        :ets.update_counter(@table, @prefix <> key, {2, -1}, {@prefix <> key, 1, 0})

      _over_or_unavailable ->
        :ok
    end)
  end
end
