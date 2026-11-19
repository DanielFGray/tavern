defmodule Tavern.Chat.Poll do
  @moduledoc """
  A poll on a message (docs/design/polls.md). The message body is the question. A poll is open
  until `closed_at` is set or `closes_at` has passed; `closed?/2` is the one rule.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "polls" do
    field(:multi_select, :boolean, default: false)
    field(:anonymous, :boolean, default: false)
    field(:allow_other, :boolean, default: false)
    field(:closes_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)
    field(:max_voters, :integer)
    field(:voter_user_ids, {:array, :binary_id}, default: [])
    field(:voter_role_ids, {:array, :binary_id}, default: [])

    belongs_to(:message, Tavern.Chat.Message)
    has_many(:options, Tavern.Chat.PollOption, preload_order: [asc: :position])
    has_many(:ballots, Tavern.Chat.PollBallot, preload_order: [asc: :inserted_at])

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Whether the poll takes no more votes at `now`: closed by hand or by its vote limit, or past its end time."
  def closed?(%__MODULE__{closed_at: closed_at, closes_at: closes_at}, now \\ DateTime.utc_now()),
    do:
      not is_nil(closed_at) or
        (not is_nil(closes_at) and DateTime.compare(closes_at, now) != :gt)

  @doc "Whether the poll narrows its voters to named members or roles."
  def narrowed?(%__MODULE__{voter_user_ids: user_ids, voter_role_ids: role_ids}),
    do: user_ids != [] or role_ids != []

  @doc """
  Whether a member with `user_id` and `role_ids` is on the poll's voter list. A poll that names no
  member and no role lists everyone; the channel's own send rule still applies on top.
  """
  def listed_voter?(%__MODULE__{} = poll, user_id, role_ids) do
    not narrowed?(poll) or user_id in poll.voter_user_ids or
      Enum.any?(role_ids, &(&1 in poll.voter_role_ids))
  end
end
