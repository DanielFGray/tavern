defmodule Tavern.Chat.PushSubscription do
  @moduledoc """
  One device's Web Push address: the push service URL its browser gave (`endpoint`) and the two
  keys the browser made, raw bytes (`p256dh`, 65 bytes; `auth`, 16 bytes). `session` is the
  browser session that made it: a push goes only while that session is live.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "push_subscriptions" do
    field(:endpoint, :string)
    field(:p256dh, :binary)
    field(:auth, :binary)

    belongs_to(:user, Tavern.Chat.User)
    belongs_to(:session, Tavern.Chat.UserSession)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset from the browser's `PushSubscription.toJSON()` fields, already decoded. The
  endpoint must be an https URL; where it resolves is checked when a push is sent
  (`Tavern.Embeds.SafeHTTP`).
  """
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth])
    |> validate_required([:endpoint, :p256dh, :auth])
    |> validate_length(:endpoint, max: 2048)
    |> validate_change(:endpoint, fn :endpoint, endpoint ->
      case URI.new(endpoint) do
        {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> []
        _ -> [endpoint: "must be an https URL"]
      end
    end)
    |> validate_change(:p256dh, fn :p256dh, key ->
      if match?(<<4, _::binary-64>>, key), do: [], else: [p256dh: "is not a P-256 public key"]
    end)
    |> validate_change(:auth, fn :auth, auth ->
      if byte_size(auth) == 16, do: [], else: [auth: "must be 16 bytes"]
    end)
    |> unique_constraint(:endpoint)
  end
end
