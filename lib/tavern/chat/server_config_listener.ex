defmodule Tavern.Chat.ServerConfigListener do
  @moduledoc """
  Drops this node's cached server settings when any node commits a settings change
  (`Tavern.Chat.Topics.broadcast_server_settings_changed/0`). The next read loads the new
  settings from the database in the reading process. This process never queries the database,
  so it needs no connection and cannot fail when a test's database owner has stopped.
  """
  use GenServer

  alias Tavern.Chat.ServerConfig
  alias Tavern.Chat.Topics

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = Topics.subscribe_server_settings()
    {:ok, nil}
  end

  @impl true
  def handle_info(:server_settings_changed, state) do
    ServerConfig.reset_server_settings_cache()
    {:noreply, state}
  end
end
