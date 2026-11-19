defmodule Tavern.Repo.Migrations.AddEmailVerification do
  @moduledoc """
  Marks the Unverified system role, and marks every existing account verified.

  `roles.is_unverified` names the one role every member with an unconfirmed email holds without a
  `member_roles` row (docs/design/accounts.md). Bootstrap creates the row; this migration only
  adds the column and its rules.

  Every account that exists now gets `confirmed_at`, so turning verification on restricts no
  current member. Deleted accounts keep `confirmed_at` empty, as the deletion wipe left it.
  """
  use Ecto.Migration

  def up do
    alter table(:roles) do
      add(:is_unverified, :boolean, null: false, default: false)
    end

    create(unique_index(:roles, [:is_unverified], where: "is_unverified = true"))

    create(
      constraint(:roles, :unverified_role_is_not_default,
        check: "NOT (is_default AND is_unverified)"
      )
    )

    execute("""
    UPDATE users SET confirmed_at = now() WHERE confirmed_at IS NULL AND deleted_at IS NULL
    """)
  end

  def down do
    drop(constraint(:roles, :unverified_role_is_not_default))
    drop(index(:roles, [:is_unverified], where: "is_unverified = true"))

    alter table(:roles) do
      remove(:is_unverified)
    end
  end
end
