defmodule Tavern.Chat.ForumsTest do
  @moduledoc """
  Forum posts: a post is a thread whose first message lives inside it. Posts carry the #tags of
  their title and first message, and list by activity or creation with a tag and title search.
  """
  use Tavern.DataCase, async: false

  import Ecto.Changeset, only: [change: 2]
  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.Channel
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  @member_bits [
    :view_channel,
    :send_messages,
    :send_messages_in_threads,
    :create_public_threads,
    :add_reactions
  ]

  setup do
    owner = owner_fixture()
    role = role_fixture(%{permissions: PermissionBits.combine(@member_bits)})
    [author, reader] = for _ <- 1..2, do: user_fixture()
    Enum.each([author, reader], &member_role_fixture(&1, role))

    forum = channel_fixture(%{name: "Help", kind: :forum})
    %{forum: forum, owner: owner, author: author, reader: reader}
  end

  describe "create_post/3" do
    test "makes a thread under the forum whose starter is its first message", ctx do
      {:ok, post} =
        Chat.create_forum_post(scope_for(ctx.author), ctx.forum.id, %{
          "title" => "Cannot log in #Auth",
          "body" => "It fails on #mobile and #auth"
        })

      assert post.kind == :thread_public
      assert post.parent_channel_id == ctx.forum.id
      assert post.name == "Cannot log in #Auth"
      assert post.hashtags == ["auth", "mobile"]
      assert post.starter_message.channel_id == post.id
      assert post.starter_message.body == "It fails on #mobile and #auth"
      assert Chat.following_thread?(scope_for(ctx.author), post.id)
    end

    test "refuses a blank title or body with a changeset", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Chat.create_forum_post(scope_for(ctx.author), ctx.forum.id, %{
                 "title" => " ",
                 "body" => ""
               })

      assert %{title: [_], body: [_]} = errors_on(changeset)
    end

    test "needs the right to create public threads in the forum", ctx do
      channel_permission_overwrite_fixture(ctx.forum, %{
        user_id: ctx.author.id,
        deny_permissions: PermissionBits.combine([:create_public_threads])
      })

      assert {:error, :forbidden} = new_post(ctx.forum, ctx.author, "Nope")
    end

    test "needs the right to send messages in the forum", ctx do
      channel_permission_overwrite_fixture(ctx.forum, %{
        user_id: ctx.author.id,
        deny_permissions: PermissionBits.combine([:send_messages])
      })

      assert {:error, :forbidden} = new_post(ctx.forum, ctx.author, "Nope")
    end

    test "a hidden forum and a channel that is not a forum are not found", ctx do
      hide_channel(ctx.forum, ctx.author)
      assert {:error, :not_found} = new_post(ctx.forum, ctx.author, "Hidden")

      text = channel_fixture(%{})
      assert {:error, :not_found} = new_post(text, ctx.reader, "Wrong kind")
    end

    test "the forum's slowmode spaces a member's posts", ctx do
      ctx.forum |> change(slowmode_seconds: 60) |> Repo.update!()

      assert {:ok, _post} = new_post(ctx.forum, ctx.author, "First")
      assert {:error, {:slowmode, _seconds}} = new_post(ctx.forum, ctx.author, "Second")
      assert {:ok, _post} = new_post(ctx.forum, ctx.reader, "Someone else")
    end
  end

  test "a forum takes no top-level message", ctx do
    assert {:error, :forbidden} =
             Chat.create_message(scope_for(ctx.author), ctx.forum.id, %{body: "hello"})

    assert {:error, :forbidden} =
             Chat.create_message(scope_for(ctx.owner), ctx.forum.id, %{body: "hello"})

    refute Chat.channel_abilities(scope_for(ctx.author), ctx.forum.id).send_messages
  end

  test "replies count without the first message, and replies are allowed", ctx do
    {:ok, post} = new_post(ctx.forum, ctx.author, "Replies")
    message_fixture(post, ctx.reader, %{body: "a reply"})

    {:ok, page} = Chat.list_forum_posts(scope_for(ctx.reader), ctx.forum.id)
    assert [%{reply_count: 1}] = page.entries
  end

  test "editing the first message takes the tags again", ctx do
    {:ok, post} = new_post(ctx.forum, ctx.author, "Edit me", "about #old")

    {:ok, _message} =
      Chat.update_message(scope_for(ctx.author), post.starter_message_id, %{body: "now #new"})

    assert Repo.get!(Channel, post.id).hashtags == ["new"]
  end

  describe "list_forum_posts/3" do
    test "filters by exact tag and searches titles by word", ctx do
      {:ok, bug} = new_post(ctx.forum, ctx.author, "Crash on start", "#bug")
      {:ok, bugs} = new_post(ctx.forum, ctx.author, "Crash in settings", "#bugs")
      {:ok, idea} = new_post(ctx.forum, ctx.author, "Dark theme", "#idea")
      scope = scope_for(ctx.reader)

      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, query: "#BUG")) == [bug.id]
      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, query: "crash")) == [bugs.id, bug.id]

      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, query: "#bugs settings")) ==
               [bugs.id]

      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, query: "theme")) == [idea.id]
    end

    test "sorts by latest activity or by creation", ctx do
      {:ok, older} = new_post(ctx.forum, ctx.author, "Older")
      {:ok, newer} = new_post(ctx.forum, ctx.author, "Newer")
      age(older, -60)
      age(newer, -30)
      message_fixture(older, ctx.reader, %{body: "bump"})
      scope = scope_for(ctx.reader)

      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, sort: :activity)) ==
               [older.id, newer.id]

      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, sort: :created)) ==
               [newer.id, older.id]
    end

    test "pages by creation with the cursor of that sort", ctx do
      posts =
        for n <- 1..27 do
          {:ok, post} = new_post(ctx.forum, ctx.author, "post #{n}")
          age(post, n - 100)
        end

      scope = scope_for(ctx.reader)
      {:ok, first} = Chat.list_forum_posts(scope, ctx.forum.id, sort: :created)

      {:ok, second} =
        Chat.list_forum_posts(scope, ctx.forum.id, sort: :created, after: first.next)

      assert Enum.map(first.entries ++ second.entries, & &1.thread.id) ==
               posts |> Enum.reverse() |> Enum.map(& &1.id)
    end

    test "shows the first message's author and top reaction", ctx do
      {:ok, post} = new_post(ctx.forum, ctx.author, "Reacted")
      scope = scope_for(ctx.reader)
      {:ok, _} = Chat.toggle_reaction(scope_for(ctx.author), post.starter_message_id, "👍")
      {:ok, _} = Chat.toggle_reaction(scope, post.starter_message_id, "🔥")
      {:ok, _} = Chat.toggle_reaction(scope, post.starter_message_id, "👍")

      {:ok, %{entries: [entry]}} = Chat.list_forum_posts(scope, ctx.forum.id)
      assert entry.starter.author.id == ctx.author.id
      assert %{emoji_unicode: "👍", count: 2} = entry.top_reaction
      assert entry.image_url == nil
    end

    test "lists only posts the scope may view", ctx do
      {:ok, open} = new_post(ctx.forum, ctx.author, "Open")
      {:ok, hidden} = new_post(ctx.forum, ctx.author, "Hidden")
      hide_channel(hidden, ctx.reader)

      assert ids(Chat.list_forum_posts(scope_for(ctx.reader), ctx.forum.id)) == [open.id]

      hide_channel(ctx.forum, ctx.reader)
      assert {:error, :not_found} = Chat.list_forum_posts(scope_for(ctx.reader), ctx.forum.id)
    end

    test "lists active posts by default and archived posts on the archived tab", ctx do
      {:ok, open} = new_post(ctx.forum, ctx.author, "Open")
      {:ok, archived} = new_post(ctx.forum, ctx.author, "Closed")
      {:ok, _} = Chat.archive_thread(scope_for(ctx.author), archived.id)
      scope = scope_for(ctx.reader)

      assert ids(Chat.list_forum_posts(scope, ctx.forum.id)) == [open.id]
      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, tab: :active)) == [open.id]
      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, tab: :archived)) == [archived.id]
    end

    test "searches within the selected tab", ctx do
      {:ok, _open} = new_post(ctx.forum, ctx.author, "Crash open")
      {:ok, archived} = new_post(ctx.forum, ctx.author, "Crash closed")
      {:ok, _} = Chat.archive_thread(scope_for(ctx.author), archived.id)
      scope = scope_for(ctx.reader)

      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, tab: :archived, query: "crash")) ==
               [archived.id]

      assert ids(Chat.list_forum_posts(scope, ctx.forum.id, tab: :archived, query: "open")) == []
    end

    test "keeps a post whose first message was deleted, with no starter", ctx do
      {:ok, post} = new_post(ctx.forum, ctx.author, "Orphaned")
      {:ok, _} = Chat.delete_message(scope_for(ctx.author), post.starter_message_id)

      assert {:ok, %{entries: [%{thread: %{id: id}, starter: nil}]}} =
               Chat.list_forum_posts(scope_for(ctx.reader), ctx.forum.id)

      assert id == post.id
    end
  end

  describe "post view" do
    test "is remembered per member and forum", ctx do
      scope = scope_for(ctx.reader)
      assert Chat.forum_post_view(scope, ctx.forum.id) == %{sort: :activity, layout: :list}

      assert {:ok, %{sort: :created, layout: :list}} =
               Chat.set_forum_post_view(scope, ctx.forum.id, %{"sort" => "created"})

      assert {:ok, %{sort: :created, layout: :gallery}} =
               Chat.set_forum_post_view(scope, ctx.forum.id, %{"layout" => "gallery"})

      assert Chat.forum_post_view(scope_for(ctx.author), ctx.forum.id) ==
               %{sort: :activity, layout: :list}
    end

    test "refuses an unknown value and a channel that is not a visible forum", ctx do
      scope = scope_for(ctx.reader)

      assert {:error, %Ecto.Changeset{}} =
               Chat.set_forum_post_view(scope, ctx.forum.id, %{"sort" => "votes"})

      hide_channel(ctx.forum, ctx.reader)
      assert {:error, :not_found} = Chat.set_forum_post_view(scope, ctx.forum.id, %{})
    end
  end

  defp new_post(forum, author, title, body \\ "first message") do
    Chat.create_forum_post(scope_for(author), forum.id, %{"title" => title, "body" => body})
  end

  # Moves a post's creation `seconds` from now, so posts made in one test order by it.
  defp age(post, seconds) do
    post
    |> change(inserted_at: DateTime.add(DateTime.utc_now(), seconds, :second))
    |> Repo.update!()
  end

  defp hide_channel(channel, user) do
    channel_permission_overwrite_fixture(channel, %{
      user_id: user.id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })
  end

  defp ids({:ok, page}), do: Enum.map(page.entries, & &1.thread.id)
end
