defmodule Tavern.Chat.PollOption do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "poll_options" do
    field(:position, :integer)
    field(:label, :string)

    belongs_to(:poll, Tavern.Chat.Poll)
  end
end
