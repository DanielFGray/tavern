defmodule Tavern.Chat.Invites do
  @moduledoc """
  Invite links for joining the server.

  An invite carries a code, an optional use cap and expiry, and the channel a new member
  starts in. `redeem/2` runs inside the registration transaction: it takes the invite's row
  lock, re-checks revocation, expiry and the use cap from the locked row, and records the
  use, so two concurrent registrations of the last seat cannot both pass.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Invite
  alias Tavern.Chat.InviteRequest
  alias Tavern.Chat.InviteUse
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.ProductEvents
  alias Tavern.Repo

  # A URL-safe alphabet without the pairs that read alike on paper (0/O, 1/l/I).
  @code_alphabet ~c(abcdefghjkmnpqrstuvwxyz23456789)
  @code_length 8

  @doc "An empty changeset for the create form, so the form renders without live errors."
  def new_invite_changeset, do: Ecto.Changeset.change(%Invite{})

  @doc """
  Creates an invite from attrs. Needs `manage_server` now, in the database: `{:error,
  :forbidden}` without it. A blank or missing `code` gets a random one; `channel_id` is required.
  """
  def create_invite(%Scope{} = scope, attrs) when is_map(attrs) do
    Repo.transact(fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_server, :server),
           {:ok, invite} <-
             %Invite{inviter_id: scope.user_id}
             |> Invite.changeset(with_generated_code(attrs))
             |> Repo.insert() do
        {:ok, Repo.preload(invite, [:channel, :inviter])}
      end
    end)
    |> tap(fn
      {:ok, invite} -> ProductEvents.record({:invite_created, invite})
      {:error, _reason} -> :ok
    end)
  end

  @doc """
  Inserts a one-use invite with a random code, expiring `expires_at`, inside the caller's
  transaction. The caller has already authorised the write: an approved invite request uses
  this under `manage_applications`, not `manage_server`. The new member starts in `#general`,
  or else the first text channel.
  """
  def insert_single_use!(inviter_id, %DateTime{} = expires_at) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "insert_single_use!/2 must run inside a transaction"
    end

    %Invite{inviter_id: inviter_id}
    |> Invite.changeset(%{
      code: generate_code(),
      channel_id: starting_channel_id(),
      max_uses: 1,
      expires_at: expires_at
    })
    |> Repo.insert!()
  end

  defp starting_channel_id do
    from(channel in Channel,
      where: channel.kind == :text and is_nil(channel.archived_at) and is_nil(channel.deleted_at),
      order_by: [desc: channel.slug == "general", asc: channel.position, asc: channel.inserted_at],
      limit: 1,
      select: channel.id
    )
    |> Repo.one()
  end

  defp with_generated_code(attrs) do
    case normalize_code(attrs) do
      nil -> Map.put(attrs, "code", generate_code())
      code -> Map.put(attrs, "code", code)
    end
  end

  defp normalize_code(attrs) do
    attrs
    |> Map.take(["code", :code])
    |> Map.values()
    |> Enum.map(&(&1 && String.trim(to_string(&1))))
    |> Enum.find(&(&1 not in [nil, ""]))
  end

  def generate_code do
    1..@code_length
    |> Enum.map(fn _ -> Enum.random(@code_alphabet) end)
    |> List.to_string()
  end

  @doc """
  The active invites of the server, newest first. Needs `manage_server`.
  """
  def list_invites(%Scope{} = scope) do
    if Visibility.can?(scope, :manage_server, :server) do
      Invite
      |> order_by(desc: :inserted_at)
      |> Repo.all()
      |> Repo.preload([:channel, :inviter])
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Revokes an invite by id. Needs `manage_server`. Returns the revoked invite, or
  `{:error, :not_found}` when the id names no invite.
  """
  def revoke_invite(%Scope{} = scope, invite_id) do
    Repo.transact(fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_server, :server),
           {:ok, invite} <- lock_invite(invite_id) do
        invite
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Repo.update()
      end
    end)
  end

  defp lock_invite(invite_id) do
    with {:ok, invite_id} <- Ecto.UUID.cast(invite_id),
         %Invite{} = invite <-
           Invite |> where(id: ^invite_id) |> lock("FOR UPDATE") |> Repo.one() do
      {:ok, invite}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Redeems `code` for `user` inside the caller's transaction. The caller must already hold
  a transaction: registration checks the code and creates the user as one decision.

  Returns `{:ok, invite}`, or `{:error, :invalid_invite}` for an unknown, revoked, expired,
  exhausted or already-used code. The caller rolls back on the error.
  """
  def redeem(code, %User{} = user) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "redeem/2 must run inside a transaction"
    end

    now = DateTime.utc_now()

    invite =
      Invite
      |> where(
        [invite],
        invite.code == ^normalize_code(%{"code" => code}) and is_nil(invite.revoked_at)
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    with %Invite{} = invite <- invite,
         true <- unexpired?(invite, now),
         true <- under_use_cap?(invite),
         false <- used_by?(invite, user.id),
         {:ok, _} <-
           invite
           |> Ecto.Changeset.change(uses: invite.uses + 1, last_used_at: now)
           |> Repo.update(),
         {:ok, _} <-
           %InviteUse{}
           |> InviteUse.changeset(%{invite_id: invite.id, user_id: user.id, used_at: now})
           |> Repo.insert() do
      {:ok, invite}
    else
      {:error, %Changeset{} = changeset} -> {:error, changeset}
      _unusable -> {:error, :invalid_invite}
    end
  end

  @doc """
  Whether `invite` was mailed to `email`: it is bound to an approved invite request for that
  address (the column is case-insensitive). An invite made by hand is mailed nowhere.
  """
  def mailed_to?(%Invite{id: invite_id}, email) when is_binary(email) do
    Repo.exists?(
      from request in InviteRequest,
        where:
          request.invite_id == ^invite_id and request.status == :approved and
            request.email == ^email
    )
  end

  defp unexpired?(%Invite{expires_at: nil}, _now), do: true
  defp unexpired?(%Invite{expires_at: expires_at}, now), do: not DateTime.before?(expires_at, now)

  defp under_use_cap?(%Invite{max_uses: nil}), do: true
  defp under_use_cap?(%Invite{max_uses: max_uses, uses: uses}), do: uses < max_uses

  defp used_by?(invite, user_id) do
    Repo.exists?(
      from invite_use in InviteUse,
        where: invite_use.invite_id == ^invite.id and invite_use.user_id == ^user_id
    )
  end
end
