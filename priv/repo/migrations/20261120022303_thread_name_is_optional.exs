defmodule Tavern.Repo.Migrations.ThreadNameIsOptional do
  use Ecto.Migration

  # A thread stores a name only once someone has named it; until then a view shows the start of
  # its starter message. A channel or category still needs a name.
  def up do
    alter table(:channels) do
      modify(:name, :string, null: true, from: {:string, null: false})
    end

    create(
      constraint(:channels, :channels_name_required_unless_thread,
        check:
          "name IS NOT NULL OR kind IN ('thread_public', 'thread_private', 'thread_announcement')"
      )
    )

    # Before this change a text-channel thread took the first 40 characters of its starter as its
    # name, so a name equal to that text is not a name anyone chose. A forum post keeps its title.
    execute("""
    UPDATE channels AS thread
    SET name = NULL
    FROM messages AS starter, channels AS parent
    WHERE starter.id = thread.starter_message_id
      AND parent.id = thread.parent_channel_id
      AND thread.kind IN ('thread_public', 'thread_private', 'thread_announcement')
      AND parent.kind <> 'forum'
      AND thread.name = COALESCE(
        NULLIF(left(regexp_replace(starter.body, '^\\s+|\\s+$', '', 'g'), 40), ''),
        'Thread'
      )
    """)
  end

  def down do
    execute("""
    UPDATE channels AS thread
    SET name = COALESCE(
      NULLIF(left(regexp_replace(starter.body, '^\\s+|\\s+$', '', 'g'), 40), ''),
      'Thread'
    )
    FROM messages AS starter
    WHERE thread.name IS NULL AND starter.id = thread.starter_message_id
    """)

    execute("UPDATE channels SET name = 'Thread' WHERE name IS NULL")

    drop(constraint(:channels, :channels_name_required_unless_thread))

    alter table(:channels) do
      modify(:name, :string, null: false, from: {:string, null: true})
    end
  end
end
