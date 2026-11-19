defmodule Tavern.Chat.Threads do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Channels
  alias Tavern.Chat.Message
  alias Tavern.Chat.ThreadFollower
  alias Tavern.Chat.ThreadFollows
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @browse_page_size 25

  @doc """
  The unarchived threads the scope follows and may view, newest activity first, as entries (see
  `browse_threads/3`). The sidebar lists them under their parent channels.
  """
  def followed_threads(%Scope{} = scope) do
    case visible_thread_ids(scope) do
      [] ->
        []

      thread_ids ->
        thread_ids
        |> thread_entries_query(scope.user_id)
        |> where([thread, _activity, follower], not is_nil(follower.id))
        |> where([thread], is_nil(thread.archived_at))
        |> Repo.all()
    end
  end

  @doc """
  One page of the threads under `channel_id` for the thread browser, each an entry
  `%{thread: thread, last_activity_at: at, reply_count: n, following?: bool}`.

  Options: `:tab` (`:active` or `:archived`), `:query` (a title substring) and `:after` (the
  `next` cursor of the page before). Returns `{:ok, %{entries: entries, next: cursor_or_nil}}`, or
  `{:error, :not_found}` for a channel the scope may not view or one that holds no threads.
  """
  def browse_threads(%Scope{} = scope, channel_id, opts \\ []) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id),
         visible = Visibility.visible_channels(scope),
         %Channel{} = channel <- Enum.find(visible, &(&1.id == channel_id)),
         true <- Channel.thread_host?(channel) do
      thread_ids =
        for thread <- visible,
            thread.parent_channel_id == channel_id,
            Channel.thread?(thread),
            do: thread.id

      entries =
        thread_ids
        |> thread_entries_query(scope.user_id)
        |> where_tab(Keyword.get(opts, :tab, :active))
        |> where_title(Keyword.get(opts, :query))
        |> where_after(Keyword.get(opts, :after))
        |> limit(@browse_page_size + 1)
        |> Repo.all()

      {page, rest} = Enum.split(entries, @browse_page_size)
      next = if rest == [], do: nil, else: cursor(List.last(page))
      {:ok, %{entries: page, next: next}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp visible_thread_ids(scope) do
    for channel <- Visibility.visible_channels(scope), Channel.thread?(channel), do: channel.id
  end

  # Threads among `thread_ids`, each with its last activity (its newest live message, or its
  # creation), its live reply count and whether `user_id` follows it. Ordered newest activity
  # first, then by id, the order `where_after/2` pages by.
  defp thread_entries_query(thread_ids, user_id) do
    activity =
      from(message in Message,
        where: message.channel_id in ^thread_ids and is_nil(message.deleted_at),
        group_by: message.channel_id,
        select: %{
          channel_id: message.channel_id,
          last_at: max(message.inserted_at),
          reply_count: count(message.id)
        }
      )

    from(thread in Channel,
      as: :thread,
      left_join: activity in subquery(activity),
      as: :activity,
      on: activity.channel_id == thread.id,
      left_join: follower in ThreadFollower,
      on:
        follower.thread_id == thread.id and follower.user_id == ^user_id and
          is_nil(follower.unfollowed_at),
      where: thread.id in ^thread_ids,
      order_by: [desc: coalesce(activity.last_at, thread.inserted_at), desc: thread.id],
      preload: [:parent_channel],
      select: %{
        thread: thread,
        last_activity_at:
          type(coalesce(activity.last_at, thread.inserted_at), :utc_datetime_usec),
        reply_count: coalesce(activity.reply_count, 0),
        following?: not is_nil(follower.id)
      }
    )
  end

  defp where_tab(query, :archived), do: where(query, [thread], not is_nil(thread.archived_at))
  defp where_tab(query, _active), do: where(query, [thread], is_nil(thread.archived_at))

  defp where_title(query, text) when is_binary(text) do
    case String.trim(text) do
      "" -> query
      text -> where(query, [thread], ilike(thread.name, ^"%#{escape_like(text)}%"))
    end
  end

  defp where_title(query, _none), do: query

  defp where_after(query, {%DateTime{} = at, id}) do
    where(
      query,
      [thread, activity],
      coalesce(activity.last_at, thread.inserted_at) < type(^at, :utc_datetime_usec) or
        (coalesce(activity.last_at, thread.inserted_at) == type(^at, :utc_datetime_usec) and
           thread.id < type(^id, :binary_id))
    )
  end

  defp where_after(query, _first_page), do: query

  defp cursor(%{last_activity_at: at, thread: %Channel{id: id}}), do: {at, id}

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")

  defp list_threads_for_channel(channel_ids) do
    Channel
    |> where(
      [channel],
      channel.parent_channel_id in ^channel_ids and channel.kind == :thread_public
    )
    |> order_by([channel], asc: channel.inserted_at, asc: channel.id)
    |> preload([:parent_channel, starter_message: :author])
    |> Repo.all()
  end

  def thread_summaries_for_channel(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id) do
      thread_summaries_for_visible_channel(scope, channel_id)
    else
      :error -> %{}
    end
  end

  defp thread_summaries_for_visible_channel(scope, channel_id) do
    visible = Visibility.visible_channels(scope)
    visible_ids = MapSet.new(Enum.map(visible, & &1.id))

    threads =
      if MapSet.member?(visible_ids, channel_id),
        do:
          list_threads_for_channel([channel_id])
          |> Enum.filter(&MapSet.member?(visible_ids, &1.id)),
        else: []

    thread_ids = Enum.map(threads, & &1.id)

    reply_counts =
      if thread_ids == [] do
        %{}
      else
        from(message in Message,
          where: message.channel_id in ^thread_ids and is_nil(message.deleted_at),
          group_by: message.channel_id,
          select: {message.channel_id, count(message.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    Enum.into(threads, %{}, fn thread ->
      {thread.starter_message_id,
       %{
         thread: thread,
         reply_count: Map.get(reply_counts, thread.id, 0)
       }}
    end)
  end

  def get_thread_for_starter_message(%Scope{} = scope, starter_message_id) do
    with {:ok, starter_message_id} <- Ecto.UUID.cast(starter_message_id),
         %Channel{id: id} <- thread_for_starter(starter_message_id) do
      get_thread(scope, id)
    else
      nil -> nil
      :error -> nil
    end
  end

  def get_thread(%Scope{} = scope, thread_id) do
    with {:ok, thread_id} <- Ecto.UUID.cast(thread_id) do
      case Visibility.visible_channel(scope, thread_id) do
        %Channel{} = thread ->
          if Channel.thread?(thread),
            do: Repo.preload(thread, [:parent_channel, starter_message: :author]),
            else: nil

        nil ->
          nil
      end
    else
      :error -> nil
    end
  end

  def create_public_thread(%Scope{} = scope, starter_message_id, attrs \\ %{}) do
    with {:ok, starter_message_id} <- Ecto.UUID.cast(starter_message_id) do
      result =
        Repo.transact(fn ->
          with :ok <-
                 Visibility.authorize_write(scope, :create_public_threads, %Message{
                   id: starter_message_id
                 }),
               parent_id when is_binary(parent_id) <- message_channel_id(starter_message_id),
               %Channel{} = parent <- Channels.lock_channel(parent_id),
               %Message{} = starter <- Chat.lock_live_message(starter_message_id),
               :ok <- validate_thread_host(parent, starter) do
            case thread_for_starter(starter.id) do
              nil -> insert_thread(scope, parent, starter, attrs)
              existing -> existing_thread(scope, existing.id)
            end
          else
            nil -> {:error, :not_found}
            error -> error
          end
        end)

      case result do
        {:ok, %Channel{} = thread} ->
          Topics.broadcast_server({:channel_created, thread})
          {:ok, thread}

        other ->
          other
      end
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Archives a thread. Its creator or a member with `manage_messages` in its parent channel may; a
  locked thread takes it from the latter only. Refusals: `{:error, :not_found}` for a thread the
  scope cannot view, `{:error, :forbidden}` otherwise.
  """
  def archive_thread(%Scope{} = scope, thread_id),
    do: set_thread_state(scope, thread_id, :archive_thread, archived_at: DateTime.utc_now())

  @doc "Unarchives a thread, by the same rule as `archive_thread/2`."
  def unarchive_thread(%Scope{} = scope, thread_id),
    do: set_thread_state(scope, thread_id, :unarchive_thread, archived_at: nil)

  @doc "Locks a thread. Only a member with `manage_messages` in its parent channel may."
  def lock_thread(%Scope{} = scope, thread_id),
    do: set_thread_state(scope, thread_id, :lock_thread, locked_at: DateTime.utc_now())

  @doc "Unlocks a thread, by the same rule as `lock_thread/2`."
  def unlock_thread(%Scope{} = scope, thread_id),
    do: set_thread_state(scope, thread_id, :unlock_thread, locked_at: nil)

  defp set_thread_state(scope, thread_id, action, changes) do
    with {:ok, thread_id} <- Ecto.UUID.cast(thread_id) do
      result =
        Repo.transact(fn ->
          with :ok <- Visibility.authorize_write(scope, action, %Channel{id: thread_id}),
               %Channel{} = thread <- Channels.lock_channel(thread_id),
               {:ok, thread} <- thread |> Ecto.Changeset.change(changes) |> Repo.update() do
            {:ok, Repo.preload(thread, [:parent_channel, starter_message: :author])}
          else
            nil -> {:error, :not_found}
            error -> error
          end
        end)

      with {:ok, thread} <- result do
        Topics.broadcast_server({:channel_updated, thread})
        {:ok, thread}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp invalid_thread_changeset(parent_channel, starter_message, message) do
    starter_message
    |> new_thread(parent_channel, starter_message.author_id)
    |> Channel.thread_changeset(%{})
    |> Ecto.Changeset.add_error(:starter_message_id, message)
  end

  # Everything but the name comes from the starter message and its channel, so a client cannot
  # choose a thread's kind, parent, starter message or creator.
  defp new_thread(starter_message, parent_channel, creator_id) do
    %Channel{
      kind: :thread_public,
      name: thread_name_from_message(starter_message),
      slug: "thread-#{Ecto.UUID.generate()}",
      position: next_thread_position(parent_channel.id),
      parent_channel_id: parent_channel.id,
      starter_message_id: starter_message.id,
      created_by_id: creator_id
    }
  end

  defp thread_name_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, "name", Map.get(attrs, :name)) do
      name when is_binary(name) and name != "" -> %{"name" => name}
      _blank -> %{}
    end
  end

  defp thread_name_attrs(_attrs), do: %{}

  defp thread_name_from_message(%Message{body: body}) do
    body
    |> String.trim()
    |> case do
      "" -> "Thread"
      value -> String.slice(value, 0, 40)
    end
  end

  defp insert_thread(scope, parent, starter, attrs) do
    with {:ok, thread} <-
           starter
           |> new_thread(parent, scope.user_id)
           |> Channel.thread_changeset(thread_name_attrs(attrs))
           |> Repo.insert(),
         :ok <- Channels.ensure_channel_memberships(scope, [thread]),
         :ok <- ThreadFollows.follow_created(thread, scope.user_id) do
      {:ok, Repo.preload(thread, [:parent_channel, starter_message: :author])}
    end
  end

  # A starter that already has a thread answers with that thread, when the scope can view it.
  defp existing_thread(scope, thread_id) do
    case get_thread(scope, thread_id) do
      %Channel{} = thread -> {:ok, thread}
      nil -> {:error, :not_found}
    end
  end

  defp validate_thread_host(parent, starter) do
    if Channel.thread_host?(parent),
      do: :ok,
      else:
        {:error,
         invalid_thread_changeset(
           parent,
           starter,
           "threads can only start from text-like channels"
         )}
  end

  # A message never changes channel, so this read needs no lock. The starter itself is locked after
  # its channel, in the order the design fixes (scoped-reads.md, "Consistency").
  defp message_channel_id(message_id) do
    Repo.one(
      from(message in Message, where: message.id == ^message_id, select: message.channel_id)
    )
  end

  defp thread_for_starter(starter_id) do
    Repo.one(
      from(channel in Channel,
        where: channel.starter_message_id == ^starter_id and channel.kind == :thread_public
      )
    )
  end

  defp next_thread_position(parent_channel_id) do
    from(channel in Channel,
      where: channel.parent_channel_id == ^parent_channel_id and channel.kind == :thread_public,
      select: max(channel.position)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end
end
