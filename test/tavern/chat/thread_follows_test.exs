defmodule Tavern.Chat.ThreadFollowsTest do
  @moduledoc """
  Who follows a thread: its creator, its posters and the members it names, until they unfollow by
  hand. The sidebar and browser reads return only threads the scope may view.
  """
  use Tavern.DataCase, async: false

  import Ecto.Changeset, only: [change: 2]
  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.ThreadFollower
  alias Tavern.Repo

  @member_bits [
    :view_channel,
    :send_messages,
    :send_messages_in_threads,
    :create_public_threads
  ]

  setup do
    _owner = owner_fixture()
    role = role_fixture(%{permissions: PermissionBits.combine(@member_bits)})
    [creator, poster, bystander] = for _ <- 1..3, do: user_fixture()
    Enum.each([creator, poster, bystander], &member_role_fixture(&1, role))

    channel = channel_fixture(%{})
    starter = message_fixture(channel, creator, %{body: "starter"})
    thread = thread_fixture(channel, starter, creator)

    %{channel: channel, thread: thread, creator: creator, poster: poster, bystander: bystander}
  end

  describe "follow sources" do
    test "the creator follows the thread they create", ctx do
      assert source(ctx.thread, ctx.creator) == :created
      assert Chat.following_thread?(scope_for(ctx.creator), ctx.thread.id)
      refute Chat.following_thread?(scope_for(ctx.bystander), ctx.thread.id)
    end

    test "posting in a thread follows it", ctx do
      message_fixture(ctx.thread, ctx.poster, %{body: "a reply"})

      assert source(ctx.thread, ctx.poster) == :posted
      assert Chat.following_thread?(scope_for(ctx.poster), ctx.thread.id)
    end

    test "a direct mention follows the named member", ctx do
      message_fixture(ctx.thread, ctx.poster, %{body: "hey @#{ctx.bystander.username}"})

      assert source(ctx.thread, ctx.bystander) == :mentioned
    end

    test "a mention does not follow a member who may not view the thread", ctx do
      hide_channel(ctx.channel, ctx.bystander)
      message_fixture(ctx.thread, ctx.poster, %{body: "hey @#{ctx.bystander.username}"})

      assert source(ctx.thread, ctx.bystander) == nil
    end

    test "a message outside a thread follows nothing", ctx do
      message_fixture(ctx.channel, ctx.poster, %{body: "plain channel message"})

      assert Repo.aggregate(ThreadFollower, :count) == 1
    end
  end

  describe "manual follow and unfollow" do
    test "an unfollow survives a later post and mention", ctx do
      poster = scope_for(ctx.poster)
      message_fixture(ctx.thread, ctx.poster, %{body: "first"})

      assert :ok = Chat.unfollow_thread(poster, ctx.thread.id)
      refute Chat.following_thread?(poster, ctx.thread.id)

      message_fixture(ctx.thread, ctx.poster, %{body: "second"})
      message_fixture(ctx.thread, ctx.creator, %{body: "ping @#{ctx.poster.username}"})

      refute Chat.following_thread?(poster, ctx.thread.id)
      assert %ThreadFollower{source: :posted} = row(ctx.thread, ctx.poster)
    end

    test "follow clears an unfollow and records a manual follow", ctx do
      creator = scope_for(ctx.creator)
      assert :ok = Chat.unfollow_thread(creator, ctx.thread.id)
      assert :ok = Chat.follow_thread(creator, ctx.thread.id)

      assert Chat.following_thread?(creator, ctx.thread.id)
      assert source(ctx.thread, ctx.creator) == :manual
    end

    test "an unfollow with no row yet is stored, so a later post does not follow", ctx do
      bystander = scope_for(ctx.bystander)
      assert :ok = Chat.unfollow_thread(bystander, ctx.thread.id)

      message_fixture(ctx.thread, ctx.bystander, %{body: "drive-by"})

      refute Chat.following_thread?(bystander, ctx.thread.id)
    end

    test "a thread the scope may not view refuses follow and unfollow as not found", ctx do
      hide_channel(ctx.channel, ctx.bystander)
      bystander = scope_for(ctx.bystander)

      assert {:error, :not_found} = Chat.follow_thread(bystander, ctx.thread.id)
      assert {:error, :not_found} = Chat.unfollow_thread(bystander, ctx.thread.id)
      assert {:error, :not_found} = Chat.follow_thread(bystander, ctx.channel.id)
      assert {:error, :not_found} = Chat.follow_thread(bystander, "not-a-uuid")
      assert row(ctx.thread, ctx.bystander) == nil
    end
  end

  describe "followed_threads/1" do
    test "lists followed, unarchived threads, newest activity first", ctx do
      creator = scope_for(ctx.creator)
      older = ctx.thread
      newer = new_thread(ctx.channel, ctx.creator, "newer", 10)
      archived = new_thread(ctx.channel, ctx.creator, "archived", 20)
      {:ok, _} = Chat.archive_thread(creator, archived.id)

      assert ids(Chat.followed_threads(creator)) == [newer.id, older.id]

      older
      |> message_fixture(ctx.poster, %{body: "bump"})
      |> change(inserted_at: DateTime.add(DateTime.utc_now(), 30, :second))
      |> Repo.update!()

      assert [%{thread: %{id: id}, reply_count: 1, following?: true} | _] =
               Chat.followed_threads(creator)

      assert id == older.id
    end

    test "leaves out unfollowed threads", ctx do
      creator = scope_for(ctx.creator)
      :ok = Chat.unfollow_thread(creator, ctx.thread.id)

      assert Chat.followed_threads(creator) == []
    end

    test "leaves out a followed thread the scope can no longer view", ctx do
      message_fixture(ctx.thread, ctx.poster, %{body: "followed"})
      hide_channel(ctx.channel, ctx.poster)

      assert Chat.followed_threads(scope_for(ctx.poster)) == []
      refute Chat.following_thread?(scope_for(ctx.poster), ctx.thread.id)
    end
  end

  describe "browse_threads/3" do
    test "splits active and archived threads and searches titles", ctx do
      creator = scope_for(ctx.creator)
      tavern = new_thread(ctx.channel, ctx.creator, "Tavern lore", 10)
      archived = new_thread(ctx.channel, ctx.creator, "Old tavern menu", 20)
      {:ok, _} = Chat.archive_thread(creator, archived.id)

      {:ok, active} = Chat.browse_threads(creator, ctx.channel.id, tab: :active)
      assert ids(active.entries) == [tavern.id, ctx.thread.id]

      {:ok, old} = Chat.browse_threads(creator, ctx.channel.id, tab: :archived)
      assert ids(old.entries) == [archived.id]

      {:ok, found} = Chat.browse_threads(creator, ctx.channel.id, tab: :active, query: "LORE")
      assert ids(found.entries) == [tavern.id]

      {:ok, none} = Chat.browse_threads(creator, ctx.channel.id, query: "100%")
      assert none.entries == []
    end

    test "reports follow state per thread", ctx do
      {:ok, page} = Chat.browse_threads(scope_for(ctx.bystander), ctx.channel.id)
      assert [%{following?: false}] = page.entries

      {:ok, page} = Chat.browse_threads(scope_for(ctx.creator), ctx.channel.id)
      assert [%{following?: true, reply_count: 0}] = page.entries
    end

    test "pages archived threads by last activity", ctx do
      creator = scope_for(ctx.creator)

      archived =
        for n <- 1..27 do
          thread = new_thread(ctx.channel, ctx.creator, "archived #{n}", n)
          {:ok, _} = Chat.archive_thread(creator, thread.id)
          thread
        end

      {:ok, first} = Chat.browse_threads(creator, ctx.channel.id, tab: :archived)
      assert length(first.entries) == 25
      assert first.next

      {:ok, second} =
        Chat.browse_threads(creator, ctx.channel.id, tab: :archived, after: first.next)

      assert length(second.entries) == 2
      assert second.next == nil

      assert ids(first.entries) ++ ids(second.entries) ==
               archived |> Enum.reverse() |> Enum.map(& &1.id)
    end

    test "a channel the scope may not view is not found", ctx do
      hide_channel(ctx.channel, ctx.bystander)

      assert {:error, :not_found} = Chat.browse_threads(scope_for(ctx.bystander), ctx.channel.id)
      assert {:error, :not_found} = Chat.browse_threads(scope_for(ctx.creator), ctx.thread.id)
    end
  end

  # The thread's creation is moved `seconds` ahead, so threads made in one test order by it.
  defp new_thread(channel, author, body, seconds) do
    starter = message_fixture(channel, author, %{body: body})
    thread = thread_fixture(channel, starter, author)
    at = DateTime.add(DateTime.utc_now(), seconds, :second)
    thread |> change(inserted_at: at) |> Repo.update!()
  end

  defp hide_channel(channel, user) do
    channel_permission_overwrite_fixture(channel, %{
      user_id: user.id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })
  end

  defp row(thread, user), do: Repo.get_by(ThreadFollower, thread_id: thread.id, user_id: user.id)

  defp source(thread, user) do
    case row(thread, user) do
      nil -> nil
      follower -> follower.source
    end
  end

  defp ids(entries), do: Enum.map(entries, & &1.thread.id)
end
