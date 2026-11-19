defmodule Tavern.Chat.InviteRequest do
  @moduledoc """
  A request to join an invite-only server, made with only an email address. A moderator
  approves it (which binds a one-use invite and mails its link) or denies it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "invite_requests" do
    field(:email, :string)
    field(:ip_address, :string)
    field(:status, Ecto.Enum, values: [:pending, :approved, :denied], default: :pending)
    field(:requested_at, :utc_datetime_usec)
    field(:decided_at, :utc_datetime_usec)
    field(:delivered_at, :utc_datetime_usec)
    field(:delivery_error, :string)
    field(:ip_request_count, :integer, virtual: true)

    belongs_to(:decided_by, Tavern.Chat.User)
    belongs_to(:invite, Tavern.Chat.Invite)
  end

  @doc "Validates the applicant's address. `ip_address` and `requested_at` are set by the caller."
  def request_changeset(request, attrs) do
    request
    |> cast(attrs, [:email])
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "must be an email address")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email, name: :invite_requests_pending_email_index)
  end
end
