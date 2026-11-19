defmodule Tavern.Repo.Migrations.AddPolls do
  use Ecto.Migration

  def change do
    create table(:polls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:multi_select, :boolean, null: false, default: false)
      add(:anonymous, :boolean, null: false, default: false)
      add(:allow_other, :boolean, null: false, default: false)
      add(:closes_at, :utc_datetime_usec)
      add(:closed_at, :utc_datetime_usec)
      add(:max_voters, :integer)
      add(:voter_user_ids, {:array, :binary_id}, null: false, default: [])
      add(:voter_role_ids, {:array, :binary_id}, null: false, default: [])

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:polls, [:message_id]))
    create(index(:polls, [:closes_at], where: "closed_at IS NULL AND closes_at IS NOT NULL"))

    create(
      constraint(:polls, :max_voters_positive, check: "max_voters IS NULL OR max_voters > 0")
    )

    create table(:poll_options, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:poll_id, references(:polls, type: :binary_id, on_delete: :delete_all), null: false)
      add(:position, :integer, null: false)
      add(:label, :text, null: false)
    end

    create(unique_index(:poll_options, [:poll_id, :position]))

    create table(:poll_ballots, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:poll_id, references(:polls, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:option_ids, {:array, :binary_id}, null: false, default: [])
      add(:other_text, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:poll_ballots, [:poll_id, :user_id]))
  end
end
