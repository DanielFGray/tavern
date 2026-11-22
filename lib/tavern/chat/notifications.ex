defmodule Tavern.Chat.Notifications do
  @moduledoc """
  A member's notification settings and read state. Each function reads or writes only the rows
  of `scope.user_id`, the read policy's "that member only". The channel ids it takes come from
  the caller's scoped channel reads, except where a function says it decides the channel itself.

  `message_mentions_user?/2` and `message_mentions_user_directly?/2` take a `%User{}`, not a
  scope: they are pure, and decide from rows already preloaded, so each receiver of a broadcast
  decides without a query.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.ChannelMembership
  alias Tavern.Chat.ChannelNotificationOverride
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageRoleMention
  alias Tavern.Chat.MessageUserMention
  alias Tavern.Chat.Role
  alias Tavern.Chat.User
  alias Tavern.Chat.UserNotificationSetting
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @doc "The scope's notification setting, or the defaults when none is stored."
  def get_user_notification_setting(%Scope{user_id: user_id}) do
    Repo.get_by(UserNotificationSetting, user_id: user_id) ||
      %UserNotificationSetting{user_id: user_id}
  end

  def update_user_notification_setting(%Scope{} = scope, attrs) do
    scope
    |> get_user_notification_setting()
    |> UserNotificationSetting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "The scope's channel membership rows among `channel_ids`, by channel id."
  def channel_memberships(%Scope{user_id: user_id}, channel_ids) when is_list(channel_ids) do
    ChannelMembership
    |> where(
      [membership],
      membership.user_id == ^user_id and membership.channel_id in ^channel_ids
    )
    |> Repo.all()
    |> Map.new(&{&1.channel_id, &1})
  end

  @doc """
  Sets the scope's notification level and favourite flag for channel `channel_id`. The id comes
  from the client, so the write first decides that the scope may view the channel:
  `{:error, :not_found}` when it may not, or when the id names no channel.
  """
  def update_channel_membership_notification(%Scope{} = scope, channel_id, attrs) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id) do
      Repo.transact(fn ->
        with :ok <- Visibility.authorize_write(scope, :view_channel, %Channel{id: channel_id}) do
          scope.user_id
          |> channel_membership(channel_id)
          |> ChannelMembership.changeset(attrs)
          |> Repo.insert_or_update()
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  defp channel_membership(user_id, channel_id) do
    Repo.get_by(ChannelMembership, user_id: user_id, channel_id: channel_id) ||
      %ChannelMembership{user_id: user_id, channel_id: channel_id, joined_at: DateTime.utc_now()}
  end

  @doc "The scope's unread message count in each of `channel_ids`, by channel id."
  def unread_counts(%Scope{user_id: user_id}, channel_ids) when is_list(channel_ids) do
    counts = unread_counts_by_channel(user_id, channel_ids)
    Map.new(channel_ids, &{&1, Map.get(counts, &1, 0)})
  end

  @doc """
  The number of unread messages in each of `channel_ids` that mention the scope: directly,
  through one of its roles, or through the default role. By channel id.
  """
  def unread_mentions(%Scope{user_id: user_id}, channel_ids) when is_list(channel_ids) do
    role_ids =
      Role
      |> join(:left, [role], member_role in assoc(role, :member_roles),
        on: member_role.user_id == ^user_id
      )
      |> where([role, member_role], role.is_default or not is_nil(member_role.id))
      |> select([role, _member_role], role.id)
      |> Repo.all()

    mentions = unread_mentions_by_channel(user_id, role_ids, channel_ids)
    Map.new(channel_ids, &{&1, Map.get(mentions, &1, 0)})
  end

  @doc """
  Whether `message` mentions `user`: directly, through one of the user's roles, or through
  the default role. It reads the mention rows preloaded on the message, which
  Chat.create_message/3 loads before it broadcasts, so every receiver decides without a query.
  """
  def message_mentions_user?(
        %Message{user_mentions: user_mentions, role_mentions: role_mentions},
        %User{id: user_id, member_roles: member_roles}
      )
      when is_list(user_mentions) and is_list(role_mentions) and is_list(member_roles) do
    role_ids = MapSet.new(member_roles, & &1.role_id)

    Enum.any?(user_mentions, &(&1.mentioned_user_id == user_id)) or
      Enum.any?(role_mentions, fn mention ->
        MapSet.member?(role_ids, mention.mentioned_role_id) or mention.mentioned_role.is_default
      end)
  end

  @doc """
  Whether `message` mentions `user` by name. A role or @everyone mention does not count. A thread
  the user does not follow notifies only on this kind of mention.
  """
  def message_mentions_user_directly?(%Message{user_mentions: user_mentions}, %User{id: user_id})
      when is_list(user_mentions),
      do: Enum.any?(user_mentions, &(&1.mentioned_user_id == user_id))

  @doc """
  Whether a mention in `channel` should alert the scope: desktop and mention alerts are on, and
  the channel's effective level is not `:nothing`. The channel struct is read for its parent
  link only.
  """
  def mention_notifications_enabled?(%Scope{} = scope, %Channel{} = channel) do
    setting = get_user_notification_setting(scope)

    cond do
      not setting.desktop_enabled ->
        false

      not setting.notify_on_mentions ->
        false

      true ->
        case effective_channel_notification_level(scope.user_id, channel) do
          :nothing -> false
          _ -> true
        end
    end
  end

  @doc """
  Marks channel `channel_id` read for the scope up to `message`, or up to the channel's latest
  message when none is given. `message` is the one the caller already shows; its id and time set
  the read marker.
  """
  def mark_channel_read(%Scope{user_id: user_id}, channel_id, message \\ nil) do
    message = message || latest_message_for_channel(channel_id)
    now = DateTime.utc_now()
    last_read_at = message && DateTime.add(message.inserted_at, 1, :microsecond)

    %ChannelMembership{}
    |> ChannelMembership.changeset(%{
      channel_id: channel_id,
      user_id: user_id,
      joined_at: now,
      last_read_message_id: message && message.id,
      last_read_at: last_read_at
    })
    |> Repo.insert!(
      on_conflict: [
        set: [
          last_read_message_id: message && message.id,
          last_read_at: last_read_at,
          updated_at: now
        ]
      ],
      conflict_target: [:channel_id, :user_id]
    )

    :ok
  end

  defp latest_message_for_channel(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id)
    |> Message.where_listed()
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(1)
    |> Repo.one()
  end

  defp unread_counts_by_channel(_user_id, []), do: %{}

  defp unread_counts_by_channel(user_id, channel_ids) do
    channel_ids
    |> unread_messages_query(user_id)
    |> group_by([message], message.channel_id)
    |> select([message], {message.channel_id, count(message.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp unread_mentions_by_channel(_user_id, _role_ids, []), do: %{}

  defp unread_mentions_by_channel(user_id, role_ids, channel_ids) do
    direct_mentions_query =
      channel_ids
      |> unread_messages_query(user_id)
      |> join(:inner, [message, _membership, _last_read_message], mention in MessageUserMention,
        on: mention.message_id == message.id and mention.mentioned_user_id == ^user_id
      )
      |> select([message, _membership, _last_read_message, _mention], {
        message.channel_id,
        message.id
      })

    role_mentions_query =
      if role_ids == [] do
        nil
      else
        channel_ids
        |> unread_messages_query(user_id)
        |> join(:inner, [message, _membership, _last_read_message], mention in MessageRoleMention,
          on: mention.message_id == message.id and mention.mentioned_role_id in ^role_ids
        )
        |> select([message, _membership, _last_read_message, _mention], {
          message.channel_id,
          message.id
        })
      end

    [direct_mentions_query, role_mentions_query]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&Repo.all/1)
    |> Enum.group_by(fn {channel_id, _message_id} -> channel_id end, fn {_channel_id, message_id} ->
      message_id
    end)
    |> Map.new(fn {channel_id, message_ids} ->
      {channel_id, message_ids |> MapSet.new() |> MapSet.size()}
    end)
  end

  defp unread_messages_query(channel_ids, user_id) do
    boundary = unread_boundary_dynamic()

    from(message in Message,
      left_join: membership in ChannelMembership,
      on: membership.user_id == ^user_id and membership.channel_id == message.channel_id,
      left_join: last_read_message in Message,
      on: last_read_message.id == membership.last_read_message_id,
      where: message.channel_id in ^channel_ids,
      where: message.author_id != ^user_id,
      where: ^boundary
    )
    |> Message.where_listed()
  end

  defp unread_boundary_dynamic do
    dynamic(
      [message, membership, last_read_message],
      is_nil(membership.id) or
        (not is_nil(membership.last_read_message_id) and not is_nil(last_read_message.id) and
           (message.inserted_at > last_read_message.inserted_at or
              (message.inserted_at == last_read_message.inserted_at and
                 message.id > last_read_message.id))) or
        (is_nil(membership.last_read_message_id) and not is_nil(membership.last_read_at) and
           message.inserted_at > membership.last_read_at) or
        (is_nil(membership.last_read_message_id) and is_nil(membership.last_read_at))
    )
  end

  # A thread whose own level is :default takes its parent channel's level, so muting a channel
  # also mutes the threads under it.
  defp effective_channel_notification_level(user_id, %Channel{} = channel) do
    case own_notification_level(user_id, channel.id) do
      :default when is_binary(channel.parent_channel_id) ->
        if Channel.thread?(channel),
          do: own_notification_level(user_id, channel.parent_channel_id),
          else: :default

      level ->
        level
    end
  end

  defp own_notification_level(user_id, channel_id) do
    override =
      Repo.get_by(ChannelNotificationOverride, user_id: user_id, channel_id: channel_id)

    membership =
      Repo.get_by(ChannelMembership, user_id: user_id, channel_id: channel_id)

    cond do
      override && override.level != :default -> override.level
      membership && membership.notification_level != :default -> membership.notification_level
      true -> :default
    end
  end
end
