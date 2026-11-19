defmodule Tavern.Repo.Migrations.AddForumPosts do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add(:hashtags, {:array, :text}, null: false, default: [])
    end

    # A tag filter reads `hashtags @> ARRAY[...]`, which this index serves.
    create(index(:channels, [:hashtags], using: :gin))

    alter table(:channel_memberships) do
      add(:post_sort, :string, null: false, default: "activity")
      add(:post_layout, :string, null: false, default: "list")
    end
  end
end
