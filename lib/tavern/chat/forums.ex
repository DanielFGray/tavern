defmodule Tavern.Chat.Forums do
  @moduledoc """
  Forum channels (docs/design/forums.md). A forum holds no message of its own; it holds posts. A
  post is a public thread under the forum whose starter message is the post's first message,
  written inside the post. Following, the sidebar and the thread browser treat a post as any
  other thread.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat
  alias Tavern.Chat.Channel
  alias Tavern.Chat.ChannelMembership
  alias Tavern.Chat.Channels
  alias Tavern.Chat.Emoji
  alias Tavern.Chat.Message
  alias Tavern.Chat.Reaction
  alias Tavern.Chat.ThreadFollows
  alias Tavern.Chat.Threads
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @post_types %{title: :string, body: :string}

  @doc "A changeset for the New post form: a title (a thread name) and a first message."
  def change_post(attrs \\ %{}) do
    {%{}, @post_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@post_types))
    |> Ecto.Changeset.update_change(:title, &String.trim/1)
    |> Ecto.Changeset.update_change(:body, &String.trim/1)
    |> Ecto.Changeset.validate_required([:title, :body])
    |> Ecto.Changeset.validate_length(:title, max: 40)
    |> Ecto.Changeset.validate_length(:body, max: 4000)
  end

  @doc """
  Creates a post in a forum: a public thread named by the title, and its first message, in one
  transaction. It needs what creating a public thread in the forum needs (view, send and create
  public threads, and no timeout), and waits out the forum's slowmode, which counts the member's
  last post there. The creator follows the post.

  Returns `{:ok, thread}`; `{:error, changeset}` for a title or body the form refuses;
  `{:error, {:slowmode, seconds}}`; `{:error, :forbidden}` for a visible forum the scope may not
  post in; `{:error, :not_found}` for a hidden channel, a missing one or one that is not a forum.
  """
  def create_post(%Scope{} = scope, forum_id, attrs) do
    changeset = change_post(attrs)

    with {:ok, forum_id} <- Ecto.UUID.cast(forum_id),
         {:ok, post} <- Ecto.Changeset.apply_action(changeset, :insert) do
      Repo.transact(fn ->
        with :ok <-
               Visibility.authorize_write(scope, :create_public_threads, %Channel{id: forum_id}),
             %Channel{kind: :forum} = forum <- Channels.lock_channel(forum_id),
             :ok <- enforce_post_slowmode(scope, forum),
             {:ok, thread} <- insert_post_thread(scope, forum, post),
             {:ok, {message, _followers} = written} <-
               Chat.write_message(scope, thread.id, %{"body" => post.body, "metadata" => %{}}),
             {:ok, thread} <- start_post(thread, message) do
          {:ok, {thread, written}}
        else
          %Channel{} -> {:error, :not_found}
          nil -> {:error, :not_found}
          error -> error
        end
      end)
      |> case do
        {:ok, {thread, written}} ->
          Topics.broadcast_server({:channel_created, thread})
          Chat.publish_message(written)
          {:ok, thread}

        error ->
          error
      end
    else
      :error -> {:error, :not_found}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  @doc """
  One page of a forum's posts, active and archived, each an entry of `Chat.browse_threads/3` with
  `:starter` (the first message with its author, or nil once deleted), `:top_reaction` (`%{emoji,
  emoji_unicode, count}` or nil) and `:image_url` (the first message's first image, or nil).

  Options: `:sort` (`:activity` or `:created`), `:query` (see `Chat.browse_threads/3`) and
  `:after`. A channel that is not a visible forum is `{:error, :not_found}`.
  """
  def list_posts(%Scope{} = scope, forum_id, opts \\ []) do
    with %Channel{kind: :forum} <- visible_forum(scope, forum_id),
         {:ok, page} <-
           Threads.browse_threads(scope, forum_id, Keyword.put(opts, :tab, :all)) do
      {:ok, %{page | entries: with_post_details(page.entries)}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  How the scope lists a forum's posts: `%{sort: :activity | :created, layout: :list | :gallery}`.
  A member who never chose sees the defaults.
  """
  def post_view(%Scope{} = scope, forum_id) do
    membership =
      with %Channel{kind: :forum} = forum <- visible_forum(scope, forum_id) do
        Repo.get_by(ChannelMembership, channel_id: forum.id, user_id: scope.user_id)
      end

    %ChannelMembership{post_sort: sort, post_layout: layout} = membership || %ChannelMembership{}
    %{sort: sort, layout: layout}
  end

  @doc """
  Remembers how the scope lists a forum's posts. `attrs` may set `:sort` and `:layout`. Returns
  `{:ok, view}` as `post_view/2` reads it, `{:error, changeset}` for an unknown value, or
  `{:error, :not_found}` for a channel that is not a visible forum.
  """
  def set_post_view(%Scope{} = scope, forum_id, attrs) do
    case visible_forum(scope, forum_id) do
      %Channel{kind: :forum} = forum ->
        params =
          for {key, field} <- [sort: :post_sort, layout: :post_layout],
              value = attr(attrs, key),
              into: %{},
              do: {field, value}

        changeset = Ecto.Changeset.cast(%ChannelMembership{}, params, [:post_sort, :post_layout])

        if changeset.valid? do
          upsert_view(scope, forum, changeset.changes)
          {:ok, post_view(scope, forum.id)}
        else
          {:error, changeset}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp visible_forum(scope, forum_id) do
    case Ecto.UUID.cast(forum_id) do
      {:ok, forum_id} -> Visibility.visible_channel(scope, forum_id)
      :error -> nil
    end
  end

  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp upsert_view(scope, forum, changes) do
    now = DateTime.utc_now()
    set = Map.to_list(changes) ++ [updated_at: now]

    Repo.insert_all(
      ChannelMembership,
      [
        Map.merge(changes, %{
          id: Ecto.UUID.generate(),
          channel_id: forum.id,
          user_id: scope.user_id,
          joined_at: now,
          inserted_at: now,
          updated_at: now
        })
      ],
      on_conflict: [set: set],
      conflict_target: [:channel_id, :user_id]
    )
  end

  # The forum's slowmode spaces a member's posts, as a channel's spaces their messages.
  defp enforce_post_slowmode(_scope, %Channel{slowmode_seconds: 0}), do: :ok

  defp enforce_post_slowmode(scope, %Channel{slowmode_seconds: seconds} = forum) do
    last_post_at =
      Repo.one(
        from(post in Channel,
          where: post.parent_channel_id == ^forum.id and post.created_by_id == ^scope.user_id,
          select: max(post.inserted_at)
        )
      )

    left =
      if last_post_at,
        do: seconds - DateTime.diff(DateTime.utc_now(), last_post_at, :millisecond) / 1000,
        else: 0

    cond do
      left <= 0 -> :ok
      Visibility.can?(scope, :bypass_slowmode, forum) -> :ok
      true -> {:error, {:slowmode, ceil(left)}}
    end
  end

  defp insert_post_thread(scope, forum, post) do
    with {:ok, thread} <-
           forum
           |> Threads.new_thread(scope.user_id)
           |> Channel.thread_changeset(%{"name" => post.title})
           |> Repo.insert(),
         :ok <- Channels.ensure_channel_memberships(scope, [thread]),
         :ok <- ThreadFollows.follow_created(thread, scope.user_id) do
      {:ok, thread}
    end
  end

  # The first message is written after the thread it lives in, so the thread takes it as its
  # starter, and its tags, in a second step.
  defp start_post(thread, message) do
    with {:ok, thread} <-
           thread
           |> Ecto.Changeset.change(starter_message_id: message.id)
           |> Threads.put_hashtags(message.body)
           |> Repo.update() do
      {:ok, Repo.preload(thread, [:parent_channel, starter_message: :author])}
    end
  end

  defp with_post_details([]), do: []

  defp with_post_details(entries) do
    starter_ids = for entry <- entries, id = entry.thread.starter_message_id, do: id

    starters =
      from(message in Message,
        where: message.id in ^starter_ids and is_nil(message.deleted_at),
        preload: [:author, embeds: :image_asset]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    top_reactions = top_reactions(starter_ids)

    Enum.map(entries, fn entry ->
      starter = Map.get(starters, entry.thread.starter_message_id)

      Map.merge(entry, %{
        starter: starter,
        top_reaction: starter && Map.get(top_reactions, starter.id),
        image_url: starter && first_image_url(starter)
      })
    end)
  end

  # The reaction most members gave each message, the earliest-used one on a tie.
  defp top_reactions(message_ids) do
    from(reaction in Reaction,
      where: reaction.message_id in ^message_ids,
      group_by: [reaction.message_id, reaction.emoji_id, reaction.emoji_unicode],
      distinct: reaction.message_id,
      order_by: [desc: count(reaction.id), asc: min(reaction.inserted_at)],
      select: %{
        message_id: reaction.message_id,
        emoji_id: reaction.emoji_id,
        emoji_unicode: reaction.emoji_unicode,
        count: count(reaction.id)
      }
    )
    |> Repo.all()
    |> with_emojis()
    |> Map.new(&{&1.message_id, &1})
  end

  defp with_emojis(reactions) do
    emojis =
      case for(reaction <- reactions, id = reaction.emoji_id, do: id) do
        [] -> %{}
        ids -> Repo.all(from(emoji in Emoji, where: emoji.id in ^ids, preload: :asset))
      end
      |> Map.new(&{&1.id, &1})

    Enum.map(reactions, &Map.put(&1, :emoji, Map.get(emojis, &1.emoji_id)))
  end

  # A message's images today are its link previews' images. Attachments are not built yet.
  defp first_image_url(%Message{embeds: embeds}) do
    Enum.find_value(embeds, fn
      %{image_asset: %{} = asset} -> Chat.asset_url(asset)
      _embed -> nil
    end)
  end
end
