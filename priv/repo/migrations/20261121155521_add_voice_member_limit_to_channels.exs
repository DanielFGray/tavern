defmodule Tavern.Repo.Migrations.AddVoiceMemberLimitToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :voice_member_limit, :integer, null: false, default: 6
      constraint(:channels, :voice_member_limit_range, check: "voice_member_limit BETWEEN 1 AND 25")
    end
  end
end
