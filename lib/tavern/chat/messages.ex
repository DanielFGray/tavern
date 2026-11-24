defmodule Tavern.Chat.Messages do
  @moduledoc """
  Messages and their reactions: reading a channel's messages, and the writes that send, edit,
  delete and react to one. Every write decides through `Tavern.Chat.Visibility` inside its own
  transaction and broadcasts after the commit.

  `send_message/4`, `write_message/3` and `publish_message/1` are the seams the other message
  writers (questions, forum posts) build on. The row access they share with the embed and thread
  writes is `Tavern.Chat.MessageRows`, below this module.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Attachments
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Channels
  alias Tavern.Chat.Embeds
  alias Tavern.Chat.Emojis
  alias Tavern.Chat.Ids
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.Mentions
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageRows
  alias Tavern.Chat.Question
  alias Tavern.Chat.Reaction
  alias Tavern.Chat.SendLimit
  alias Tavern.Chat.Slowmode
  alias Tavern.Chat.ThreadFollows
  alias Tavern.Chat.Threads
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Ephemeral
  alias Tavern.Repo

  # What a message read needs to render and serialize. The channel is not here: a read sets it from
  # the decision that allowed the read, so it costs no query.
  @read_preloads [
    :user_mentions,
    author: :avatar_asset,
    role_mentions: :mentioned_role,
    reactions: [emoji: :asset],
    reply_to: :author,
    embeds: :image_asset,
    attachments: :asset,
    question: [:options, answers: :user]
  ]

  def change_message(message, attrs \\ %{}) do
    Message.changeset(message, attrs)
  end

  # --- Reads -------------------------------------------------------------------------------------

  @doc """
  A page of up to `:limit` messages (default 50) in a channel the scope may view, oldest first,
  as `{:ok, messages}`. Without a cursor it is the newest page. `after: message_id` is the page
  that starts just after that message; `before: message_id` is the page that ends just before
  it. A cursor names a message of this channel, deleted or not, or the call is
  `{:error, :invalid_cursor}`; both cursors at once are `{:error, :invalid_cursor}` too. A
  missing channel and a hidden one are both `{:error, :not_found}`. A deleted message is listed
  only as the tombstone of a thread it starts (`Message.where_transcript/1`).
  """
  def list_messages(%Scope{} = scope, channel_id, opts \\ []) do
    with {:ok, channel_id} <- Ids.cast(channel_id),
         %Channel{} = channel <- Visibility.visible_channel(scope, channel_id) do
      with {:ok, cursor} <- message_cursor(channel_id, opts) do
        limit = Keyword.get(opts, :limit, 50)

        messages =
          Message
          |> where([message], message.channel_id == ^channel_id)
          |> Message.where_transcript()
          |> page_from(cursor)
          |> limit(^limit)
          |> preload(^@read_preloads)
          |> Repo.all()
          |> chronological(cursor)
          |> Enum.map(&%{&1 | channel: channel})

        {:ok, messages}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The message with `message_id`, when the scope may view its channel, or nil. A hidden message and
  a missing one both give nil.
  """
  def get_message(%Scope{} = scope, message_id) do
    with {:ok, message_id} <- Ids.cast(message_id),
         %Message{} = message <- Visibility.visible_message(scope, message_id) do
      Repo.preload(message, @read_preloads)
    else
      _ -> nil
    end
  end

  @doc """
  The messages among `message_ids` that the scope may view, in the order given. Hidden, missing and
  malformed ids are left out. Each distinct channel is decided once, and the preloads run once for
  the whole list.
  """
  def get_messages(%Scope{} = scope, message_ids) do
    ids =
      message_ids
      |> Enum.flat_map(fn id ->
        case Ids.cast(id) do
          {:ok, id} -> [id]
          {:error, _} -> []
        end
      end)
      |> Enum.uniq()

    # An `in` over an empty list still runs a query, and callers often pass only nil ids.
    case ids do
      [] -> []
      ids -> visible_messages(scope, ids)
    end
  end

  @doc "The number of listed messages (`Message.listed?/1`) in a channel the scope may view. A hidden channel counts 0, as a missing one does."
  def message_count(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ids.cast(channel_id),
         true <- Visibility.can?(scope, :view_channel, %Channel{id: channel_id}) do
      Message
      |> where([message], message.channel_id == ^channel_id)
      |> Message.where_listed()
      |> Repo.aggregate(:count)
    else
      _ -> 0
    end
  end

  # --- Sending -----------------------------------------------------------------------------------

  @doc """
  Creates a message in a channel or thread the scope may send to, and broadcasts it. The message
  comes back with its write preloads (`MessageRows.reload_message/1`), the same shape the broadcast carries. A channel the scope
  may not view is `{:error, :not_found}`; a visible one it may not send to is `{:error,
  :forbidden}`. A send refused by slowmode is `{:error, {:slowmode, seconds}}`, and one over the
  member's send limit is `{:error, {:rate_limited, seconds}}`.

  `uploads` are files to attach (`Tavern.Chat.Attachments.prepare/2`). Attaching needs
  `attach_files` here, or the send is `{:error, :attach_files_forbidden}`; a message with
  attachments may have an empty body.
  """
  def create_message(%Scope{} = scope, channel_id, attrs, uploads \\ []),
    do: send_message(scope, channel_id, attrs, &{:ok, &1}, uploads)

  @doc """
  Sends a message under every send rule of `create_message/4`, then runs `extend` on what
  `write_message/4` wrote, inside the same transaction. `extend` returns `{:ok, written}`, with
  the message reloaded when it added rows to it. A question (`Tavern.Chat.Questions`) is a
  message extended with its question rows.
  """
  def send_message(%Scope{} = scope, channel_id, attrs, extend, uploads \\ []) do
    with {:ok, channel_id} <- Ids.cast(channel_id),
         {:ok, attrs} <- normalize_attrs(attrs),
         {:ok, attachments} <- Attachments.prepare(scope, uploads) do
      Repo.transact(fn ->
        with :ok <- Visibility.authorize_write(scope, :send_messages, %Channel{id: channel_id}),
             :ok <- authorize_attachments(scope, channel_id, attachments),
             {:ok, reopened} <- enforce_channel_state(scope, channel_id),
             {:ok, written} <- write_message(scope, channel_id, attrs, attachments),
             {:ok, written} <- extend.(written) do
          {:ok, {written, reopened}}
        end
      end)
      |> case do
        {:ok, {written, reopened}} ->
          result = publish_message(written)
          # After the message events: a session reloads its sidebar on the reopen, and that reload
          # must already include the message, or the message would be counted twice.
          if reopened, do: Topics.broadcast_server({:channel_updated, reopened})
          result

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Inserts a message the caller has authorized, with its mentions, the follows it makes and its
  `attachments` (built by `Tavern.Chat.Attachments.prepare/2`, attaching already authorized).
  `attrs` have string keys and a decoded `"metadata"` map, as `normalize_attrs/1` returns them.
  Runs inside the caller's transaction; `publish_message/1` takes the result after the commit.
  `create_message/4` and a forum post's first message (`Tavern.Chat.Forums`) share it, so the
  member's send limit (`Tavern.Chat.SendLimit`) is counted here, before any other query: over it,
  the write is `{:error, {:rate_limited, seconds}}`. The attachments' bytes go to the object
  store last, so a refusal stores nothing.
  """
  def write_message(%Scope{} = scope, channel_id, attrs, attachments \\ []) do
    with :ok <- SendLimit.admit(scope.user_id),
         :ok <- validate_reply_target(channel_id, attrs),
         :ok <- Mentions.authorize(scope, channel_id, attrs),
         {:ok, message} <-
           %Message{channel_id: channel_id, author_id: scope.user_id}
           |> Message.create_changeset(attrs, attachments)
           |> Repo.insert(),
         :ok <- Mentions.sync(message),
         {:ok, new_followers} <- ThreadFollows.follow_for_message(message),
         :ok <- Attachments.store_objects(message) do
      {:ok, {MessageRows.reload_message(message.id), new_followers}}
    end
  end

  @doc """
  Broadcasts a message `write_message/3` wrote, once its transaction committed, and fetches its
  link previews.
  """
  def publish_message({%Message{} = message, new_followers}) do
    # A sent message ends its author's typing in that channel, whoever sent it: a bot has no
    # "stop typing" call, and a browser's own stop would race the message.
    _ = Ephemeral.remove_typing(message.channel_id, message.author_id)

    Topics.broadcast_channel(
      message.channel_id,
      {:typing_stopped, message.channel_id, message.author_id}
    )

    broadcast(:message_created, message)
    ThreadFollows.broadcast_message_created(message, new_followers)
    schedule_embeds(message, [])
  end

  # --- Editing, deleting, reacting ---------------------------------------------------------------

  @doc """
  Edits a message the scope authored, and broadcasts it. The edit drops the embeds of links it
  removed and fetches previews only for links it added. Editing a thread's starter message takes
  the thread's tags from it again (`Tavern.Chat.Hashtags`). A message the scope may not view is
  `{:error, :not_found}`. A visible message it may not edit (another author, a timeout, or a
  question, whose text stays as answered) is `{:error, :forbidden}`.
  """
  def update_message(%Scope{} = scope, message_id, attrs) do
    with {:ok, message_id} <- Ids.cast(message_id),
         {:ok, attrs} <- normalize_attrs(attrs) do
      Repo.transact(fn ->
        with {:ok, message} <- authorize_message_write(scope, :edit_message, message_id),
             :ok <- refuse_question_edit(message),
             :ok <- Mentions.authorize(scope, message.channel_id, attrs),
             {:ok, updated_message} <-
               message
               # Loaded so the changeset lets a message with attachments keep an empty body.
               |> Repo.preload(:attachments)
               |> Message.changeset(attrs)
               |> Ecto.Changeset.put_change(:edited_at, DateTime.utc_now())
               |> Repo.update(),
             :ok <- Mentions.sync(updated_message),
             {:ok, retagged} <- Threads.retag_started_thread(updated_message) do
          {embedded_urls, image_keys} = Embeds.prune(updated_message)

          {:ok,
           {MessageRows.reload_message(updated_message.id), embedded_urls, image_keys, retagged}}
        end
      end)
      |> case do
        {:ok, {message, embedded_urls, image_keys, retagged}} ->
          MediaAssets.delete_objects(image_keys)
          broadcast(:message_updated, message)
          # A thread whose tags changed is redrawn wherever it is listed, as for a rename.
          if retagged, do: Topics.broadcast_server({:channel_updated, retagged})
          schedule_embeds(message, embedded_urls)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Removes a message's embeds and keeps them off: a later edit fetches none. The author may remove
  them; `manage_messages` lets anyone else with view remove them. Refusals follow
  `update_message/3`.
  """
  def suppress_embeds(%Scope{} = scope, message_id) do
    write_and_prune_embeds(scope, :suppress_embeds, message_id, :message_updated, fn message ->
      message |> Ecto.Changeset.change(suppress_embeds: true) |> Repo.update()
    end)
  end

  @doc """
  Deletes a message's content, keeping the row, and broadcasts the deletion. The author may
  delete their own message; `manage_messages` lets anyone else with view delete it. Refusals
  follow `update_message/3`.
  """
  def delete_message(%Scope{} = scope, message_id) do
    write_and_prune_embeds(scope, :delete_message, message_id, :message_deleted, fn message ->
      now = DateTime.utc_now()

      with {:ok, deleted_message} <-
             message
             |> Ecto.Changeset.change(body: "[message deleted]", deleted_at: now, edited_at: now)
             |> Repo.update(),
           :ok <- Mentions.clear(deleted_message.id) do
        {:ok, deleted_message}
      end
    end)
    |> retitle_started_thread()
  end

  # A thread's title comes from its starter, so deleting the starter retitles the thread: each
  # view reloads its sidebar, open thread and reply pills on `:channel_updated`.
  defp retitle_started_thread({:ok, %Message{} = message} = result) do
    if thread = Threads.thread_for_starter(message.id),
      do: Topics.broadcast_server({:channel_updated, thread})

    result
  end

  defp retitle_started_thread(error), do: error

  @doc """
  Adds the scope's reaction with this unicode emoji to a message, or removes it when present.
  Refusals follow `update_message/3`. An empty emoji is `{:error, :invalid_emoji}`.
  """
  def toggle_reaction(%Scope{} = scope, message_id, emoji_unicode)
      when is_binary(emoji_unicode) do
    case String.trim(emoji_unicode) do
      "" ->
        {:error, :invalid_emoji}

      emoji_unicode ->
        toggle_reaction_on(scope, message_id, fn -> {:ok, %{emoji_unicode: emoji_unicode}} end)
    end
  end

  # Toggles a reaction with a custom emoji the scope's member may use, by emoji id.
  def toggle_reaction(%Scope{} = scope, message_id, %{"emoji_id" => emoji_id})
      when is_binary(emoji_id) do
    toggle_reaction_on(scope, message_id, fn ->
      with {:ok, emoji} <- Emojis.fetch_available_emoji(scope, emoji_id) do
        {:ok, %{emoji_id: emoji.id}}
      end
    end)
  end

  # --- Reading helpers ---------------------------------------------------------------------------

  defp message_cursor(channel_id, opts) do
    case {Keyword.get(opts, :after), Keyword.get(opts, :before)} do
      {nil, nil} -> {:ok, nil}
      {id, nil} -> find_cursor(:after, channel_id, id)
      {nil, id} -> find_cursor(:before, channel_id, id)
      {_after, _before} -> {:error, :invalid_cursor}
    end
  end

  defp find_cursor(direction, channel_id, message_id) do
    with {:ok, message_id} <- Ids.cast(message_id),
         %Message{} = message <- Repo.get_by(Message, id: message_id, channel_id: channel_id) do
      {:ok, {direction, message.inserted_at, message.id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp page_from(query, nil),
    do: order_by(query, [message], desc: message.inserted_at, desc: message.id)

  defp page_from(query, {:after, inserted_at, id}) do
    query
    |> where(
      [message],
      message.inserted_at > ^inserted_at or
        (message.inserted_at == ^inserted_at and message.id > ^id)
    )
    |> order_by([message], asc: message.inserted_at, asc: message.id)
  end

  defp page_from(query, {:before, inserted_at, id}) do
    query
    |> where(
      [message],
      message.inserted_at < ^inserted_at or
        (message.inserted_at == ^inserted_at and message.id < ^id)
    )
    |> order_by([message], desc: message.inserted_at, desc: message.id)
  end

  # `page_from/2` reads every page except an `after` page newest first, so those rows are turned back.
  defp chronological(messages, {:after, _inserted_at, _id}), do: messages
  defp chronological(messages, _cursor), do: Enum.reverse(messages)

  defp visible_messages(scope, ids) do
    messages = Message |> where([message], message.id in ^ids) |> Repo.all()

    channels =
      messages
      |> Enum.map(& &1.channel_id)
      |> Enum.uniq()
      |> Map.new(&{&1, Visibility.visible_channel(scope, &1)})

    visible_by_id =
      Enum.flat_map(messages, fn message ->
        case Map.get(channels, message.channel_id) do
          nil -> []
          channel -> [{message.id, %{message | channel: channel}}]
        end
      end)
      |> Map.new()

    ids
    |> Enum.flat_map(fn id -> List.wrap(Map.get(visible_by_id, id)) end)
    |> Repo.preload(@read_preloads)
  end

  # --- Send helpers ------------------------------------------------------------------------------

  # Applies the two send rules that depend on the channel row: slowmode, and reopening an archived
  # thread. The row is read first without a lock, so a channel with neither costs no lock. A
  # channel with slowmode or an archived thread is locked `FOR UPDATE`, after the membership lock,
  # so two sends by one author queue behind each other and the second sees the first's message.
  # Returns `{:ok, reopened_thread_or_nil}`.
  defp enforce_channel_state(scope, channel_id) do
    case Repo.get(Channel, channel_id) do
      %Channel{slowmode_seconds: seconds, archived_at: archived_at}
      when seconds > 0 or not is_nil(archived_at) ->
        with %Channel{} = channel <- Channels.lock_channel(channel_id),
             :ok <- Slowmode.enforce(scope, channel, last_message_at(scope, channel)) do
          reopen_archived(channel)
        else
          nil -> {:error, :not_found}
          error -> error
        end

      _ ->
        {:ok, nil}
    end
  end

  defp last_message_at(scope, %Channel{id: channel_id}) do
    from(message in Message,
      where: message.channel_id == ^channel_id and message.author_id == ^scope.user_id,
      select: max(message.inserted_at)
    )
  end

  defp reopen_archived(%Channel{archived_at: nil}), do: {:ok, nil}

  defp reopen_archived(%Channel{} = channel),
    do: channel |> Ecto.Changeset.change(archived_at: nil) |> Repo.update()

  # A reply must name a live message in the same channel. A message elsewhere, a deleted one and a
  # missing one get the same error, so the answer does not reveal a message in a channel the author
  # may not view.
  defp validate_reply_target(channel_id, attrs) do
    case normalize_optional_binary_id(Map.get(attrs, "reply_to_id")) do
      nil ->
        :ok

      reply_to_id ->
        with {:ok, reply_to_id} <- Ecto.UUID.cast(reply_to_id),
             true <-
               Repo.exists?(
                 from(message in Message,
                   where:
                     message.id == ^reply_to_id and message.channel_id == ^channel_id and
                       is_nil(message.deleted_at)
                 )
               ) do
          :ok
        else
          _ ->
            {:error,
             invalid_reply_changeset(attrs, "must reference a message in the same conversation")}
        end
    end
  end

  defp invalid_reply_changeset(attrs, message) do
    %Message{}
    |> Message.changeset(Map.put(attrs, "body", Map.get(attrs, "body", "")))
    |> Ecto.Changeset.add_error(:reply_to_id, message)
  end

  defp normalize_optional_binary_id(nil), do: nil
  defp normalize_optional_binary_id(""), do: nil
  defp normalize_optional_binary_id(value), do: value

  defp normalize_attrs(attrs) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    metadata = Map.get(attrs, "metadata")

    normalized_metadata =
      cond do
        is_map(metadata) -> {:ok, metadata}
        is_binary(metadata) and metadata != "" -> Jason.decode(metadata)
        true -> {:ok, %{}}
      end

    case normalized_metadata do
      {:ok, decoded_metadata} ->
        {:ok, Map.put(attrs, "metadata", stored_metadata(decoded_metadata))}

      {:error, _reason} ->
        {:error, invalid_metadata_changeset(attrs)}
    end
  end

  # The composer also sends its whole editor document, which nothing reads back. Only the
  # mention entities are stored, so a client cannot fill a row with unbounded data.
  defp stored_metadata(%{} = metadata), do: Map.take(metadata, ["entities"])
  defp stored_metadata(_metadata), do: %{}

  defp invalid_metadata_changeset(attrs) do
    %Message{}
    |> Message.changeset(Map.put(attrs, "body", Map.get(attrs, "body", "")))
    |> Ecto.Changeset.add_error(:metadata, "must be valid JSON")
  end

  # --- Write helpers -----------------------------------------------------------------------------

  # A question's body is its text, and answers were given to it, so the message stays as written.
  # Runs inside the edit's transaction, on the locked message.
  defp refuse_question_edit(%Message{id: message_id}) do
    if Repo.exists?(from(question in Question, where: question.message_id == ^message_id)),
      do: {:error, :forbidden},
      else: :ok
  end

  # Decides a message write, then locks the message row and reads it. The lock keeps a moderator's
  # delete from committing between the decision and the change. The row is read again with its
  # deleted_at, so a message deleted after the decision is refused.
  defp authorize_message_write(scope, action, message_id) do
    with :ok <- Visibility.authorize_write(scope, action, %Message{id: message_id}) do
      case MessageRows.lock_live_message(message_id) do
        %Message{} = message -> {:ok, message}
        nil -> {:error, :not_found}
      end
    end
  end

  # Decides `action`, applies `change` to the locked message and drops the embeds the changed
  # message no longer wants, and a deleted message's attachments, in one transaction. Object-store
  # deletes run after the commit, when the rows that named the objects are already gone.
  defp write_and_prune_embeds(scope, action, message_id, event, change) do
    with {:ok, message_id} <- Ids.cast(message_id) do
      Repo.transact(fn ->
        with {:ok, message} <- authorize_message_write(scope, action, message_id),
             {:ok, changed} <- change.(message),
             {:ok, attachment_keys} <- prune_attachments(changed) do
          {_kept, image_keys} = Embeds.prune(changed)
          {:ok, {MessageRows.reload_message(changed.id), image_keys ++ attachment_keys}}
        end
      end)
      |> delete_dropped_images()
      |> broadcast_written(event)
    end
  end

  defp prune_attachments(%Message{deleted_at: nil}), do: {:ok, []}
  defp prune_attachments(%Message{id: id}), do: Attachments.delete_for_message(id)

  defp authorize_attachments(_scope, _channel_id, []), do: :ok

  # The send was allowed just before, so a refusal here is about attaching alone.
  defp authorize_attachments(scope, channel_id, _attachments) do
    case Visibility.authorize_write(scope, :attach_files, %Channel{id: channel_id}) do
      {:error, :forbidden} -> {:error, :attach_files_forbidden}
      result -> result
    end
  end

  defp delete_dropped_images({:ok, {message, image_keys}}) do
    MediaAssets.delete_objects(image_keys)
    {:ok, message}
  end

  defp delete_dropped_images({:error, reason}), do: {:error, reason}

  # Broadcasts a committed message write. The broadcast happens after the commit, so a receiver
  # never reads a message the database does not hold.
  defp broadcast_written({:ok, %Message{} = message}, event) do
    broadcast(event, message)
    {:ok, message}
  end

  defp broadcast_written({:error, reason}, _event), do: {:error, reason}

  # Runs after the broadcast, so the fetch's own broadcast follows the write's.
  defp schedule_embeds(%Message{} = message, embedded_urls) do
    :ok = Embeds.schedule(message, embedded_urls)
    {:ok, message}
  end

  defp broadcast(event, %Message{} = message) do
    Topics.broadcast_channel(message.channel_id, {event, message})
    if event == :message_deleted, do: ThreadFollows.broadcast_message_unlisted(message)
    :ok
  end

  # --- Reaction helpers --------------------------------------------------------------------------

  # The reaction's key (its emoji) is resolved inside the transaction, after the lock, because
  # a custom emoji's availability depends on the member's current roles.
  defp toggle_reaction_on(scope, message_id, emoji_key) do
    with {:ok, message_id} <- Ids.cast(message_id) do
      Repo.transact(fn ->
        with {:ok, message} <- authorize_message_write(scope, :add_reactions, message_id),
             {:ok, key} <- emoji_key.(),
             {:ok, change} <- toggle_reaction_row(message, scope.user_id, key) do
          {:ok, {MessageRows.reload_message(message.id), change}}
        end
      end)
      |> broadcast_reaction()
    end
  end

  # `:message_updated` re-renders open views. `:reaction_added` / `:reaction_removed` tell the bot
  # stream who reacted, which the message alone does not say.
  defp broadcast_reaction({:ok, {%Message{} = message, {event, reaction}}}) do
    broadcast(:message_updated, message)
    Topics.broadcast_channel(message.channel_id, {event, message, reaction})
    {:ok, message}
  end

  defp broadcast_reaction({:error, reason}), do: {:error, reason}

  # The row carries its emoji, so the removal event can name a custom emoji after the row is gone.
  defp toggle_reaction_row(message, user_id, emoji_key) do
    fields = Map.merge(emoji_key, %{message_id: message.id, user_id: user_id})

    case Repo.get_by(Reaction, Map.to_list(fields)) do
      nil ->
        with {:ok, reaction} <- %Reaction{} |> Reaction.changeset(fields) |> Repo.insert(),
             do: {:ok, {:reaction_added, Repo.preload(reaction, :emoji)}}

      reaction ->
        reaction = Repo.preload(reaction, :emoji)
        with {:ok, reaction} <- Repo.delete(reaction), do: {:ok, {:reaction_removed, reaction}}
    end
  end
end
