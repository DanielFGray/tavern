defmodule Tavern.Chat.DirectMessages do
  @moduledoc """
  Direct messages between two accounts, and blocks (docs/design/direct-messages.md).

  A DM is a channel row of kind `:direct` that names its two participants. Messages, reactions,
  read state, search and message links work on it as on any channel; `Tavern.Chat.Visibility`
  decides every action in it from participation, never from permission bits.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Ids
  alias Tavern.Chat.Message
  alias Tavern.Chat.Topics
  alias Tavern.Chat.User
  alias Tavern.Chat.UserBlock
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @doc """
  The direct message between the scope and member `user_id`, with `peer` set. Returns the
  existing DM of the pair, or starts one when `Visibility` allows `:start_direct_message`. A new
  DM is announced on both participants' user topics as `{:direct_message_opened, channel}`.

  Every refusal is `{:error, :not_available}`: an unknown id, a blocked pair and a member who
  turned off new contacts look the same, so a probe learns nothing about the target.
  """
  def open_direct_message(%Scope{} = scope, user_id) do
    with {:ok, user_id} <- Ids.cast(user_id),
         nil <- visible_pair(scope, user_id) do
      start(scope, user_id)
    else
      %Channel{} = channel -> {:ok, channel}
      _ -> {:error, :not_available}
    end
  end

  @doc """
  The scope's direct messages, with `peer` set, most recent activity first. A DM shows once it
  holds a message, or for the participant who started it.
  """
  def list_direct_messages(%Scope{} = scope) do
    case Visibility.member(scope) do
      nil ->
        []

      %User{id: user_id} ->
        from(channel in participant_channels(user_id),
          left_join: message in Message,
          on: message.channel_id == channel.id,
          where: not is_nil(message.id) or channel.created_by_id == ^user_id,
          group_by: channel.id,
          order_by: [
            desc: coalesce(max(message.inserted_at), channel.inserted_at),
            desc: channel.id
          ]
        )
        |> Repo.all()
        |> with_peers(user_id)
    end
  end

  @doc "The direct message `channel_id`, with `peer` set, when the scope is a participant, or nil."
  def get_direct_message(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ids.cast(channel_id),
         %Channel{kind: :direct} = channel <- Visibility.visible_channel(scope, channel_id),
         %User{id: me} <- Visibility.member(scope) do
      channel |> List.wrap() |> with_peers(me) |> hd()
    else
      _ -> nil
    end
  end

  @doc "Ids of the scope's direct messages, listed or not: the conversations it may read."
  def direct_message_ids(%Scope{} = scope) do
    case Visibility.member(scope) do
      nil ->
        []

      %User{id: user_id} ->
        Repo.all(from(channel in participant_channels(user_id), select: channel.id))
    end
  end

  @doc """
  Blocks `user_id` for the scope's account. The block refuses direct messages between the two
  both ways and collapses the blocked account's messages for the blocker. Blocking twice is
  `:ok`. A block is sent to the blocker's user topic as `:blocks_changed`.
  """
  def block_user(%Scope{} = scope, user_id) do
    with %User{id: blocker_id} <- Visibility.member(scope),
         {:ok, user_id} <- Ids.cast(user_id),
         true <- user_id != blocker_id,
         true <- Repo.exists?(from(user in User, where: user.id == ^user_id)) do
      Repo.insert_all(UserBlock, [%{blocker_id: blocker_id, blocked_id: user_id}],
        on_conflict: :nothing
      )

      Topics.broadcast_user(blocker_id, :blocks_changed)
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Removes the scope's block of `user_id`. Unblocking an unblocked account is `:ok`."
  def unblock_user(%Scope{} = scope, user_id) do
    with %User{id: blocker_id} <- Visibility.member(scope),
         {:ok, user_id} <- Ids.cast(user_id) do
      Repo.delete_all(
        from(block in UserBlock,
          where: block.blocker_id == ^blocker_id and block.blocked_id == ^user_id
        )
      )

      Topics.broadcast_user(blocker_id, :blocks_changed)
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The accounts the scope blocks, most recently blocked first."
  def list_blocked_users(%Scope{} = scope) do
    case Visibility.member(scope) do
      nil ->
        []

      %User{id: blocker_id} ->
        Repo.all(
          from(user in User,
            join: block in UserBlock,
            on: block.blocked_id == user.id,
            where: block.blocker_id == ^blocker_id,
            order_by: [desc: block.inserted_at],
            preload: [:avatar_asset]
          )
        )
    end
  end

  @doc """
  Sets whether members with no direct message with the scope's account yet may start one.
  An existing DM is not affected.
  """
  def set_direct_messages_from_new_contacts(%Scope{} = scope, allowed?)
      when is_boolean(allowed?) do
    case Visibility.member(scope) do
      nil ->
        {:error, :not_found}

      %User{} = user ->
        user
        |> Ecto.Changeset.change(direct_messages_from_new_contacts: allowed?)
        |> Repo.update()
    end
  end

  # The live DM of the scope and `user_id`, when the scope may view it.
  defp visible_pair(scope, user_id) do
    with %User{id: me} <- Visibility.member(scope),
         [low, high] <- Enum.sort([me, user_id]),
         %Channel{id: id} <-
           Repo.one(
             from(channel in Channel,
               where:
                 channel.kind == :direct and is_nil(channel.deleted_at) and
                   channel.direct_low_user_id == ^low and channel.direct_high_user_id == ^high
             )
           ),
         %Channel{} = channel <- Visibility.visible_channel(scope, id) do
      channel |> List.wrap() |> with_peers(me) |> hd()
    else
      _ -> nil
    end
  end

  # Two members who start the same DM at once both get the one row: the second insert does
  # nothing on the pair's unique index, and both read the row back.
  defp start(scope, user_id) do
    result =
      Repo.transact(fn ->
        with :ok <- Visibility.authorize_write(scope, :start_direct_message, user_id),
             %User{id: me} <- Visibility.member(scope) do
          {:ok, insert_pair(me, user_id)}
        else
          _ -> {:error, :not_available}
        end
      end)

    with {:ok, created} <- result,
         %Channel{} = channel <- visible_pair(scope, user_id) do
      if created, do: announce(created)
      {:ok, channel}
    else
      _ -> {:error, :not_available}
    end
  end

  # The new row, or nil when the pair already has one.
  defp insert_pair(creator_id, other_id) do
    now = DateTime.utc_now()
    %Channel{} = template = Channel.new_direct(creator_id, other_id)

    row =
      template
      |> Map.take([:kind, :slug, :position, :direct_low_user_id, :direct_high_user_id])
      |> Map.merge(%{created_by_id: creator_id, inserted_at: now, updated_at: now})

    case Repo.insert_all(Channel, [row],
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment,
              "(direct_low_user_id, direct_high_user_id) WHERE deleted_at IS NULL"},
           returning: true
         ) do
      {1, [channel]} -> channel
      {0, []} -> nil
    end
  end

  defp announce(%Channel{} = channel) do
    for user_id <- Channel.participant_ids(channel),
        do: Topics.broadcast_user(user_id, {:direct_message_opened, channel})
  end

  defp participant_channels(user_id) do
    from(channel in Channel,
      where:
        channel.kind == :direct and is_nil(channel.deleted_at) and
          (channel.direct_low_user_id == ^user_id or channel.direct_high_user_id == ^user_id)
    )
  end

  defp with_peers(channels, user_id) do
    peers =
      channels
      |> Enum.map(&Channel.peer_id(&1, user_id))
      |> then(&Repo.all(from(user in User, where: user.id in ^&1, preload: [:avatar_asset])))
      |> Map.new(&{&1.id, &1})

    Enum.map(channels, &%{&1 | peer: Map.get(peers, Channel.peer_id(&1, user_id))})
  end
end
