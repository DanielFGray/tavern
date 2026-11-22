defmodule Tavern.Chat.QuestionOption do
  @moduledoc """
  One option of a question. `kind` is set only on a permission request's options and says what
  choosing it means (the permission option kinds of the Agent Client Protocol), so the card can
  style an allow apart from a reject. The label stays the bot's own words.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:allow_once, :allow_always, :reject]

  schema "question_options" do
    field(:position, :integer)
    field(:label, :string)
    field(:kind, Ecto.Enum, values: @kinds)

    belongs_to(:question, Tavern.Chat.Question)
  end

  @doc "The kinds a permission request's option may have."
  def kinds, do: @kinds
end
