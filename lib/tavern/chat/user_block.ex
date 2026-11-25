defmodule Tavern.Chat.UserBlock do
  @moduledoc """
  One account's block of another. A block refuses direct messages between the two, both ways,
  and collapses the blocked account's messages in the blocker's view of channels
  (docs/design/direct-messages.md).
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "user_blocks" do
    belongs_to(:blocker, Tavern.Chat.User, primary_key: true)
    belongs_to(:blocked, Tavern.Chat.User, primary_key: true)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end
end
