defmodule Tavern.Chat.Visibility do
  @moduledoc """
  Makes every access decision in the chat, for a `%Tavern.Accounts.Scope{}`.

  A decision loads its inputs in one statement: the account with membership and roles, the
  default role, the Unverified role, and for a channel or message target the channel, its parent and their overwrites.
  It then decides with the pure functions in this module and `Tavern.Chat.Authorization`. Nothing
  is cached between calls, so a role, timeout or ban change applies to the next decision.

  A bot scope names a token. Every load first checks that the token row still names the bot,
  is not revoked and has not expired; a failed check leaves the scope with no account.

  The account is the user row with its membership, whatever the membership's state. The
  member is the account when the membership is active. A decision about who may act uses the
  member. A moderation decision reads the subject's account, so a kicked member can still be
  banned: a deactivated membership removes the right to act, not the rank that others are measured
  against.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts
  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Authorization
  alias Tavern.Chat.BotToken
  alias Tavern.Chat.Channel
  alias Tavern.Chat.ChannelPermissionOverwrite
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Message
  alias Tavern.Chat.Role
  alias Tavern.Chat.User
  alias Tavern.Repo

  # A UUID that names no message. Loads that have no message target join against it, so the
  # message join matches nothing.
  @no_message_id "00000000-0000-0000-0000-000000000000"

  # Key of the transaction-scoped advisory lock on the role list (see `lock_role_list!/0`).
  @role_list_lock_key 7_314_002_003

  @doc "The member the scope acts as, with membership and roles, or nil when none may act."
  def member(%Scope{} = scope) do
    scope |> load([]) |> Map.fetch!(:member)
  end

  @doc """
  Whether a membership's timeout is still running. A timed-out member may view but not send,
  react, or create threads.
  """
  def timed_out?(%Membership{timeout_until: nil}), do: false

  def timed_out?(%Membership{timeout_until: timeout_until}),
    do: DateTime.compare(timeout_until, DateTime.utc_now()) == :gt

  @doc """
  Whether the scope may do `action` on `target` now.

  Channel bits take a `%Channel{}` target. Server-wide bits take `:server`. `:send_messages`,
  `:send_messages_in_threads` and the rest of the timed actions check the member's timeout
  first. `:edit_message`, `:delete_message`, `:suppress_embeds`, `:add_reactions`, `:vote_in_poll`
  and `:close_poll` take a `%Message{}` and read only its id: the message and its channel load in
  the decision's own statement. `{:moderate, bit}` takes the subject's user id. So does `:assign_roles` (giving or taking a member role).
  `:manage_permissions` (reading a channel's overwrites) takes a `%Channel{}`; so does
  `{:manage_permissions, target}`, which decides a write of the overwrite for `target`
  (`{:role, role_id}` or `{:user, user_id}`) on that channel. `:restore_channel` takes a
  `%Channel{}` and is the one decision that answers yes for a deleted channel.
  """
  def can?(%Scope{} = scope, action, target) do
    ctx = load_for(scope, action, target)

    if is_nil(ctx.member), do: false, else: decide(action, ctx, target)
  end

  defp lock_membership(user_id) do
    from(membership in Membership,
      where: membership.user_id == ^user_id,
      select: membership.id,
      lock: "FOR SHARE"
    )
    |> Repo.one()

    :ok
  end

  @doc """
  Takes the role-list lock exclusively. Every role write (`Tavern.Chat.Roles`) and every overwrite
  write (`Tavern.Chat.ChannelOverwrites`) takes it first, so those writes never interleave. A
  write that also takes the channel-tree lock takes this one before it. Must run inside the write
  transaction.
  """
  def lock_role_list! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@role_list_lock_key])
    :ok
  end

  # A moderation or ownership write names a subject. Both membership rows are taken `FOR UPDATE`,
  # each once, in ascending user id, so every such write takes them in the same order. The lock is
  # chosen by the action, not by the target's shape. Every other write holds only the actor's row.
  #
  # A moderation or role-assignment decision reads the actor's and the subject's top roles in two
  # statements. It first takes the role-list lock shared, so no role write (which may renumber
  # every position) commits between the two reads. A role assignment runs inside a role write that
  # already holds the lock exclusive; Postgres grants the shared lock to the same transaction.
  defp lock_membership_rows(%Scope{user_id: actor_id}, action, subject_id)
       when (is_tuple(action) and elem(action, 0) == :moderate) or action == :assign_roles do
    Repo.query!("SELECT pg_advisory_xact_lock_shared($1)", [@role_list_lock_key])
    lock_memberships!([actor_id, subject_id])
  end

  defp lock_membership_rows(%Scope{user_id: actor_id}, :manage_ownership, subject_id),
    do: lock_memberships!([actor_id, subject_id])

  # A user overwrite write reads the subject's rank, so it holds the subject's row as moderation
  # does. It runs under the role-list lock (exclusive), which keeps every rank still.
  defp lock_membership_rows(
         %Scope{user_id: actor_id},
         {:manage_permissions, {:user, subject_id}},
         %Channel{}
       ),
       do: lock_memberships!([actor_id, subject_id])

  defp lock_membership_rows(%Scope{user_id: actor_id}, _action, _target),
    do: lock_membership(actor_id)

  @doc """
  Takes the membership rows of `user_ids` `FOR UPDATE`, each once, in ascending user id. Every write
  that holds more than one membership row takes them this way, so two such writes never wait on
  each other in opposite orders. Must run inside the write transaction.
  """
  def lock_memberships!(user_ids) do
    user_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn user_id ->
      from(membership in Membership,
        where: membership.user_id == ^user_id,
        select: membership.id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()
    end)

    :ok
  end

  @doc """
  Takes the locks the action needs, then decides the write. Moderation and `:assign_roles` take
  the role-list lock shared; they and ownership changes lock the actor's and the subject's rows
  `FOR UPDATE` in user id order; every other write takes the actor's row `FOR SHARE`. A hidden or
  missing target returns `{:error, :not_found}`; a visible target without permission returns
  `{:error, :forbidden}`. This must run inside the write transaction.
  """
  def authorize_write(%Scope{} = scope, action, target) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "authorize_write/3 must run inside a transaction"
    end

    lock_membership_rows(scope, action, target)

    if can?(scope, action, target), do: :ok, else: refusal(scope, target)
  end

  defp refusal(scope, %Channel{id: id}) do
    case visible_channel(scope, id) do
      %Channel{} -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  defp refusal(scope, %Message{id: id}) do
    case visible_message(scope, id) do
      %Message{deleted_at: nil} -> {:error, :forbidden}
      %Message{} -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  defp refusal(_scope, :server), do: {:error, :forbidden}

  # A subject with no membership row, or whose user row is deleted, answers as a missing row. Any
  # other subject the scope may not change is `:forbidden`, whatever its membership state.
  defp refusal(_scope, subject_id) when is_binary(subject_id) do
    query =
      from(membership in Membership,
        join: user in User,
        on: user.id == membership.user_id,
        where: membership.user_id == ^subject_id and is_nil(user.deleted_at),
        select: membership.id
      )

    if Repo.exists?(query), do: {:error, :forbidden}, else: {:error, :not_found}
  end

  @doc """
  The channels and threads the scope may view now, ordered by position then creation. Each is
  the struct as loaded, with its overwrites.
  """
  def visible_channels(%Scope{} = scope) do
    filter_all_channels(scope, &view?/2)
  end

  @doc """
  The deleted channels and categories the scope may restore (`:restore_channel`), most recently
  deleted first.
  """
  def restorable_channels(%Scope{} = scope) do
    scope
    |> filter_all_channels(&channel_decision(:restore_channel, &1, &2))
    |> Enum.sort_by(& &1.deleted_at, {:desc, DateTime})
  end

  # Every channel row, with overwrites, that `keep?` accepts for the scope's member. Each decision
  # reads its parents from the same rows.
  defp filter_all_channels(scope, keep?) do
    ctx = load(scope, [])

    if is_nil(ctx.member) do
      []
    else
      channels =
        Repo.all(
          from(channel in Channel,
            order_by: [asc: channel.position, asc: channel.inserted_at],
            preload: [:permission_overwrites]
          )
        )

      ctx = %{ctx | channels: Map.new(channels, &{&1.id, &1})}
      Enum.filter(channels, &keep?.(ctx, &1))
    end
  end

  @doc "The ids of `visible_channels/1`, in the same order."
  def channel_ids(%Scope{} = scope) do
    scope
    |> visible_channels()
    |> Enum.map(& &1.id)
  end

  @doc """
  The channel `channel_id` when the scope may view it now, as the decision loaded it, or nil. A
  read that returns rows of this channel sets their `channel` from it, so it costs no query.
  """
  def visible_channel(%Scope{} = scope, channel_id) do
    ctx = load(scope, [channel_id])

    with false <- is_nil(ctx.member),
         {:ok, channel} <- Map.fetch(ctx.channels, channel_id),
         true <- view?(ctx, channel) do
      channel
    else
      _ -> nil
    end
  end

  # What a channel or thread view needs to know about the viewer. Each key is the action the
  # control would run; `abilities/2` decides them all from one load.
  @abilities [
    :send_messages,
    :send_messages_in_threads,
    :create_public_threads,
    :add_reactions,
    :manage_messages,
    :mention_everyone,
    :archive_thread,
    :rename_thread,
    :lock_thread,
    :delete_thread,
    :connect_voice,
    :speak_voice,
    :stream_voice,
    :mute_voice_members,
    :disconnect_voice_members
  ]

  @doc "The abilities of a scope that may do nothing: every key of `abilities/2`, false."
  def no_abilities, do: Map.new(@abilities, &{&1, false})

  @doc """
  What the scope may do in channel or thread `channel_id` now, as a map from action to boolean,
  decided from one load. A channel the scope cannot view answers all false.

  `:archive_thread` and `:lock_thread` answer for the control the viewer would use now: archive
  when the thread is open, unarchive when archived; lock when unlocked, unlock when locked. The
  thread's state comes from the same load, so it is never stale. The thread keys are false for a
  channel that is not a thread.
  """
  def abilities(%Scope{} = scope, channel_id) do
    ctx = load(scope, [channel_id])

    with false <- is_nil(ctx.member),
         {:ok, channel} <- Map.fetch(ctx.channels, channel_id),
         true <- view?(ctx, channel) do
      Map.new(@abilities, &{&1, channel_decision(thread_toggle(&1, channel), ctx, channel)})
    else
      _ -> no_abilities()
    end
  end

  defp thread_toggle(:archive_thread, %Channel{archived_at: nil}), do: :archive_thread
  defp thread_toggle(:archive_thread, _channel), do: :unarchive_thread
  defp thread_toggle(:lock_thread, %Channel{locked_at: nil}), do: :lock_thread
  defp thread_toggle(:lock_thread, _channel), do: :unlock_thread
  defp thread_toggle(action, _channel), do: action

  def voice_moderate?(%Scope{} = scope, bit, channel_id, subject_id)
      when bit in [:mute_voice_members, :disconnect_voice_members] do
    ctx = load(scope, [channel_id])

    with {:ok, channel} <- Map.fetch(ctx.channels, channel_id),
         true <- view?(ctx, channel) and bit?(ctx, channel, bit) do
      moderate_subject?(ctx, subject_id)
    else
      _ -> false
    end
  end

  @doc """
  The message `message_id` with its `channel` set, when the scope may view its channel now, or nil.
  The message and its channel come from the decision's own statement, so a read that returns the
  message decided on the same snapshot the message was read from.
  """
  def visible_message(%Scope{} = scope, message_id) do
    ctx = load(scope, [], message_id)

    with false <- is_nil(ctx.member),
         %Message{channel_id: channel_id} = message <- ctx.message,
         {:ok, channel} <- Map.fetch(ctx.channels, channel_id),
         true <- view?(ctx, channel) do
      %{message | channel: channel}
    else
      _ -> nil
    end
  end

  @doc """
  The facts `Tavern.Chat.RoleAuthority` decides from, read in one load: whether the scope is the
  owner, its server bits (owner and administrator expanded), its highest role position, and its
  bits in each of `channel_ids`. A scope with no member holds nothing.
  """
  def authority(%Scope{} = scope, channel_ids) do
    ctx = load(scope, channel_ids)

    case ctx.member do
      nil ->
        %{owner?: false, server_permissions: 0, top_role_position: 0, channel_permissions: %{}}

      member ->
        %{
          owner?: Accounts.owner?(member),
          server_permissions: server_bits(ctx),
          top_role_position: top_position(member, ctx.default_role),
          channel_permissions: Map.new(channel_ids, &{&1, channel_bits(ctx, &1)})
        }
    end
  end

  # --- Loading ---------------------------------------------------------------------------------

  # Loads the account, the member, the default role, the channels named by `channel_ids` with
  # their parents and overwrites, and the message named by `message_id`, in one statement.
  defp load(scope, channel_ids), do: load(scope, channel_ids, @no_message_id)

  defp load(%Scope{user_id: user_id, bot_token_id: token_id}, channel_ids, message_id) do
    now = DateTime.utc_now()
    base = from(user in User, where: user.id == ^user_id and is_nil(user.deleted_at))

    base =
      if is_nil(token_id) do
        base
      else
        from(user in base,
          join: token in BotToken,
          on:
            token.user_id == user.id and token.id == ^token_id and is_nil(token.revoked_at) and
              (is_nil(token.expires_at) or token.expires_at > ^now)
        )
      end

    base
    |> join_inputs(channel_ids, message_id)
    |> Repo.all()
    |> assemble()
  end

  defp load_for(%Scope{} = scope, _action, %Message{id: message_id}),
    do: load(scope, [], message_id)

  defp load_for(%Scope{} = scope, _action, %Channel{id: channel_id}),
    do: load(scope, [channel_id])

  defp load_for(%Scope{} = scope, _action, _target), do: load(scope, [])

  defp join_inputs(base, channel_ids, message_id) do
    from(user in base,
      left_join: membership in assoc(user, :membership),
      left_join: member_role in MemberRole,
      on: member_role.user_id == user.id,
      left_join: role in Role,
      on: role.id == member_role.role_id,
      left_join: default_role in Role,
      on: default_role.is_default == true,
      left_join: unverified_role in Role,
      on: unverified_role.is_unverified == true,
      left_join: target in Message,
      on: target.id == ^message_id,
      left_join: channel in Channel,
      on: channel.id in ^channel_ids or channel.id == target.channel_id,
      left_join: parent in Channel,
      on: parent.id == channel.parent_channel_id,
      left_join: grandparent in Channel,
      on: grandparent.id == parent.parent_channel_id,
      left_join: channel_overwrite in ChannelPermissionOverwrite,
      on: channel_overwrite.channel_id == channel.id,
      left_join: parent_overwrite in ChannelPermissionOverwrite,
      on: parent_overwrite.channel_id == parent.id,
      left_join: grandparent_overwrite in ChannelPermissionOverwrite,
      on: grandparent_overwrite.channel_id == grandparent.id,
      select: %{
        user: user,
        membership: membership,
        member_role: member_role,
        role: role,
        default_role: default_role,
        unverified_role: unverified_role,
        target: target,
        channel: channel,
        channel_overwrite: channel_overwrite,
        parent: parent,
        parent_overwrite: parent_overwrite,
        grandparent: grandparent,
        grandparent_overwrite: grandparent_overwrite
      }
    )
  end

  # The joined rows repeat the account once per role and overwrite. This folds them back into one
  # account with its roles, one default role, the target message, and each loaded channel with
  # its overwrites. A visibility decision walks up to two parents (thread, channel, category),
  # so each target is loaded with both.
  defp assemble([]),
    do: %{
      account: nil,
      member: nil,
      default_role: nil,
      implicit_roles: [],
      message: nil,
      channels: %{}
    }

  defp assemble([%{user: user} | _] = rows) do
    membership = Enum.find_value(rows, & &1.membership)

    member_roles =
      rows
      |> Enum.flat_map(fn row ->
        if row.member_role, do: [%{row.member_role | role: row.role}], else: []
      end)
      |> Enum.uniq_by(& &1.id)

    default_role = Enum.find_value(rows, & &1.default_role)
    message = Enum.find_value(rows, & &1.target)

    account = if membership, do: %{user | membership: membership, member_roles: member_roles}

    member = if membership && is_nil(membership.deactivated_at), do: account

    unverified_role = Enum.find_value(rows, & &1.unverified_role)

    implicit_roles =
      if member && unverified_role && Accounts.unverified?(member),
        do: [unverified_role],
        else: []

    channels =
      rows
      |> Enum.reduce(%{}, fn row, acc ->
        acc
        |> add_channel(row.channel, row.channel_overwrite)
        |> add_channel(row.parent, row.parent_overwrite)
        |> add_channel(row.grandparent, row.grandparent_overwrite)
      end)
      |> Map.new(fn {id, {channel, overwrites}} ->
        {id, %{channel | permission_overwrites: Map.values(overwrites)}}
      end)

    %{
      account: account,
      member: member,
      default_role: default_role,
      implicit_roles: implicit_roles,
      message: message,
      channels: channels
    }
  end

  defp add_channel(acc, nil, _overwrite), do: acc

  defp add_channel(acc, %Channel{id: id} = channel, overwrite) do
    {_, overwrites} = Map.get(acc, id, {channel, %{}})

    overwrites =
      if overwrite, do: Map.put(overwrites, overwrite.id, overwrite), else: overwrites

    Map.put(acc, id, {channel, overwrites})
  end

  # --- Decisions -------------------------------------------------------------------------------

  defp decide(action, ctx, %Channel{id: channel_id}) when is_atom(action) do
    case Map.fetch(ctx.channels, channel_id) do
      {:ok, channel} -> channel_decision(action, ctx, channel)
      :error -> false
    end
  end

  # A deleted message takes no action, so edit, delete, reaction and thread creation answer as
  # for a missing one.
  defp decide(action, ctx, %Message{}) when is_atom(action) do
    with %Message{deleted_at: nil, author_id: author_id, channel_id: channel_id} <- ctx.message,
         {:ok, channel} <- Map.fetch(ctx.channels, channel_id) do
      message_decision(action, ctx, author_id, channel)
    else
      _ -> false
    end
  end

  defp decide(action, ctx, :server) when is_atom(action) do
    Authorization.has_permission?(server_bits(ctx), action)
  end

  # Ownership changes are decided by the actor alone: an active owner. The subject's state is
  # checked by the caller after the lock is held.
  defp decide(:manage_ownership, ctx, subject_id) when is_binary(subject_id),
    do: Accounts.owner?(ctx.member)

  # Giving or taking a role. The actor holds `manage_roles` and ranks over the subject. Which roles
  # may be given is decided by `Tavern.Chat.RoleAuthority` after this.
  defp decide(:assign_roles, ctx, subject_id) when is_binary(subject_id) do
    Authorization.has_permission?(server_bits(ctx), :manage_roles) and
      ranks_over?(ctx, subject_id)
  end

  # Writing a channel overwrite. The actor may manage the channel's permissions and ranks over the
  # target. Which bits the write may change is decided by `Tavern.Chat.ChannelOverwrites` after
  # this, from the stored overwrite.
  defp decide({:manage_permissions, target}, ctx, %Channel{} = channel) do
    decide(:manage_permissions, ctx, channel) and overwrite_target?(ctx, target)
  end

  defp decide({:moderate, bit}, ctx, subject_id) when is_binary(subject_id) do
    Authorization.has_permission?(server_bits(ctx), bit) and moderate_subject?(ctx, subject_id)
  end

  # The subject and rank checks `{:moderate, bit}` and `voice_moderate?/4` share.
  defp moderate_subject?(ctx, subject_id) do
    subject = load(%Scope{user_id: subject_id}, [])

    cond do
      is_nil(subject.account) ->
        false

      ctx.member.id == subject_id ->
        false

      Accounts.owner?(subject.account) ->
        false

      Accounts.owner?(ctx.member) ->
        true

      true ->
        top_position(ctx.member, ctx.default_role) >
          top_position(subject.account, subject.default_role)
    end
  end

  # A locked or archived thread takes no edit, delete or reaction from anyone without
  # `manage_messages` in its parent channel (`thread_closed?/2`).
  defp message_decision(:edit_message, ctx, author_id, channel),
    do:
      ctx.member.id == author_id and not acting_timed_out?(ctx) and view?(ctx, channel) and
        not thread_closed?(ctx, channel)

  # Removing a message's embeds follows deleting it: the author, or `manage_messages`.
  defp message_decision(action, ctx, author_id, channel)
       when action in [:delete_message, :suppress_embeds],
       do:
         view?(ctx, channel) and not thread_closed?(ctx, channel) and
           (ctx.member.id == author_id or bit?(ctx, channel, :manage_messages))

  defp message_decision(:add_reactions, ctx, _author_id, channel),
    do: channel_decision(:add_reactions, ctx, channel) and not thread_closed?(ctx, channel)

  # A vote needs what a send needs (view, send rights, no timeout, an unlocked thread) and is
  # refused in a closed thread as a reaction is: a vote never reopens an archived thread.
  # A poll's own voter list narrows this further (`Tavern.Chat.Polls`).
  defp message_decision(:vote_in_poll, ctx, _author_id, channel),
    do: send?(ctx, channel) and not thread_closed?(ctx, channel)

  # Ending a poll by hand: the author, or `manage_messages`. A locked or archived thread does not
  # block it, as the closer ends due polls there too.
  defp message_decision(:close_poll, ctx, author_id, channel),
    do:
      view?(ctx, channel) and
        (ctx.member.id == author_id or bit?(ctx, channel, :manage_messages))

  defp message_decision(:create_public_threads, ctx, _author_id, channel),
    do: channel_decision(:create_public_threads, ctx, channel)

  defp channel_decision(:view_channel, ctx, channel), do: view?(ctx, channel)
  # A forum holds posts, which are threads, and no message of its own. Only this decision says
  # so: `send?/2` still answers for a forum, because its posts and their replies need it.
  defp channel_decision(:send_messages, _ctx, %Channel{kind: :forum}), do: false
  defp channel_decision(:send_messages, ctx, channel), do: send?(ctx, channel)

  defp channel_decision(:send_messages_in_threads, ctx, channel),
    do: send_in_thread?(ctx, channel)

  defp channel_decision(:create_public_threads, ctx, channel), do: create_threads?(ctx, channel)

  defp channel_decision(:manage_channels, ctx, channel),
    do: view?(ctx, channel) and Authorization.has_permission?(server_bits(ctx), :manage_channels)

  # Restoring a deleted channel or category: server `manage_channels`, and the scope could view
  # the channel once it is restored. So a manager never learns of a deleted channel that was
  # hidden from them.
  defp channel_decision(:restore_channel, ctx, %Channel{deleted_at: %DateTime{}} = channel),
    do:
      not Channel.thread?(channel) and
        Authorization.has_permission?(server_bits(ctx), :manage_channels) and
        view?(ctx, %{channel | deleted_at: nil})

  defp channel_decision(:restore_channel, _ctx, _channel), do: false

  defp channel_decision(:add_reactions, ctx, channel),
    do: not acting_timed_out?(ctx) and view?(ctx, channel) and bit?(ctx, channel, :add_reactions)

  defp channel_decision(:manage_messages, ctx, channel),
    do: view?(ctx, channel) and bit?(ctx, channel, :manage_messages)

  # Whether the server shows previews of the member's links here. It is decided when a fetch
  # completes, not when the message is sent, so a role change in between applies.
  defp channel_decision(:embed_links, ctx, channel),
    do: view?(ctx, channel) and bit?(ctx, channel, :embed_links)

  # Archiving, unarchiving and renaming: the thread's creator or a manager. A locked thread takes
  # them from a manager only. Locking and unlocking are the manager's alone.
  defp channel_decision(action, ctx, channel)
       when action in [:archive_thread, :unarchive_thread, :rename_thread],
       do:
         Channel.thread?(channel) and view?(ctx, channel) and
           (thread_manager?(ctx, channel) or
              (is_nil(channel.locked_at) and not acting_timed_out?(ctx) and
                 channel.created_by_id == ctx.member.id))

  defp channel_decision(action, ctx, channel) when action in [:lock_thread, :unlock_thread],
    do: Channel.thread?(channel) and view?(ctx, channel) and thread_manager?(ctx, channel)

  # Deleting a thread or forum post: a manager's alone, whatever the thread's state. The creator
  # holds no right to it.
  defp channel_decision(:delete_thread, ctx, channel),
    do: Channel.thread?(channel) and view?(ctx, channel) and thread_manager?(ctx, channel)

  # Whether the member may send in this channel or thread without waiting out its slowmode.
  defp channel_decision(:bypass_slowmode, ctx, channel),
    do:
      view?(ctx, channel) and
        (channel_manager?(ctx, channel) or
           Authorization.has_permission?(server_bits(ctx), :manage_channels))

  defp channel_decision(:mention_everyone, ctx, channel),
    do: view?(ctx, channel) and bit?(ctx, channel, :mention_everyone)

  # Voice: connect, publish audio, publish video (camera or screen), and the two moderator
  # actions on another member (docs/design/voice.md). A moderator action also needs the actor
  # to rank over the subject, decided with the same subject checks as `{:moderate, bit}`
  # (`voice_moderate?/4`).
  defp channel_decision(action, ctx, channel)
       when action in [
              :connect_voice,
              :speak_voice,
              :stream_voice,
              :mute_voice_members,
              :disconnect_voice_members
            ],
       do: view?(ctx, channel) and bit?(ctx, channel, action)

  defp channel_decision(:manage_permissions, ctx, channel),
    do: view?(ctx, channel) and bit?(ctx, channel, :manage_roles)

  # An overwrite target is a role below the actor's top role (the default role always), or a
  # subject the actor ranks over.
  defp overwrite_target?(ctx, {:role, role_id}) do
    case Repo.get(Role, role_id) do
      %Role{is_default: true} ->
        true

      %Role{} = role ->
        Accounts.owner?(ctx.member) or role.position < top_position(ctx.member, ctx.default_role)

      nil ->
        false
    end
  end

  defp overwrite_target?(ctx, {:user, subject_id}), do: ranks_over?(ctx, subject_id)

  # The owner ranks over every account; anyone else ranks over themselves and over a non-owner whose
  # top role is below their own. The subject's rank is read from its account, whatever the state
  # of its membership.
  defp ranks_over?(ctx, subject_id) do
    subject = load(%Scope{user_id: subject_id}, [])

    cond do
      is_nil(subject.account) ->
        false

      Accounts.owner?(ctx.member) ->
        true

      ctx.member.id == subject_id ->
        true

      Accounts.owner?(subject.account) ->
        false

      true ->
        top_position(ctx.member, ctx.default_role) >
          top_position(subject.account, subject.default_role)
    end
  end

  # A channel is visible when it is not deleted, grants view and its parent is visible: a thread
  # needs its channel, and a channel needs its category. A thread always has a parent. So a
  # deleted channel hides its threads and their messages with it.
  defp view?(_ctx, %Channel{deleted_at: %DateTime{}}), do: false

  defp view?(ctx, %Channel{parent_channel_id: nil} = channel),
    do: not Channel.thread?(channel) and bit?(ctx, channel, :view_channel)

  defp view?(ctx, %Channel{} = channel),
    do: parent_visible?(ctx, channel) and bit?(ctx, channel, :view_channel)

  defp parent_visible?(ctx, channel) do
    case parent(ctx, channel) do
      nil -> false
      parent -> view?(ctx, parent)
    end
  end

  defp send?(ctx, %Channel{} = channel) do
    if Channel.thread?(channel) do
      send_in_thread?(ctx, channel)
    else
      not acting_timed_out?(ctx) and bit?(ctx, channel, :send_messages) and view?(ctx, channel)
    end
  end

  defp send_in_thread?(ctx, %Channel{} = thread) do
    Channel.thread?(thread) and not acting_timed_out?(ctx) and view?(ctx, thread) and
      bit?(ctx, thread, :send_messages_in_threads) and
      (is_nil(thread.locked_at) or thread_manager?(ctx, thread)) and
      case parent(ctx, thread) do
        nil -> false
        parent -> send?(ctx, parent)
      end
  end

  defp create_threads?(ctx, %Channel{} = channel) do
    Channel.thread_host?(channel) and not acting_timed_out?(ctx) and send?(ctx, channel) and
      bit?(ctx, channel, :create_public_threads)
  end

  # A thread is closed to ordinary members once it is locked or archived. A send into an archived
  # thread is not refused here: it reopens the thread. Only a locked thread refuses it
  # (`send_in_thread?/2`).
  defp thread_closed?(ctx, %Channel{} = channel),
    do:
      Channel.thread?(channel) and
        (not is_nil(channel.locked_at) or not is_nil(channel.archived_at)) and
        not thread_manager?(ctx, channel)

  # `manage_messages` in the thread's parent channel stands in for Discord's Manage Threads.
  defp thread_manager?(ctx, %Channel{} = thread) do
    case parent(ctx, thread) do
      nil -> false
      parent -> bit?(ctx, parent, :manage_messages)
    end
  end

  defp channel_manager?(ctx, %Channel{} = channel) do
    if Channel.thread?(channel),
      do: thread_manager?(ctx, channel),
      else: bit?(ctx, channel, :manage_messages)
  end

  defp parent(_ctx, %Channel{parent_channel_id: nil}), do: nil
  defp parent(ctx, %Channel{parent_channel_id: parent_id}), do: Map.get(ctx.channels, parent_id)

  defp bit?(ctx, %Channel{} = channel, bit) do
    channel_bits(ctx, channel)
    |> Authorization.has_permission?(bit)
  end

  defp channel_bits(ctx, %Channel{} = channel) do
    Authorization.channel_permissions(ctx.member, channel, ctx.default_role, ctx.implicit_roles)
  end

  defp channel_bits(ctx, channel_id) when is_binary(channel_id) do
    case Map.fetch(ctx.channels, channel_id) do
      {:ok, channel} -> channel_bits(ctx, channel)
      :error -> 0
    end
  end

  defp server_bits(ctx),
    do: Authorization.server_permissions(ctx.member, ctx.default_role, ctx.implicit_roles)

  defp acting_timed_out?(ctx), do: timed_out?(ctx.member.membership)

  defp top_position(%User{member_roles: member_roles}, default_role) do
    member_roles
    |> Enum.map(& &1.role.position)
    |> Enum.max(fn -> (default_role && default_role.position) || 0 end)
  end
end
