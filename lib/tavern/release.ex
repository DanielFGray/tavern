defmodule Tavern.Release do
  @moduledoc """
  Release tasks that run without Mix, such as the cartridge's migrate step (`bin/migrate`).
  """
  @app :tavern

  @doc """
  Runs every pending migration, provisions the seed data a fresh server needs and, while the
  server has no owner, prints the setup invite's link (`Tavern.Accounts.ensure_setup_invite/0`).
  """
  def migrate do
    with_repo(fn repo ->
      Ecto.Migrator.run(repo, :up, all: true)
      Tavern.Bootstrap.ensure_seed_data!()
      announce_setup_invite()
    end)
  end

  @doc """
  Prints the setup invite's registration link while the server has no owner, and nothing once
  it has one. The link is built from the endpoint's configured URL, because release commands run
  without the endpoint.
  """
  def announce_setup_invite do
    case Tavern.Accounts.ensure_setup_invite() do
      nil ->
        :ok

      invite ->
        IO.puts("""
        This server has no owner yet. The first account registered with this link owns it:

            #{setup_url(invite.code)}

        The link works once, until #{Calendar.strftime(invite.expires_at, "%Y-%m-%d %H:%M UTC")}.\
        """)
    end
  end

  defp setup_url(code) do
    # As Phoenix does, a url without a port takes the port the endpoint listens on.
    config = Application.get_env(@app, TavernWeb.Endpoint, [])
    url = config[:url] || []
    scheme = Keyword.get(url, :scheme, "http")
    port = Keyword.get(url, :port) || get_in(config, [:http, :port])

    URI.to_string(%URI{
      scheme: scheme,
      host: Keyword.get(url, :host, "localhost"),
      port: if(port in [nil, URI.default_port(scheme)], do: nil, else: port),
      path: "/register",
      query: URI.encode_query(%{"code" => code})
    })
  end

  @doc "Promote an existing account to the first server owner."
  def make_owner(email) do
    with_repo(fn _repo ->
      case Tavern.Accounts.promote_first_owner(email) do
        {:ok, user} ->
          IO.puts("Made #{user.email} the server owner.")

        {:error, reason} ->
          IO.puts(:stderr, "Could not make #{email} the server owner: #{inspect(reason)}")
          System.halt(1)
      end
    end)
  end

  # Release Repo connections must bypass after_connect, which changes them to the visitor role.
  defp with_repo(fun) do
    Application.ensure_loaded(@app)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _} = repo.__adapter__().ensure_all_started(repo.config(), :temporary)
      {:ok, pid} = repo.start_link(pool_size: 2, after_connect: nil)

      try do
        fun.(repo)
      after
        Supervisor.stop(pid)
      end
    end
  end
end
