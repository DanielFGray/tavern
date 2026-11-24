defmodule Tavern.Repo.Migrations.AddMessageSearchIndex do
  @moduledoc """
  Indexes message text for `Tavern.Chat.search_messages/3`. The query repeats this exact
  expression, `to_tsvector('simple', body)`, so Postgres can use the index. The `simple`
  configuration lowercases words and does not stem them, so it treats every language alike.
  """
  use Ecto.Migration

  def up do
    execute """
    CREATE INDEX messages_body_search_index ON messages
    USING gin (to_tsvector('simple', body))
    """
  end

  def down do
    execute "DROP INDEX messages_body_search_index"
  end
end
