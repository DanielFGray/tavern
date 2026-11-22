defmodule Tavern.Repo.Migrations.RenamePollsToQuestions do
  @moduledoc """
  A poll becomes one kind of question (docs/design/questions.md). The tables, columns, indexes
  and constraints take the question names, every existing row becomes a `poll`, and options gain
  the `kind` a permission request's options carry.
  """
  use Ecto.Migration

  # {old, new} names of indexes and constraints Postgres keeps across a table rename. A check
  # constraint's expression follows its column's rename by itself.
  @indexes [
    {"polls_pkey", "questions_pkey"},
    {"polls_message_id_index", "questions_message_id_index"},
    {"polls_closes_at_index", "questions_closes_at_index"},
    {"poll_options_pkey", "question_options_pkey"},
    {"poll_options_poll_id_position_index", "question_options_question_id_position_index"},
    {"poll_ballots_pkey", "question_answers_pkey"},
    {"poll_ballots_poll_id_user_id_index", "question_answers_question_id_user_id_index"}
  ]

  @constraints [
    {"questions", "polls_message_id_fkey", "questions_message_id_fkey"},
    {"questions", "max_voters_positive", "max_answers_positive"},
    {"question_options", "poll_options_poll_id_fkey", "question_options_question_id_fkey"},
    {"question_answers", "poll_ballots_poll_id_fkey", "question_answers_question_id_fkey"},
    {"question_answers", "poll_ballots_user_id_fkey", "question_answers_user_id_fkey"}
  ]

  def up do
    rename(table(:polls), to: table(:questions))
    rename(table(:poll_options), to: table(:question_options))
    rename(table(:poll_ballots), to: table(:question_answers))

    rename(table(:questions), :max_voters, to: :max_answers)
    rename(table(:questions), :voter_user_ids, to: :answerer_user_ids)
    rename(table(:questions), :voter_role_ids, to: :answerer_role_ids)
    rename(table(:question_options), :poll_id, to: :question_id)
    rename(table(:question_answers), :poll_id, to: :question_id)

    for {old, new} <- @indexes, do: execute("ALTER INDEX #{old} RENAME TO #{new}")

    for {table, old, new} <- @constraints,
        do: execute("ALTER TABLE #{table} RENAME CONSTRAINT #{old} TO #{new}")

    alter table(:questions) do
      add(:kind, :string, null: false, default: "poll")
    end

    create(constraint(:questions, :kind_known, check: "kind IN ('poll', 'ask', 'permission')"))

    alter table(:question_options) do
      add(:kind, :string)
    end

    create(
      constraint(:question_options, :kind_known,
        check: "kind IS NULL OR kind IN ('allow_once', 'allow_always', 'reject')"
      )
    )
  end

  def down do
    drop(constraint(:question_options, :kind_known))

    alter table(:question_options) do
      remove(:kind)
    end

    drop(constraint(:questions, :kind_known))

    alter table(:questions) do
      remove(:kind)
    end

    for {table, old, new} <- @constraints,
        do: execute("ALTER TABLE #{table} RENAME CONSTRAINT #{new} TO #{old}")

    for {old, new} <- @indexes, do: execute("ALTER INDEX #{new} RENAME TO #{old}")

    rename(table(:question_answers), :question_id, to: :poll_id)
    rename(table(:question_options), :question_id, to: :poll_id)
    rename(table(:questions), :answerer_role_ids, to: :voter_role_ids)
    rename(table(:questions), :answerer_user_ids, to: :voter_user_ids)
    rename(table(:questions), :max_answers, to: :max_voters)

    rename(table(:question_answers), to: table(:poll_ballots))
    rename(table(:question_options), to: table(:poll_options))
    rename(table(:questions), to: table(:polls))
  end
end
