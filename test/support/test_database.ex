defmodule Tavern.TestDatabase do
  @moduledoc """
  The platform gives a checkout one test database, and the ExUnit suite and the Playwright
  suite share it. Each suite empties it when it starts, so neither depends on the other to
  clean up after itself.
  """

  alias Tavern.Repo

  @doc """
  Truncates every table except `schema_migrations` and restarts the sequences. Under the SQL
  sandbox it runs outside the sandbox, so the change commits; the e2e server's ordinary pool
  commits it already.
  """
  def truncate! do
    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &truncate_all/0)
    else
      truncate_all()
    end

    :ok
  end

  defp truncate_all do
    %{rows: tables} =
      Repo.query!("""
      SELECT format('%I.%I', schemaname, tablename)
      FROM pg_tables
      WHERE schemaname = 'public' AND tablename <> 'schema_migrations'
      """)

    Repo.query!("TRUNCATE #{Enum.map_join(tables, ", ", &hd/1)} RESTART IDENTITY CASCADE")
  end
end
