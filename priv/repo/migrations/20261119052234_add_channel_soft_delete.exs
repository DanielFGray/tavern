defmodule Tavern.Repo.Migrations.AddChannelSoftDelete do
  use Ecto.Migration

  # A deleted channel keeps its row (docs/design/channel-management.md). Only live channels hold
  # their slug, so a new channel may reuse the slug of a deleted one.
  def change do
    alter table(:channels) do
      add(:deleted_at, :utc_datetime_usec)
    end

    drop(unique_index(:channels, [:slug]))

    create(
      unique_index(:channels, [:slug],
        where: "deleted_at IS NULL",
        name: :channels_live_slug_index
      )
    )
  end
end
