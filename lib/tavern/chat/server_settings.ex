defmodule Tavern.Chat.ServerSettings do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "server_settings" do
    field(:singleton, :boolean, default: true)
    field(:name, :string)
    field(:registration_mode, Ecto.Enum, values: [:open, :invite_only], default: :open)
    field(:accept_invite_requests, :boolean, default: false)

    belongs_to(:icon_asset, Tavern.Chat.MediaAsset)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(server_settings, attrs) do
    server_settings
    |> cast(attrs, [:name, :registration_mode, :accept_invite_requests])
    |> validate_required([:singleton, :name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_change(:accept_invite_requests, &mail_configured/2)
    |> unique_constraint(:singleton)
  end

  # An approved request is answered by mail, so requests cannot be accepted while no mail
  # provider is configured.
  defp mail_configured(:accept_invite_requests, true) do
    case Tavern.Mailer.missing_settings() do
      [] -> []
      missing -> [accept_invite_requests: "needs mail: set #{Enum.join(missing, ", ")}"]
    end
  end

  defp mail_configured(:accept_invite_requests, false), do: []
end
