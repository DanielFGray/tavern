defmodule Tavern.Chat.QuestionAnswer do
  @moduledoc """
  One member's current answer to a question (a vote, in a poll): the options they chose and, when
  they chose "Other", its text. A member has at most one answer per question; changing it
  replaces it and withdrawing deletes it, so the number of answers is the number of answerers.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "question_answers" do
    field(:option_ids, {:array, :binary_id}, default: [])
    field(:other_text, :string)

    belongs_to(:question, Tavern.Chat.Question)
    belongs_to(:user, Tavern.Chat.User)

    timestamps(type: :utc_datetime_usec)
  end
end
