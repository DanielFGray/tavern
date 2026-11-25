defmodule Tavern.Repo.Migrations.AddDirectMessages do
  use Ecto.Migration

  # A direct message is a channel row of kind `direct` that names its two participants, the lower
  # id first (docs/design/direct-messages.md). The constraint ties the two columns to the kind, so
  # no other kind can name participants and no DM can lack them.
  def change do
    alter table(:channels) do
      add(:direct_low_user_id, references(:users, type: :binary_id, on_delete: :restrict))
      add(:direct_high_user_id, references(:users, type: :binary_id, on_delete: :restrict))
    end

    create(
      constraint(:channels, :direct_participants,
        check: """
        (kind = 'direct') = (direct_low_user_id IS NOT NULL AND direct_high_user_id IS NOT NULL)
        AND (direct_low_user_id IS NULL OR direct_low_user_id < direct_high_user_id)
        """
      )
    )

    create(
      unique_index(:channels, [:direct_low_user_id, :direct_high_user_id],
        where: "deleted_at IS NULL",
        name: :channels_direct_pair_index
      )
    )

    create(index(:channels, [:direct_high_user_id], where: "direct_high_user_id IS NOT NULL"))

    # Each viewer sees a DM under its peer's name, so a DM stores none, as an unnamed thread does.
    execute(
      "ALTER TABLE channels DROP CONSTRAINT channels_name_required_unless_thread",
      """
      ALTER TABLE channels ADD CONSTRAINT channels_name_required_unless_thread
      CHECK (name IS NOT NULL OR kind IN ('thread_public', 'thread_private', 'thread_announcement'))
      """
    )

    create(
      constraint(:channels, :channels_name_required,
        check:
          "name IS NOT NULL OR kind IN ('thread_public', 'thread_private', 'thread_announcement', 'direct')"
      )
    )

    create table(:user_blocks, primary_key: false) do
      add(:blocker_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:blocked_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(constraint(:user_blocks, :not_self, check: "blocker_id <> blocked_id"))
    create(index(:user_blocks, [:blocked_id]))

    alter table(:users) do
      add(:direct_messages_from_new_contacts, :boolean, null: false, default: true)
    end

    # Fixed when the server is created. A server that exists before this migration is private.
    alter table(:server_settings) do
      add(:direct_message_privacy, :string, null: false, default: "private")
    end

    create(
      constraint(:server_settings, :direct_message_privacy_known,
        check: "direct_message_privacy IN ('private', 'owner_can_read')"
      )
    )
  end
end
