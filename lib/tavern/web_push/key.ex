defmodule Tavern.WebPush.Key do
  @moduledoc "The server's VAPID key pair, raw P-256 bytes, and the server URL it was made for."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  schema "push_keys" do
    field(:origin, :string)
    field(:public_key, :binary)
    field(:private_key, :binary, redact: true)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
