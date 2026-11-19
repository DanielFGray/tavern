defmodule Tavern.Repo.Migrations.AddInviteRequests do
  use Ecto.Migration

  def change do
    alter table(:server_settings) do
      add(:accept_invite_requests, :boolean, null: false, default: false)
    end

    create table(:invite_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:email, :citext, null: false)
      add(:ip_address, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:requested_at, :utc_datetime_usec, null: false)
      add(:decided_at, :utc_datetime_usec)
      add(:decided_by_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:invite_id, references(:invites, type: :binary_id, on_delete: :nilify_all))
      add(:delivered_at, :utc_datetime_usec)
      add(:delivery_error, :text)
    end

    # One pending request per address; a decided request does not block a later one.
    create(
      unique_index(:invite_requests, [:email],
        where: "status = 'pending'",
        name: :invite_requests_pending_email_index
      )
    )

    create(index(:invite_requests, [:status, :requested_at]))
    create(index(:invite_requests, [:ip_address]))
  end
end
