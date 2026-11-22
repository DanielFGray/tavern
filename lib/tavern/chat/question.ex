defmodule Tavern.Chat.Question do
  @moduledoc """
  A question on a message (docs/design/questions.md). The message body is the question text.

  `kind` says what the question is for:

  - `:poll`: members vote, see the counts and voters, and may change their vote.
  - `:ask`: a bot asks one of the members it names, who answers once.
  - `:permission`: a bot asks to run something; one named member allows or rejects it once.

  An ask and a permission request are prompts: they close on their first answer (`max_answers` is
  1) and are never anonymous. A question is open until `closed_at` is set or `closes_at` has
  passed; `closed?/2` is the one rule.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:poll, :ask, :permission]

  schema "questions" do
    field(:kind, Ecto.Enum, values: @kinds, default: :poll)
    field(:multi_select, :boolean, default: false)
    field(:anonymous, :boolean, default: false)
    field(:allow_other, :boolean, default: false)
    field(:closes_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)
    field(:max_answers, :integer)
    field(:answerer_user_ids, {:array, :binary_id}, default: [])
    field(:answerer_role_ids, {:array, :binary_id}, default: [])

    belongs_to(:message, Tavern.Chat.Message)
    has_many(:options, Tavern.Chat.QuestionOption, preload_order: [asc: :position])
    has_many(:answers, Tavern.Chat.QuestionAnswer, preload_order: [asc: :inserted_at])

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The question kinds."
  def kinds, do: @kinds

  @doc "Whether the question is a bot's prompt (an ask or a permission request), not a poll."
  def prompt?(%__MODULE__{kind: kind}), do: kind in [:ask, :permission]

  @doc "Whether the question takes no more answers at `now`: closed by hand or by its answer limit, or past its end time."
  def closed?(%__MODULE__{closed_at: closed_at, closes_at: closes_at}, now \\ DateTime.utc_now()),
    do:
      not is_nil(closed_at) or
        (not is_nil(closes_at) and DateTime.compare(closes_at, now) != :gt)

  @doc "Whether the question narrows who may answer to named members or roles."
  def narrowed?(%__MODULE__{answerer_user_ids: user_ids, answerer_role_ids: role_ids}),
    do: user_ids != [] or role_ids != []

  @doc """
  Whether a member with `user_id` and `role_ids` is on the question's answerer list. A question
  that names no member and no role lists everyone; the channel's own send rule still applies on
  top.
  """
  def listed_answerer?(%__MODULE__{} = question, user_id, role_ids) do
    not narrowed?(question) or user_id in question.answerer_user_ids or
      Enum.any?(role_ids, &(&1 in question.answerer_role_ids))
  end
end
