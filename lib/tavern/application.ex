defmodule Tavern.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TavernWeb.Telemetry,
      Tavern.Repo,
      Tavern.Redis,
      Tavern.Accounts.LoginRateLimiter,
      {DNSCluster, query: Application.get_env(:tavern, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tavern.PubSub},
      # Link preview fetches (`Tavern.Chat.Embeds`). The cap bounds the outbound requests one
      # burst of messages can start; a write over it gets no embed.
      {Task.Supervisor, name: Tavern.Embeds.TaskSupervisor, max_children: 50},
      # Closes polls when their end time passes. Tests close polls by calling
      # `Tavern.Chat.Polls.close_due/1`, so they run without it.
      Application.get_env(:tavern, :poll_closer, true) && Tavern.Chat.PollCloser,
      # Start a worker by calling: Tavern.Worker.start_link(arg)
      # {Tavern.Worker, arg},
      # Start to serve requests, typically the last entry
      TavernWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tavern.Supervisor]
    Supervisor.start_link(Enum.filter(children, & &1), opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TavernWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
