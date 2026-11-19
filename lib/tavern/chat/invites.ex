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
  alias Tavern.Chat.Invite
  alias Tavern.Chat.InviteUse
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  # A URL-safe alphabet without the pairs that read alike on paper (0/O, 1/l/I).
  @code_alphabet ~c(abcdefghjkmnpqrstuvwxyz23456789)
  @code_length 8

  @doc "An empty changeset for the create form, so the form renders without live errors."
  def new_invite_changeset, do: Ecto.Changeset.change(%Invite{})

  @doc """
  Creates an invite from attrs, as `actor`. Needs `manage_server` now, in the database.
  A blank or missing `code` gets a random one; `channel_id` is required.
  """
  def create_invite(attrs, %User{} = actor) when is_map(attrs) do
    Repo.transaction(fn ->
      with :ok <-
             Visibility.authorize_write(%Scope{user_id: actor.id}, :manage_server, :server),
           {:ok, invite} <-
             %Invite{inviter_id: actor.id}
             |> Invite.changeset(with_generated_code(attrs))
             |> Repo.insert() do
        Repo.preload(invite, [:channel, :inviter])
      else
        {:error, %Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback({:refused, reason})
      end
    end)
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
  def list_invites(%User{} = actor) do
    if Visibility.can?(%Scope{user_id: actor.id}, :manage_server, :server) do
      Invite
      |> order_by(desc: :inserted_at)
      |> Repo.all()
      |> Repo.preload([:channel, :inviter])
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Revokes an invite by id, as `actor`. Needs `manage_server`. Returns the revoked invite,
  or `:not_found` when the id names no invite.
  """
  def revoke_invite(invite_id, %User{} = actor) do
    Repo.transaction(fn ->
      with :ok <-
             Visibility.authorize_write(%Scope{user_id: actor.id}, :manage_server, :server),
           invite <- Repo.get(Invite, invite_id) || Repo.rollback(:not_found),
           {:ok, invite} <-
             invite
             |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
             |> Repo.update() do
        invite
      else
        {:error, %Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback({:refused, reason})
      end
    end)
  end

  @doc """
  Redeems `code` for `user` inside the caller's transaction. The caller must already hold
  a transaction: registration checks the code and creates the user as one decision.

  Returns the redeemed invite, or rolls back with `{:refused, :invalid_invite}` for an
  unknown, revoked, expired, exhausted or already-used code.
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
         :ok <- check_expiry(invite, now),
         :ok <- check_use_cap(invite),
         :ok <- check_unused_by_user(invite, user.id),
         {:ok, _} <-
           invite
           |> Ecto.Changeset.change(uses: invite.uses + 1, last_used_at: now)
           |> Repo.update(),
         {:ok, _} <-
           %InviteUse{}
           |> InviteUse.changeset(%{invite_id: invite.id, user_id: user.id, used_at: now})
           |> Repo.insert() do
      invite
    else
      nil -> Repo.rollback({:refused, :invalid_invite})
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp check_expiry(%Invite{expires_at: nil}, _now), do: :ok

  defp check_expiry(%Invite{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :lt,
      do: Repo.rollback({:refused, :invalid_invite}),
      else: :ok
  end

  defp check_use_cap(%Invite{max_uses: nil}), do: :ok

  defp check_use_cap(%Invite{max_uses: max_uses, uses: uses}) when uses >= max_uses,
    do: Repo.rollback({:refused, :invalid_invite})

  defp check_use_cap(%Invite{}), do: :ok

  defp check_unused_by_user(invite, user_id) do
    query =
      from invite_use in InviteUse,
        where: invite_use.invite_id == ^invite.id and invite_use.user_id == ^user_id

    if Repo.exists?(query) do
      Repo.rollback({:refused, :invalid_invite})
    else
      :ok
    end
  end
end
