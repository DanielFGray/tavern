defmodule Tavern.Chat.PollBallot do
  @moduledoc """
  One member's current vote in a poll: the options they chose and, when they chose "Other", its
  text. A member has at most one ballot per poll; changing the vote replaces it and withdrawing
  deletes it, so the number of ballots is the number of voters.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "poll_ballots" do
    field(:option_ids, {:array, :binary_id}, default: [])
    field(:other_text, :string)

    belongs_to(:poll, Tavern.Chat.Poll)
    belongs_to(:user, Tavern.Chat.User)

    timestamps(type: :utc_datetime_usec)
  end
end
