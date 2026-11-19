defmodule Tavern.Repo.Migrations.AddInviteTreeIndexes do
  @moduledoc """
  The invite tree reads each member's earliest invite use (`invite_uses` by member, oldest
  first) and each inviter's invites. `invite_uses(user_id)` is replaced by the two-column index,
  which serves the same lookups.
  """
  use Ecto.Migration

  def change do
    drop_if_exists(index(:invite_uses, [:user_id]))
    create(index(:invite_uses, [:user_id, :used_at]))
    create(index(:invites, [:inviter_id]))
  end
end
