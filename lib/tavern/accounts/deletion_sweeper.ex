defmodule Tavern.Accounts.DeletionSweeper do
  @moduledoc """
  Deletes accounts whose scheduled deletion time has passed (`Tavern.Accounts.delete_due_accounts/1`).
  It sweeps one minute after start and then every hour. A deletion is due days ahead, so an hour
  late costs nothing. The sweep is safe to run on every node at once: each account is deleted
  under its membership row lock, after the schedule is checked again.
  """
  use GenServer

  alias Tavern.Accounts

  @first_sweep_ms 60_000
  @sweep_ms 3_600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @first_sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    Accounts.delete_due_accounts(DateTime.utc_now())
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
