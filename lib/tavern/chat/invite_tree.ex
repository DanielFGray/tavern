defmodule Tavern.Chat.InviteTree do
  @moduledoc """
  Who invited whom, read from `invites.inviter_id` and `invite_uses`. No table of its own.

  A member's parent is the inviter of the invite they first used (earliest `invite_uses` row).
  A member with no use, or whose first invite lost its inviter, is a root. Later uses (a member
  who left and came back on a fresh invite) are listed on the node as `rejoins` and never move it.

  A node is a map with `:user` (avatar asset loaded), `:joined_at`, `:code`, `:inviter` (a user or
  nil), `:child_count`, `:status` (`:active`, `:kicked` or `:banned`, or nil for a viewer who does
  not moderate) and `:rejoins` (`%{code, inviter, used_at}`, oldest first).

  A scope with `view_audit_log` or `manage_server` sees every member. Any other active member sees
  their own inviter (one node, nothing above it and none of its other invitees), themselves, and
  everything below themselves. Anything else answers `{:error, :not_found}`, so the answer does
  not reveal who exists. A scope that is not an active member answers `{:error, :forbidden}`.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Ids
  alias Tavern.Chat.Invite
  alias Tavern.Chat.InviteUse
  alias Tavern.Chat.Membership
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @search_limit 20

  @doc """
  The direct invitees of `parent` (a user id), or the top level of the tree for `:roots`. One
  level per call. For a viewer who does not moderate, `:roots` is their inviter, or themselves
  when no one invited them.
  """
  def children(%Scope{} = scope, parent) do
    with {:ok, ctx} <- context(scope),
         {:ok, parent} <- visible_parent(ctx, parent) do
      {:ok, load_nodes(ctx, child_ids(ctx, parent))}
    end
  end

  @doc """
  The chain of user ids from the top of what the scope may see down to `user_id`, inclusive. A
  moderator's chain starts at a root; another member's starts at their inviter, or at themselves.
  """
  def path_to(%Scope{} = scope, user_id) do
    with {:ok, ctx} <- context(scope),
         {:ok, user_id} <- Ids.cast(user_id),
         chain = ancestor_chain(user_id),
         {:ok, chain} <- visible_chain(ctx, chain) do
      {:ok, chain}
    end
  end

  @doc """
  Members whose username or display name contains `query`, inside what the scope may see. At most
  #{@search_limit}, by username. A blank query matches nothing.
  """
  def search(%Scope{} = scope, query) when is_binary(query) do
    with {:ok, ctx} <- context(scope) do
      case String.trim(query) do
        "" -> {:ok, []}
        term -> {:ok, load_nodes(ctx, search_ids(ctx, term))}
      end
    end
  end

  # --- Who is asking ---------------------------------------------------------------------------

  defp context(%Scope{user_id: nil, bot_token_id: nil}), do: {:error, :forbidden}

  defp context(%Scope{} = scope) do
    case Visibility.member(scope) do
      nil ->
        {:error, :forbidden}

      %User{id: viewer_id} ->
        if Visibility.can?(scope, :view_audit_log, :server) or
             Visibility.can?(scope, :manage_server, :server) do
          {:ok, %{moderator?: true, viewer_id: viewer_id, inviter_id: nil}}
        else
          {:ok, %{moderator?: false, viewer_id: viewer_id, inviter_id: parent_of(viewer_id)}}
        end
    end
  end

  # A parent whose children the viewer may list. Another member's tree is reached only below
  # the viewer, plus the viewer's inviter, whose only visible child is the viewer.
  defp visible_parent(_ctx, :roots), do: {:ok, :roots}

  defp visible_parent(ctx, parent) do
    with {:ok, id} <- Ids.cast(parent) do
      cond do
        ctx.moderator? -> if member?(id), do: {:ok, id}, else: {:error, :not_found}
        id == ctx.viewer_id or id == ctx.inviter_id -> {:ok, id}
        ctx.viewer_id in ancestor_chain(id) -> {:ok, id}
        true -> {:error, :not_found}
      end
    end
  end

  defp visible_chain(%{moderator?: true}, chain) do
    if member?(List.last(chain)), do: {:ok, chain}, else: {:error, :not_found}
  end

  defp visible_chain(ctx, chain) do
    target = List.last(chain)

    cond do
      target == ctx.inviter_id ->
        {:ok, [target]}

      target == ctx.viewer_id ->
        {:ok, from_inviter(ctx, [target])}

      ctx.viewer_id in chain ->
        {:ok, from_inviter(ctx, Enum.drop_while(chain, &(&1 != ctx.viewer_id)))}

      true ->
        {:error, :not_found}
    end
  end

  defp from_inviter(%{inviter_id: nil}, chain), do: chain
  defp from_inviter(%{inviter_id: inviter_id}, chain), do: [inviter_id | chain]

  # --- Reading the tree ------------------------------------------------------------------------

  # Each member's earliest invite use. Ties on `used_at` break on the use's id, so two reads
  # agree on the parent.
  defp first_uses do
    from(invite_use in InviteUse,
      join: invite in Invite,
      on: invite.id == invite_use.invite_id,
      distinct: invite_use.user_id,
      order_by: [asc: invite_use.user_id, asc: invite_use.used_at, asc: invite_use.id],
      select: %{
        user_id: invite_use.user_id,
        parent_id: invite.inviter_id,
        code: invite.code,
        used_at: invite_use.used_at
      }
    )
  end

  # Members who can appear in the tree: an account with a membership row, not a bot, the system
  # account or a deleted account.
  defp members do
    from(user in User,
      join: membership in Membership,
      on: membership.user_id == user.id,
      where: not user.bot and not user.system and is_nil(user.deleted_at)
    )
  end

  defp member?(id) do
    Repo.exists?(from(user in members(), where: user.id == ^id))
  end

  defp parent_of(user_id) do
    Repo.one(
      from(first in subquery(first_uses()),
        where: first.user_id == ^user_id,
        select: first.parent_id
      )
    )
  end

  defp child_ids(%{moderator?: true}, :roots) do
    from(user in members(),
      left_join: first in subquery(first_uses()),
      on: first.user_id == user.id,
      where: is_nil(first.user_id) or is_nil(first.parent_id),
      order_by: [asc: user.inserted_at, asc: user.id],
      select: user.id
    )
    |> Repo.all()
  end

  defp child_ids(%{inviter_id: nil, viewer_id: viewer_id}, :roots), do: [viewer_id]
  defp child_ids(%{inviter_id: inviter_id}, :roots), do: [inviter_id]

  defp child_ids(%{moderator?: false, viewer_id: viewer_id, inviter_id: inviter_id}, parent)
       when parent == inviter_id and parent != viewer_id,
       do: [viewer_id]

  defp child_ids(_ctx, parent) do
    from(user in members(),
      join: first in subquery(first_uses()),
      on: first.user_id == user.id,
      where: first.parent_id == ^parent,
      order_by: [asc: first.used_at, asc: user.id],
      select: user.id
    )
    |> Repo.all()
  end

  defp search_ids(ctx, term) do
    pattern = "%" <> escape_like(term) <> "%"

    query =
      from(user in members(),
        where: ilike(user.username, ^pattern) or ilike(user.display_name, ^pattern),
        order_by: [asc: user.username, asc: user.id],
        limit: ^@search_limit,
        select: user.id
      )

    if ctx.moderator? do
      Repo.all(query)
    else
      visible = visible_ids(ctx)
      Repo.all(from(user in query, where: user.id in ^visible))
    end
  end

  defp visible_ids(ctx) do
    [ctx.inviter_id | [ctx.viewer_id | descendant_ids(ctx.viewer_id)]] |> Enum.reject(&is_nil/1)
  end

  # --- Recursive queries -----------------------------------------------------------------------
  #
  # The edges are each member's parent from `first_uses`. `UNION` (not `UNION ALL`) drops repeated
  # rows, so a loop in the data ends the walk instead of running forever.

  # `[root, ..., user_id]`. A user with no parent is their own chain.
  defp ancestor_chain(user_id) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        WITH RECURSIVE edges AS (
          SELECT DISTINCT ON (invite_use.user_id) invite_use.user_id, invite.inviter_id AS parent_id
          FROM invite_uses invite_use JOIN invites invite ON invite.id = invite_use.invite_id
          ORDER BY invite_use.user_id, invite_use.used_at, invite_use.id
        ), up(user_id, parent_id) AS (
          SELECT user_id, parent_id FROM edges WHERE user_id = $1
          UNION
          SELECT edge.user_id, edge.parent_id FROM edges edge JOIN up ON edge.user_id = up.parent_id
        )
        SELECT user_id::text, parent_id::text FROM up
        """,
        [Ecto.UUID.dump!(user_id)]
      )

    parents = Map.new(rows, fn [child, parent] -> {child, parent} end)
    walk_up(user_id, parents, [user_id])
  end

  defp walk_up(id, parents, chain) do
    case Map.get(parents, id) do
      nil -> chain
      parent -> if parent in chain, do: chain, else: walk_up(parent, parents, [parent | chain])
    end
  end

  defp descendant_ids(user_id) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        WITH RECURSIVE edges AS (
          SELECT DISTINCT ON (invite_use.user_id) invite_use.user_id, invite.inviter_id AS parent_id
          FROM invite_uses invite_use JOIN invites invite ON invite.id = invite_use.invite_id
          ORDER BY invite_use.user_id, invite_use.used_at, invite_use.id
        ), down(user_id) AS (
          SELECT user_id FROM edges WHERE parent_id = $1
          UNION
          SELECT edge.user_id FROM edges edge JOIN down ON edge.parent_id = down.user_id
        )
        SELECT user_id::text FROM down
        """,
        [Ecto.UUID.dump!(user_id)]
      )

    List.flatten(rows)
  end

  # --- Building nodes --------------------------------------------------------------------------

  # Nodes for `ids`, in the order given.
  defp load_nodes(_ctx, []), do: []

  defp load_nodes(ctx, ids) do
    rows =
      from([user, membership] in members(),
        left_join: first in subquery(first_uses()),
        on: first.user_id == user.id,
        left_join: inviter in User,
        on: inviter.id == first.parent_id,
        where: user.id in ^ids,
        select: {user, first, inviter, membership}
      )
      |> Repo.all()
      |> Map.new(fn {user, first, inviter, membership} ->
        {user.id, {user, first, inviter, membership}}
      end)

    counts = child_counts(ids)
    rejoins = rejoins(ctx, ids)

    for id <- ids, {user, first, inviter, membership} = rows[id] do
      node(ctx, user, first, inviter, membership, counts, rejoins)
    end
  end

  defp node(ctx, user, first, inviter, membership, counts, rejoins) do
    # The viewer's inviter is the top of their view: what is above it, and what brought it in,
    # stays hidden.
    top? = not ctx.moderator? and user.id == ctx.inviter_id and user.id != ctx.viewer_id

    %{
      user: Repo.preload(user, :avatar_asset),
      joined_at: first && first.used_at,
      code: if(top?, do: nil, else: first && first.code),
      inviter: if(top?, do: nil, else: inviter),
      child_count: if(top?, do: 1, else: Map.get(counts, user.id, 0)),
      status: if(ctx.moderator?, do: status(membership)),
      rejoins: Map.get(rejoins, user.id, [])
    }
  end

  defp status(%Membership{deactivated_at: nil}), do: :active
  defp status(%Membership{flags: %{"banned" => true}}), do: :banned
  defp status(%Membership{}), do: :kicked

  defp child_counts(ids) do
    from(first in subquery(first_uses()),
      join: user in subquery(members()),
      on: user.id == first.user_id,
      where: first.parent_id in ^ids,
      group_by: first.parent_id,
      select: {first.parent_id, count(first.user_id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Uses after each member's first. Another member's invite may come from outside the viewer's
  # branch, so only a moderator sees who issued it.
  defp rejoins(ctx, ids) do
    from(invite_use in InviteUse,
      join: invite in Invite,
      on: invite.id == invite_use.invite_id,
      left_join: inviter in User,
      on: inviter.id == invite.inviter_id,
      where: invite_use.user_id in ^ids,
      order_by: [asc: invite_use.user_id, asc: invite_use.used_at, asc: invite_use.id],
      select:
        {invite_use.user_id, %{code: invite.code, inviter: inviter, used_at: invite_use.used_at}}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {user_id, [_first | later]} ->
      {user_id, Enum.map(later, &if(ctx.moderator?, do: &1, else: %{&1 | inviter: nil}))}
    end)
  end

  defp escape_like(term), do: String.replace(term, ~r/([\\%_])/, "\\\\\\1")
end
