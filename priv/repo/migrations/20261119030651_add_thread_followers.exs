defmodule Tavern.Repo.Migrations.AddThreadFollowers do
  use Ecto.Migration

  def change do
    create table(:thread_followers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:thread_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:source, :string, null: false)
      add(:followed_at, :utc_datetime_usec, null: false)
      add(:unfollowed_at, :utc_datetime_usec)
    end

    create(unique_index(:thread_followers, [:thread_id, :user_id]))
    create(index(:thread_followers, [:user_id]))
  end
end
