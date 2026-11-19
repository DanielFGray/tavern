defmodule Tavern.Chat.PollCloser do
  @moduledoc """
  Closes polls when their end time passes (`Tavern.Chat.Polls.close_due/1`), so bots receive
  `poll.closed` without anyone voting. It wakes at the next end time it knows of, and at least
  every `@sweep_ms`, which also picks up polls created on another node. Votes do not depend on
  it: a vote after the end time is refused under the poll row lock.
  """
  use GenServer

  alias Tavern.Chat.Polls

  @sweep_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks the closer to wake by `closes_at`. Does nothing where the closer does not run."
  def schedule(%DateTime{} = closes_at) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:schedule, closes_at})
    end
  end

  @impl true
  def init(_opts), do: {:ok, arm(nil, DateTime.add(DateTime.utc_now(), @sweep_ms, :millisecond))}

  @impl true
  def handle_cast({:schedule, closes_at}, timer), do: {:noreply, arm(timer, closes_at)}

  @impl true
  def handle_info(:sweep, _timer) do
    next = Polls.close_due(DateTime.utc_now())
    {:noreply, arm(nil, next)}
  end

  # Keeps one timer, set for the earlier of the wanted time and the current timer, and never later
  # than one sweep from now.
  defp arm(timer, wanted) do
    now = DateTime.utc_now()
    wanted_ms = if wanted, do: max(DateTime.diff(wanted, now, :millisecond), 0), else: @sweep_ms
    wanted_ms = min(wanted_ms, @sweep_ms)
    current_ms = timer && Process.read_timer(timer)

    if current_ms && current_ms <= wanted_ms do
      timer
    else
      if timer, do: Process.cancel_timer(timer)
      Process.send_after(self(), :sweep, wanted_ms)
    end
  end
end
