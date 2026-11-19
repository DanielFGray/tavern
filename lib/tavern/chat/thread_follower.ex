defmodule Tavern.Chat.ThreadFollower do
  @moduledoc """
  One member's follow state for one thread. `unfollowed_at` set means the member unfollowed the
  thread by hand; the row stays, so a later post or mention does not follow them again.
  `source` names what last made them follow it.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "thread_followers" do
    field(:source, Ecto.Enum, values: [:created, :posted, :mentioned, :manual])
    field(:followed_at, :utc_datetime_usec)
    field(:unfollowed_at, :utc_datetime_usec)

    belongs_to(:thread, Tavern.Chat.Channel)
    belongs_to(:user, Tavern.Chat.User)
  end
end
