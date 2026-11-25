defmodule Tavern.Chat.Alerts do
  @moduledoc """
  Decides which members a new message alerts, and hands each alert to its deliveries
  (docs/design/push-notifications.md).

  The decision runs once per message, in the writer's process after the message's transaction
  commits. One query finds the members who could match; `alert?/1` decides each of them; and
  `Visibility` confirms each one may view the conversation, with a scope of their own.

  Each recipient gets one notification, `%{channel_id, title, body, tag, path}`, by two routes:
  an open tab gets `{:alert, notification}` on its member's topic and decides only whether to
  show it, and each device with a push subscription gets it through `Tavern.WebPush`.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.ChannelMembership
  alias Tavern.Chat.ChannelNotificationOverride
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Message
  alias Tavern.Chat.PushSubscriptions
  alias Tavern.Chat.ThreadFollower
  alias Tavern.Chat.Topics
  alias Tavern.Chat.User
  alias Tavern.Chat.UserNotificationSetting
  alias Tavern.Chat.Visibility
  alias Tavern.Repo
  alias Tavern.WebPush

  @body_preview_length 140

  @doc """
  Decides the alerts for `message`, a message in the shape a broadcast carries, and delivers
  them. A pin line alerts no one: it says who pinned, which no member needs to be woken for.
  """
  def publish(%Message{kind: :pin}), do: :ok

  def publish(%Message{} = message) do
    case recipients(message) do
      [] ->
        :ok

      recipients ->
        notify = notification(message)

        for %{user_id: user_id, desktop?: true} = recipient <- recipients do
          Topics.broadcast_user(user_id, {:alert, notify.(recipient)})
        end

        WebPush.deliver(
          for %{push?: true} = recipient <- recipients,
              do: {recipient.user_id, notify.(recipient)}
        )
    end
  end

  @doc """
  The members `message` alerts, each as `%{user_id, mentioned?, desktop?, push?}`.
  `mentioned?` says whether a mention that counts selected the member, rather than an
  `:all_messages` level; `desktop?` that they want alerts in an open tab; `push?` that they
  have at least one push subscription.
  """
  def recipients(%Message{channel: %Channel{} = channel} = message) do
    mentions = mentions(message, channel)
    conversation_ids = conversation_ids(channel)
    candidates = message |> candidates_query(mentions, conversation_ids) |> Repo.all()
    candidate_ids = Enum.map(candidates, & &1.user_id)
    role_holders = role_holders(candidate_ids, mentions.role_ids)
    levels = levels(candidate_ids, conversation_ids)
    followers = followers(channel, candidate_ids)
    push_ids = push_ids(candidate_ids)

    candidates
    |> Enum.map(fn %{user_id: user_id, setting: setting} ->
      setting = setting || %UserNotificationSetting{user_id: user_id}

      mention = %{
        direct?: MapSet.member?(mentions.user_ids, user_id),
        role?: MapSet.member?(role_holders, user_id),
        everyone?: mentions.everyone?
      }

      facts = %{
        level: level(levels, user_id, channel),
        setting: setting,
        thread?: Channel.thread?(channel),
        followed?: MapSet.member?(followers, user_id),
        mention: mention
      }

      %{
        user_id: user_id,
        alert?: alert?(facts),
        mentioned?: mention_counts?(mention, setting),
        desktop?: setting.desktop_enabled,
        push?: MapSet.member?(push_ids, user_id)
      }
    end)
    |> Enum.filter(& &1.alert?)
    |> Enum.filter(&Visibility.can?(%Scope{user_id: &1.user_id}, :view_channel, channel))
    |> Enum.map(&Map.delete(&1, :alert?))
  end

  @doc """
  The alert rule for one member and one message, from facts already loaded:

  - `level`: the member's own level for the conversation (for a thread, its parent's when the
    thread's is `:default`), still `:default` when the member chose none;
  - `setting`: the member's `%UserNotificationSetting{}`;
  - `thread?` and `followed?`: whether the conversation is a thread, and the member follows it;
  - `mention`: `%{direct?, role?, everyone?}`, how the message mentions the member.
  """
  def alert?(%{level: level, setting: setting} = facts) do
    level = resolve_default(level, setting)

    cond do
      level == :nothing -> false
      facts.thread? and not facts.followed? -> facts.mention.direct?
      level == :all_messages -> true
      true -> mention_counts?(facts.mention, setting)
    end
  end

  defp resolve_default(:default, %UserNotificationSetting{} = setting) do
    cond do
      setting.notify_on_all_messages -> :all_messages
      setting.notify_on_mentions -> :mentions
      true -> :nothing
    end
  end

  defp resolve_default(level, _setting), do: level

  @doc """
  Whether a mention counts for a member with `setting`: a direct mention always, a role mention
  unless they suppress role mentions, an @everyone mention unless they suppress it. `mention` is
  `%{direct?, role?, everyone?}`. The alert rule and the unread mention badge both use it.
  """
  def mention_counts?(mention, %UserNotificationSetting{} = setting) do
    mention.direct? or (mention.role? and not setting.suppress_roles) or
      (mention.everyone? and not setting.suppress_everyone)
  end

  # What both deliveries show, per recipient. The tag is per message, so a browser that gets
  # the alert from a tab and from a push shows it once.
  defp notification(%Message{channel: channel, author: author} = message) do
    body = message.body |> to_string() |> String.trim() |> String.slice(0, @body_preview_length)
    # A direct message has no name to show: it is addressed to the one recipient.
    where = unless Channel.direct?(channel), do: "#" <> conversation_title(channel)

    base = %{
      channel_id: channel.id,
      body: if(body == "", do: "New message", else: body),
      tag: "mention-#{message.id}",
      path: message_path(message, channel)
    }

    fn %{mentioned?: mentioned?} ->
      title =
        cond do
          is_nil(where) -> "#{author.display_name} sent you a message"
          mentioned? -> "#{author.display_name} mentioned you in #{where}"
          true -> "#{author.display_name} in #{where}"
        end

      Map.put(base, :title, title)
    end
  end

  defp conversation_title(%Channel{} = channel) do
    if Channel.thread?(channel),
      do: channel |> Repo.preload(:starter_message) |> Channel.title(),
      else: channel.name
  end

  # The URL that opens the message in place, the same as
  # `TavernWeb.ServerLive.MessageJump.message_path/3`.
  defp message_path(%Message{id: id}, %Channel{} = channel) do
    cond do
      Channel.direct?(channel) ->
        "/?" <> URI.encode_query(dm: channel.id, message: id)

      Channel.thread?(channel) ->
        parent = Repo.get!(Channel, channel.parent_channel_id)
        "/?" <> URI.encode_query(channel: parent.slug, thread: channel.id, message: id)

      true ->
        "/?" <> URI.encode_query(channel: channel.slug, message: id)
    end
  end

  # Every message in a direct message mentions its peer: the DM is addressed to them
  # (docs/design/direct-messages.md). The peer's level for the DM, such as a mute, still applies.
  defp mentions(%Message{} = message, %Channel{} = channel) do
    {everyone, roles} = Enum.split_with(message.role_mentions, & &1.mentioned_role.is_default)
    user_ids = MapSet.new(message.user_mentions, & &1.mentioned_user_id)

    user_ids =
      if Channel.direct?(channel),
        do: MapSet.put(user_ids, Channel.peer_id(channel, message.author_id)),
        else: user_ids

    %{
      user_ids: user_ids,
      role_ids: Enum.map(roles, & &1.mentioned_role_id),
      everyone?: everyone != []
    }
  end

  defp conversation_ids(%Channel{} = channel) do
    if Channel.thread?(channel),
      do: [channel.id, channel.parent_channel_id],
      else: [channel.id]
  end

  # Active people with a delivery (desktop alerts on, or a live push subscription) who could match
  # the rule: anyone for an @everyone mention, otherwise the
  # mentioned, the holders of a mentioned role, and those who chose `:all_messages` for the
  # conversation or everywhere. `alert?/1` then decides each exactly.
  defp candidates_query(%Message{} = message, mentions, conversation_ids) do
    query =
      from(user in User,
        as: :user,
        join: membership in Membership,
        on: membership.user_id == user.id and is_nil(membership.deactivated_at),
        left_join: setting in UserNotificationSetting,
        on: setting.user_id == user.id,
        where: user.id != ^message.author_id,
        where: not user.bot and not user.system and is_nil(user.deleted_at),
        where:
          coalesce(setting.desktop_enabled, true) or
            exists(
              from(subscription in PushSubscriptions.live(),
                where: subscription.user_id == parent_as(:user).id,
                select: 1
              )
            ),
        select: %{user_id: user.id, setting: setting}
      )

    if mentions.everyone? do
      query
    else
      user_ids = MapSet.to_list(mentions.user_ids)

      where(
        query,
        [user, _membership, setting],
        user.id in ^user_ids or coalesce(setting.notify_on_all_messages, false) or
          exists(
            from(member_role in MemberRole,
              where:
                member_role.user_id == parent_as(:user).id and
                  member_role.role_id in ^mentions.role_ids
            )
          ) or
          exists(
            from(override in ChannelNotificationOverride,
              where:
                override.user_id == parent_as(:user).id and
                  override.channel_id in ^conversation_ids and override.level == :all_messages
            )
          ) or
          exists(
            from(channel_membership in ChannelMembership,
              where:
                channel_membership.user_id == parent_as(:user).id and
                  channel_membership.channel_id in ^conversation_ids and
                  channel_membership.notification_level == :all_messages
            )
          )
      )
    end
  end

  defp role_holders(_user_ids, []), do: MapSet.new()

  defp role_holders(user_ids, role_ids) do
    from(member_role in MemberRole,
      where: member_role.user_id in ^user_ids and member_role.role_id in ^role_ids,
      distinct: true,
      select: member_role.user_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # Each member's own level in each conversation id, by `{user_id, channel_id}`. An override
  # that is not `:default` wins over the channel membership's level, as in
  # `Tavern.Chat.Notifications`.
  defp levels(user_ids, channel_ids) do
    overrides =
      from(override in ChannelNotificationOverride,
        where: override.user_id in ^user_ids and override.channel_id in ^channel_ids,
        select: {{override.user_id, override.channel_id}, override.level}
      )
      |> Repo.all()
      |> Map.new()

    from(membership in ChannelMembership,
      where: membership.user_id in ^user_ids and membership.channel_id in ^channel_ids,
      select: {{membership.user_id, membership.channel_id}, membership.notification_level}
    )
    |> Repo.all()
    |> Map.new()
    |> Map.merge(Map.reject(overrides, fn {_key, level} -> level == :default end))
  end

  # A thread whose own level is :default takes its parent channel's level, so muting a channel
  # also mutes the threads under it.
  defp level(levels, user_id, %Channel{} = channel) do
    case Map.get(levels, {user_id, channel.id}, :default) do
      :default ->
        if Channel.thread?(channel),
          do: Map.get(levels, {user_id, channel.parent_channel_id}, :default),
          else: :default

      level ->
        level
    end
  end

  defp push_ids(user_ids) do
    from(subscription in PushSubscriptions.live(),
      where: subscription.user_id in ^user_ids,
      distinct: true,
      select: subscription.user_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp followers(%Channel{} = channel, user_ids) do
    if Channel.thread?(channel) do
      from(follower in ThreadFollower,
        where:
          follower.thread_id == ^channel.id and follower.user_id in ^user_ids and
            is_nil(follower.unfollowed_at),
        select: follower.user_id
      )
      |> Repo.all()
      |> MapSet.new()
    else
      MapSet.new()
    end
  end
end
