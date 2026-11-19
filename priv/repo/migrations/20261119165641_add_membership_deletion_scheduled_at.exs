defmodule Tavern.Repo.Migrations.AddMembershipDeletionScheduledAt do
  use Ecto.Migration

  def change do
    alter table(:memberships) do
      add(:deletion_scheduled_at, :utc_datetime_usec)
    end

    # The deletion sweep reads only the memberships that carry a date.
    create(
      index(:memberships, [:deletion_scheduled_at], where: "deletion_scheduled_at IS NOT NULL")
    )
  end
end
