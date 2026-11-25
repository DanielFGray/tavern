defmodule Tavern.Repo.Migrations.AddWebPush do
  use Ecto.Migration

  # docs/design/push-notifications.md. A device is on for push while it holds a subscription, so
  # the stored `push_enabled` switch goes: nothing ever read it.
  def change do
    create table(:push_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      # The browser session that made it. A push goes only while that session is live, so
      # signing out stops push on that browser; a deleted session takes the row with it.
      add :session_id, references(:user_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :endpoint, :text, null: false
      add :p256dh, :binary, null: false
      add :auth, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])
    create index(:push_subscriptions, [:session_id])

    # One row: the server's VAPID key pair, and the URL it was made for.
    create table(:push_keys, primary_key: false) do
      add :id, :smallint, primary_key: true, default: 1
      add :origin, :text, null: false
      add :public_key, :binary, null: false
      add :private_key, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:push_keys, :push_keys_one_row, check: "id = 1")

    alter table(:user_notification_settings) do
      remove :push_enabled, :boolean, default: false, null: false
    end
  end
end
