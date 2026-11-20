defmodule Tavern.Chat.Channels do
  @moduledoc """
  Channel and category management: create, edit, place, soft delete and restore
  (docs/design/channel-management.md). Every write decides `:manage_channels` (or
  `:restore_channel`) through `Tavern.Chat.Visibility` in its own transaction, under the
  channel-tree lock.
  """

  import Ecto.Query, warn: false

  alias Tavern.Chat.AuditLog
  alias Tavern.Chat.Channel
  alias Tavern.Accounts.Scope
  alias Tavern.Chat.ChannelMembership
  alias Tavern.Chat.Ids
  alias Tavern.Chat.Message
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  # Key of the transaction-scoped advisory lock that serializes channel management writes.
  @channel_tree_lock_key 7_314_002_002

  @thread_kinds [:thread_public, :thread_private, :thread_announcement]

  def list_channels(%Scope{} = scope) do
    Visibility.visible_channels(scope)
  end

  def list_channel_tree(%Scope{} = scope) do
    scope
    |> Visibility.visible_channels()
    |> build_channel_tree()
  end

  @doc """
  The sidebar's sections: one per category in category order, then the channels at the top
  level when there are any. Threads are left out.
  """
  def build_channel_tree(channels) when is_list(channels) do
    categories = Enum.filter(channels, &(&1.kind == :category))
    category_ids = MapSet.new(Enum.map(categories, & &1.id))

    uncategorized =
      Enum.filter(
        channels,
        &(visible_text_channel?(&1) and root_level_channel?(&1, category_ids))
      )

    categorized_sections =
      Enum.map(categories, fn category ->
        %{
          category: category,
          channels:
            channels
            |> Enum.filter(&(&1.parent_channel_id == category.id and visible_text_channel?(&1)))
            |> sort_channels()
        }
      end)

    categorized_sections ++
      if uncategorized == [] do
        []
      else
        [%{category: nil, channels: sort_channels(uncategorized)}]
      end
  end

  def ensure_channel_memberships(%Scope{} = scope, channels) when is_list(channels) do
    # These rows store read state only; they do not grant channel access.
    user_id = scope.user_id
    channels = Enum.reject(channels, &(&1.kind == :category))
    channel_ids = Enum.map(channels, & &1.id)

    existing_channel_ids =
      ChannelMembership
      |> where(
        [membership],
        membership.user_id == ^user_id and membership.channel_id in ^channel_ids
      )
      |> select([membership], membership.channel_id)
      |> Repo.all()
      |> MapSet.new()

    missing_channels = Enum.reject(channels, &MapSet.member?(existing_channel_ids, &1.id))

    latest_messages =
      missing_channels
      |> Enum.map(& &1.id)
      |> latest_messages_by_channel()

    now = DateTime.utc_now()

    missing_channels
    |> Enum.each(fn channel ->
      latest_message =
        case Map.get(latest_messages, channel.id) do
          %Message{author_id: author_id} = message when author_id == user_id -> message
          _ -> nil
        end

      %ChannelMembership{channel_id: channel.id, user_id: user_id}
      |> ChannelMembership.changeset(%{
        joined_at: now,
        last_read_message_id: latest_message && latest_message.id,
        last_read_at: latest_message && latest_message.inserted_at
      })
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:channel_id, :user_id])
    end)

    :ok
  end

  def get_channel(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, channel_id} -> Visibility.visible_channel(scope, channel_id)
      :error -> nil
    end
  end

  def get_channel_by_slug(%Scope{} = scope, slug) do
    channel =
      Repo.one(
        from(channel in Channel, where: channel.slug == ^slug and is_nil(channel.deleted_at))
      )

    if channel, do: get_channel(scope, channel.id), else: nil
  end

  @doc """
  Creates a channel or category (kinds in `Channel.managed_kinds/0`) at the end of its category,
  or of the top level. The slug comes from the name, with `-2`, `-3`, ... when a live channel
  holds it. Attrs that carry a slug or position (provisioning and fixtures) keep them.
  """
  def create_channel(%Scope{} = scope, attrs) do
    write_channel(scope, :manage_channels, :server, :channel_created, fn _ ->
      with {:ok, parent} <- authorize_parent(scope, attr(attrs, :parent_channel_id)) do
        parent_id = parent && parent.id

        %Channel{
          slug: free_slug(Channel.slugify(attr(attrs, :name))),
          position: next_position(parent_id)
        }
        |> Channel.changeset(attrs)
        |> require_category_parent(parent)
        |> Repo.insert()
      end
    end)
  end

  @doc "Edits a channel's name, topic, age gate, slowmode or auto-archive. The slug stays."
  def update_channel(%Scope{} = scope, channel_id, attrs) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id) do
      write_channel(scope, :manage_channels, channel_id, :channel_updated, fn channel ->
        channel |> Channel.settings_changeset(attrs) |> Repo.update()
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Places a channel under `parent_id` (a category, or nil for the top level), just before the
  sibling `before_id`, or last when `before_id` is nil. A category is placed only at the top
  level. The siblings are renumbered in the same transaction, including rows the scope cannot
  see, so their order relative to each other does not change.
  """
  def place_channel(%Scope{} = scope, channel_id, parent_id, before_id) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id),
         {:ok, parent_id} <- cast_optional(parent_id),
         {:ok, before_id} <- cast_optional(before_id) do
      scope
      |> channel_transaction(:manage_channels, channel_id, fn channel ->
        with :ok <- placeable(channel, parent_id),
             {:ok, parent} <- authorize_parent(scope, parent_id),
             :ok <- placeable_under(channel, parent),
             {:ok, order} <- sibling_order(channel, parent, before_id) do
          renumber(order, channel, parent)
        end
      end)
      |> tap(&broadcast_reorder/1)
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Soft-deletes a channel or category: it sets `deleted_at`, and `Visibility` then hides the
  channel, its threads and their messages from everyone. A category's channels move to the end
  of the top level and stay. A thread is refused here: `delete_thread/2` deletes it.
  """
  def delete_channel(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id) do
      write_channel(scope, :manage_channels, channel_id, :channel_deleted, fn channel ->
        cond do
          Channel.thread?(channel) ->
            {:error, :thread}

          channel.kind == :category ->
            move_children_to_top_level(channel)
            soft_delete(channel)

          true ->
            soft_delete(channel)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Soft-deletes a thread or forum post, with its messages, and records it in the audit log. A
  member with `manage_messages` in its parent channel may; deleting the starter message does not.
  A deleted thread is not restorable. Refusals: `{:error, :not_found}` for a thread the scope
  cannot view, `{:error, :forbidden}` otherwise. Broadcasts `{:channel_deleted, thread}` on the
  server topic.
  """
  def delete_thread(%Scope{} = scope, thread_id) do
    with {:ok, thread_id} <- Ecto.UUID.cast(thread_id) do
      write_channel(scope, :delete_thread, thread_id, :channel_deleted, fn thread ->
        with {:ok, thread} <- soft_delete(thread) do
          AuditLog.record!(scope.user_id, "thread_deleted", nil, {"channel", thread.id},
            metadata: %{
              "channel_name" => thread |> Repo.preload(:starter_message) |> Channel.title(),
              "parent_channel_id" => thread.parent_channel_id
            }
          )

          {:ok, thread}
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  @doc "The deleted channels and categories the scope may restore, most recently deleted first."
  def list_deleted_channels(%Scope{} = scope), do: Visibility.restorable_channels(scope)

  @doc """
  Restores a deleted channel or category at the end of its category, or of the top level when
  it has none. When a live channel took its slug meanwhile, it gets the next free one.
  """
  def restore_channel(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id) do
      write_channel(scope, :restore_channel, channel_id, :channel_updated, fn channel ->
        parent_id = live_category_id(channel.parent_channel_id)

        channel
        |> Ecto.Changeset.change(
          deleted_at: nil,
          parent_channel_id: parent_id,
          position: next_position(parent_id),
          slug: free_slug(channel.slug)
        )
        |> Repo.update()
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Takes the channel-tree lock exclusively. Every channel management write takes it first, and an
  overwrite write (`Tavern.Chat.ChannelOverwrites`) takes it after the role-list lock. Must run
  inside the write transaction.
  """
  def lock_channel_tree! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@channel_tree_lock_key])
    :ok
  end

  def lock_channel(id) do
    Repo.one(from(channel in Channel, where: channel.id == ^id, lock: "FOR UPDATE"))
  end

  # --- Transactions ------------------------------------------------------------------------------

  # Open ServerLive sidebars reload their channel order after the move commits.
  defp broadcast_reorder({:ok, _channel}), do: Topics.broadcast_server(:channels_reordered)
  defp broadcast_reorder(_error), do: :ok

  defp write_channel(scope, action, target, event, change) do
    case channel_transaction(scope, action, target, change) do
      {:ok, channel} = result ->
        Topics.broadcast_server({event, channel})
        result

      error ->
        error
    end
  end

  # Every channel management write runs here. The tree lock comes first, so two management writes
  # never interleave: the second one decides from the tree the first one committed, and no two of
  # them wait on each other's channel rows. Then the decision takes its membership locks, then the
  # target row is locked (`:server` has none) and `change` runs on it.
  defp channel_transaction(scope, action, target, change) do
    Repo.transact(fn ->
      lock_channel_tree!()

      with :ok <- Visibility.authorize_write(scope, action, authorization_target(target)),
           {:ok, channel} <- lock_target(target) do
        change.(channel)
      end
    end)
  end

  defp authorization_target(:server), do: :server
  defp authorization_target(channel_id), do: %Channel{id: channel_id}

  defp lock_target(:server), do: {:ok, nil}

  defp lock_target(channel_id) do
    case lock_channel(channel_id) do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, :not_found}
    end
  end

  # The scoped decision answers first, so a hidden parent and a missing one give the same refusal.
  # The kind is checked on the row the decision locked, and only for a parent that is set.
  defp authorize_parent(_scope, parent_id) when parent_id in [nil, ""], do: {:ok, nil}

  defp authorize_parent(scope, parent_id) do
    with {:ok, parent_id} <- Ids.cast(parent_id),
         :ok <- Visibility.authorize_write(scope, :manage_channels, %Channel{id: parent_id}),
         %Channel{} = parent <- lock_channel(parent_id) do
      {:ok, parent}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # A manager places a channel only under a category. Any other parent would make the channel a
  # child of a channel, whose visibility rules are a thread's.
  defp require_category_parent(changeset, %Channel{kind: :category}), do: changeset
  defp require_category_parent(changeset, nil), do: changeset

  defp require_category_parent(changeset, %Channel{}),
    do: Ecto.Changeset.add_error(changeset, :parent_channel_id, "must be a category")

  # --- Placing -----------------------------------------------------------------------------------

  defp placeable(%Channel{kind: kind}, _parent_id) when kind in @thread_kinds,
    do: {:error, :thread}

  defp placeable(%Channel{kind: :category}, parent_id) when not is_nil(parent_id),
    do: {:error, :invalid_parent}

  defp placeable(_channel, _parent_id), do: :ok

  defp placeable_under(_channel, nil), do: :ok
  defp placeable_under(_channel, %Channel{kind: :category}), do: :ok
  defp placeable_under(_channel, _parent), do: {:error, :invalid_parent}

  # The siblings in their new order, with the channel inserted before `before_id`. An anchor that
  # is not a sibling (moved or deleted meanwhile) refuses the move: the mover's sidebar reloads.
  defp sibling_order(channel, parent, before_id) do
    siblings =
      from(sibling in Channel,
        where: sibling.id != ^channel.id and sibling.kind not in ^@thread_kinds,
        order_by: [asc: sibling.position, asc: sibling.inserted_at]
      )
      |> under_parent(parent && parent.id)
      |> Repo.all()

    case before_id do
      nil ->
        {:ok, siblings ++ [channel]}

      before_id ->
        case Enum.find_index(siblings, &(&1.id == before_id)) do
          nil -> {:error, :not_found}
          index -> {:ok, List.insert_at(siblings, index, channel)}
        end
    end
  end

  defp renumber(order, channel, parent) do
    parent_id = parent && parent.id

    order
    |> Enum.with_index()
    |> Enum.each(fn {row, position} ->
      cond do
        row.id == channel.id ->
          set_place(row.id, parent_id, position)

        row.position != position ->
          set_place(row.id, row.parent_channel_id, position)

        true ->
          :ok
      end
    end)

    {:ok, Repo.get!(Channel, channel.id)}
  end

  defp set_place(id, parent_id, position) do
    from(channel in Channel, where: channel.id == ^id)
    |> Repo.update_all(
      set: [parent_channel_id: parent_id, position: position, updated_at: DateTime.utc_now()]
    )
  end

  # Every child moves, deleted ones too, so a restored child finds its category gone and lands
  # at the top level.
  defp move_children_to_top_level(category) do
    start = next_position(nil)

    from(child in Channel,
      where: child.parent_channel_id == ^category.id,
      order_by: [asc: child.position, asc: child.inserted_at]
    )
    |> Repo.all()
    |> Enum.with_index(start)
    |> Enum.each(fn {child, position} -> set_place(child.id, nil, position) end)
  end

  defp soft_delete(channel) do
    channel
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp live_category_id(nil), do: nil

  defp live_category_id(parent_id) do
    Repo.one(
      from(category in Channel,
        where:
          category.id == ^parent_id and category.kind == :category and
            is_nil(category.deleted_at),
        select: category.id
      )
    )
  end

  defp next_position(parent_id) do
    from(channel in Channel,
      where: channel.kind not in ^@thread_kinds,
      select: max(channel.position)
    )
    |> under_parent(parent_id)
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end

  defp under_parent(query, nil), do: where(query, [channel], is_nil(channel.parent_channel_id))

  defp under_parent(query, parent_id),
    do: where(query, [channel], channel.parent_channel_id == ^parent_id)

  # The first of `base`, `base-2`, `base-3`, ... that no live channel holds. It runs under the
  # channel-tree lock, so no other management write takes the slug before this one commits.
  # Thread slugs are `thread-<uuid>` and never collide with it.
  defp free_slug(base) do
    taken =
      from(channel in Channel,
        where:
          is_nil(channel.deleted_at) and
            (channel.slug == ^base or like(channel.slug, ^"#{base}-%")),
        select: channel.slug
      )
      |> Repo.all()
      |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  # --- Helpers -----------------------------------------------------------------------------------

  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, to_string(key)))

  defp cast_optional(nil), do: {:ok, nil}
  defp cast_optional(""), do: {:ok, nil}
  defp cast_optional(id), do: Ecto.UUID.cast(id)

  defp latest_messages_by_channel([]), do: %{}

  defp latest_messages_by_channel(channel_ids) do
    from(message in Message,
      where: message.channel_id in ^channel_ids and is_nil(message.deleted_at),
      distinct: message.channel_id,
      order_by: [asc: message.channel_id, desc: message.inserted_at, desc: message.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.channel_id, &1})
  end

  defp sort_channels(channels) do
    Enum.sort_by(channels, &{&1.position, &1.inserted_at})
  end

  defp root_level_channel?(channel, category_ids) do
    is_nil(channel.parent_channel_id) or
      not MapSet.member?(category_ids, channel.parent_channel_id)
  end

  defp visible_text_channel?(channel) do
    channel.kind != :category and not Channel.thread?(channel)
  end
end
