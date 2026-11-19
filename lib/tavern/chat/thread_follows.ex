defmodule Tavern.Chat.ThreadFollows do
  @moduledoc """
  Who follows which thread (docs/design/threads.md).

  A member follows a thread when they create it, post in it or are directly mentioned in it, and
  when they press Follow. Unfollow keeps the row with `unfollowed_at` set, so a later post or
  mention leaves them unfollowed; only Follow clears it.

  Every change to a member's follow state is broadcast as `{:thread_followers_changed, thread_id,
  user_ids}` on the parent channel's topic, after the commit. A member who can view a thread can
  view its parent, so every session of a changed follower that lists the parent receives it.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageUserMention
  alias Tavern.Chat.ThreadFollower
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @doc """
  Follows a thread the scope may view, and clears an earlier unfollow. A thread the scope may not
  view is `{:error, :not_found}`.
  """
  def follow(%Scope{} = scope, thread_id),
    do: set_follow(scope, thread_id, nil)

  @doc "Unfollows a thread the scope may view. The row stays, so a post or mention does not undo it."
  def unfollow(%Scope{} = scope, thread_id),
    do: set_follow(scope, thread_id, DateTime.utc_now())

  @doc "Whether the scope follows `thread_id` now. A thread it may not view is never followed."
  def following?(%Scope{} = scope, thread_id) do
    with {:ok, thread_id} <- Ecto.UUID.cast(thread_id),
         %Channel{} = thread <- Visibility.visible_channel(scope, thread_id),
         true <- Channel.thread?(thread) do
      Repo.exists?(
        from(follower in ThreadFollower,
          where:
            follower.thread_id == ^thread_id and follower.user_id == ^scope.user_id and
              is_nil(follower.unfollowed_at)
        )
      )
    else
      _ -> false
    end
  end

  @doc """
  Records that `user_id` created `thread`. Runs inside the thread's create transaction. It needs
  no broadcast: the `:channel_created` event that follows the commit makes every session reload.
  """
  def follow_created(%Channel{} = thread, user_id) do
    insert_new(thread.id, [{user_id, :created}])
    :ok
  end

  @doc """
  Records the follows a new message makes: its author (`:posted`) and each directly mentioned
  member who may view the thread (`:mentioned`). A message outside a thread makes none. A role or
  @everyone mention follows no one, so a mass mention does not fill everyone's sidebar. Runs
  inside the message's create transaction, after its mentions are stored; returns the user ids
  whose follow state changed.
  """
  def follow_for_message(%Message{} = message) do
    case Repo.get(Channel, message.channel_id) do
      %Channel{} = channel ->
        if Channel.thread?(channel),
          do: {:ok, insert_new(channel.id, message_follows(message, channel))},
          else: {:ok, []}

      nil ->
        {:ok, []}
    end
  end

  @doc """
  Announces a committed thread message to the sessions that list its parent channel, as
  `{:thread_message_created, message}`, then the follows it made. The message event comes first,
  so a session that reloads on the follow change already counts the message. A session hears of
  thread activity this way without subscribing to every thread's topic. A message outside a
  thread announces nothing here.
  """
  def broadcast_message_created(%Message{channel: %Channel{} = channel} = message, new_followers) do
    if Channel.thread?(channel) do
      Topics.broadcast_channel(channel.parent_channel_id, {:thread_message_created, message})
      broadcast_changes(channel, new_followers)
    end

    :ok
  end

  @doc """
  Announces a deleted thread message on its parent channel's topic, as
  `{:thread_message_deleted, message}`, so a session that lists the channel but has the thread
  closed lowers the reply count its chip shows. A message outside a thread announces nothing.
  """
  def broadcast_message_deleted(%Message{channel: %Channel{} = channel} = message) do
    if Channel.thread?(channel),
      do: Topics.broadcast_channel(channel.parent_channel_id, {:thread_message_deleted, message})

    :ok
  end

  @doc "Broadcasts a follow change to the parent channel's topic. Call it after the commit."
  def broadcast_changes(_thread, []), do: :ok

  def broadcast_changes(%Channel{parent_channel_id: parent_id, id: thread_id}, user_ids) do
    Topics.broadcast_channel(parent_id, {:thread_followers_changed, thread_id, user_ids})
  end

  defp message_follows(%Message{author_id: author_id, id: message_id}, channel) do
    mentioned =
      from(mention in MessageUserMention,
        where: mention.message_id == ^message_id and mention.mentioned_user_id != ^author_id,
        select: mention.mentioned_user_id
      )
      |> Repo.all()
      |> Enum.filter(&Visibility.visible_channel(%Scope{user_id: &1}, channel.id))

    [{author_id, :posted} | Enum.map(mentioned, &{&1, :mentioned})]
  end

  # Inserts rows for members with no row yet. A member who already has one, followed or
  # unfollowed, keeps it unchanged: that is what makes a manual unfollow stick. Rows go in user id
  # order, so two sends that follow the same members take their index locks in the same order and
  # never deadlock.
  defp insert_new(thread_id, follows) do
    now = DateTime.utc_now()

    rows =
      for {user_id, source} <- Enum.sort_by(follows, &elem(&1, 0)) do
        %{thread_id: thread_id, user_id: user_id, source: source, followed_at: now}
      end

    {_count, inserted} =
      Repo.insert_all(ThreadFollower, rows,
        on_conflict: :nothing,
        conflict_target: [:thread_id, :user_id],
        returning: [:user_id]
      )

    Enum.map(inserted, & &1.user_id)
  end

  defp set_follow(scope, thread_id, unfollowed_at) do
    with {:ok, thread_id} <- Ecto.UUID.cast(thread_id) do
      Repo.transact(fn ->
        with :ok <- Visibility.authorize_write(scope, :view_channel, %Channel{id: thread_id}),
             %Channel{} = thread <- Repo.get(Channel, thread_id),
             true <- Channel.thread?(thread) do
          upsert_manual(thread_id, scope.user_id, unfollowed_at)
          {:ok, thread}
        else
          _refused -> {:error, :not_found}
        end
      end)
      |> case do
        {:ok, thread} ->
          broadcast_changes(thread, [scope.user_id])
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp upsert_manual(thread_id, user_id, unfollowed_at) do
    now = DateTime.utc_now()

    # An unfollow keeps the row's source and followed_at, which say how the member came to
    # follow; a follow replaces them.
    on_conflict =
      if unfollowed_at,
        do: [set: [unfollowed_at: unfollowed_at]],
        else: [set: [source: :manual, followed_at: now, unfollowed_at: nil]]

    Repo.insert!(
      %ThreadFollower{
        thread_id: thread_id,
        user_id: user_id,
        source: :manual,
        followed_at: now,
        unfollowed_at: unfollowed_at
      },
      on_conflict: on_conflict,
      conflict_target: [:thread_id, :user_id]
    )
  end
end
