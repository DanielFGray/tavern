defmodule Tavern.Repo.Migrations.AddMessageEmbeds do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add(:suppress_embeds, :boolean, null: false, default: false)
    end

    create table(:message_embeds, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:position, :integer, null: false)
      add(:url, :text, null: false)
      add(:kind, :string, null: false)
      add(:provider, :string)
      add(:title, :text)
      add(:description, :text)
      add(:site_name, :text)
      add(:image_asset_id, references(:media_assets, type: :binary_id, on_delete: :nilify_all))
      add(:video_id, :string)
      add(:fetched_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:message_embeds, [:message_id, :url]))
    create(index(:message_embeds, [:image_asset_id]))
  end
end
