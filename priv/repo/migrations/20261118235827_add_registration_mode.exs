defmodule Tavern.Repo.Migrations.AddRegistrationMode do
  use Ecto.Migration

  def change do
    alter table(:server_settings) do
      add(:registration_mode, :string, null: false, default: "open")
    end
  end
end
