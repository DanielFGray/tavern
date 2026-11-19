defmodule Tavern.Repo.Migrations.AddRoleDenyPermissions do
  use Ecto.Migration

  def change do
    alter table(:roles) do
      add(:deny_permissions, :bigint, null: false, default: 0)
    end

    create(
      constraint(:roles, :role_bits_allowed_or_denied,
        check: "(permissions & deny_permissions) = 0"
      )
    )

    # The default role is the base that every other role's deny subtracts from.
    create(
      constraint(:roles, :default_role_denies_nothing,
        check: "NOT is_default OR deny_permissions = 0"
      )
    )
  end
end
