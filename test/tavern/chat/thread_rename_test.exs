defmodule Tavern.Chat.ThreadRenameTest do
  @moduledoc """
  Renaming a thread: its creator or a `manage_messages` holder may, a locked thread takes it from
  the latter only, the tags follow the title, and the change is audited and broadcast.
  """
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.Channel
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Topics
  alias Tavern.Repo

  @member_bits [:view_channel, :send_messages, :send_messages_in_threads, :create_public_threads]

  setup do
    _owner = owner_fixture()
    member_role = role_fixture(%{permissions: PermissionBits.combine(@member_bits)})

    moderator_role =
      role_fixture(%{permissions: PermissionBits.combine([:manage_messages | @member_bits])})

    [creator, member, moderator] = for _ <- 1..3, do: user_fixture()
    member_role_fixture(creator, member_role)
    member_role_fixture(member, member_role)
    member_role_fixture(moderator, moderator_role)

    channel = channel_fixture(%{})
    starter = message_fixture(channel, moderator, %{body: "starter #plan"})
    thread = thread_fixture(channel, starter, creator)

    %{thread: thread, creator: creator, member: member, moderator: moderator}
  end

  test "a thread stores no name until someone names it, and views show its starter", ctx do
    assert ctx.thread.name == nil
    assert Channel.title(Repo.preload(ctx.thread, :starter_message)) == "starter #plan"
    assert ctx.thread.hashtags == ["plan"]
  end

  test "a bot may name a thread as it starts it, and that name is stored", ctx do
    starter =
      message_fixture(Repo.get!(Channel, ctx.thread.parent_channel_id), ctx.moderator, %{
        body: "second"
      })

    named = thread_fixture(nil, starter, ctx.creator, %{name: "Named at birth"})

    assert named.name == "Named at birth"
  end

  test "the title search finds an unnamed thread by its starter and a named one by its name",
       ctx do
    channel = Repo.get!(Channel, ctx.thread.parent_channel_id)
    starter = message_fixture(channel, ctx.moderator, %{body: "zebra crossing"})
    thread_fixture(channel, starter, ctx.creator)
    {:ok, _} = Chat.rename_thread(scope_for(ctx.creator), ctx.thread.id, "Giraffe plan")

    titles = fn query ->
      {:ok, %{entries: entries}} =
        Chat.browse_threads(scope_for(ctx.creator), channel.id, query: query)

      Enum.map(entries, &Channel.title(&1.thread))
    end

    assert titles.("zebra") == ["zebra crossing"]
    assert titles.("giraffe") == ["Giraffe plan"]
    assert titles.("starter") == []
  end

  test "the creator renames the thread, and the tags follow the new title", ctx do
    assert {:ok, thread} =
             Chat.rename_thread(scope_for(ctx.creator), ctx.thread.id, "  Launch #ops ")

    assert thread.name == "Launch #ops"
    assert thread.hashtags == ["ops", "plan"]
    assert Repo.reload!(ctx.thread).name == "Launch #ops"
  end

  test "a manager renames a thread they did not start", ctx do
    assert {:ok, %{name: "Renamed"}} =
             Chat.rename_thread(scope_for(ctx.moderator), ctx.thread.id, "Renamed")
  end

  test "another member is refused", ctx do
    assert {:error, :forbidden} =
             Chat.rename_thread(scope_for(ctx.member), ctx.thread.id, "Renamed")

    assert Repo.reload!(ctx.thread).name == ctx.thread.name
  end

  test "a locked thread takes a rename from a manager only", ctx do
    {:ok, _} = Chat.lock_thread(scope_for(ctx.moderator), ctx.thread.id)

    assert {:error, :forbidden} =
             Chat.rename_thread(scope_for(ctx.creator), ctx.thread.id, "Renamed")

    assert {:ok, %{name: "Renamed"}} =
             Chat.rename_thread(scope_for(ctx.moderator), ctx.thread.id, "Renamed")
  end

  test "a channel is not a thread, and an unknown id is not found", ctx do
    channel = Repo.get!(Tavern.Chat.Channel, ctx.thread.parent_channel_id)

    assert {:error, :forbidden} =
             Chat.rename_thread(scope_for(ctx.moderator), channel.id, "Renamed")

    assert {:error, :not_found} =
             Chat.rename_thread(scope_for(ctx.moderator), Ecto.UUID.generate(), "Renamed")

    assert {:error, :not_found} = Chat.rename_thread(scope_for(ctx.moderator), "nope", "Renamed")
  end

  test "a blank or over-long title is refused and changes nothing", ctx do
    scope = scope_for(ctx.creator)

    assert {:error, %Ecto.Changeset{}} = Chat.rename_thread(scope, ctx.thread.id, "   ")

    assert {:error, %Ecto.Changeset{}} =
             Chat.rename_thread(scope, ctx.thread.id, String.duplicate("a", 41))

    assert Repo.reload!(ctx.thread).name == ctx.thread.name
    refute Repo.get_by(AuditLogEntry, channel_id: ctx.thread.id)
  end

  test "records the old and new title, and broadcasts the thread", ctx do
    Topics.subscribe_server()
    old_name = Channel.title(Repo.preload(ctx.thread, :starter_message))

    assert {:ok, _} = rename_elsewhere(scope_for(ctx.creator), ctx.thread.id, "Renamed")

    thread_id = ctx.thread.id
    assert_receive {:channel_updated, %{id: ^thread_id, name: "Renamed"}}

    assert %AuditLogEntry{action_type: "thread_renamed", metadata: meta, actor_user_id: actor} =
             Repo.get_by!(AuditLogEntry, channel_id: thread_id)

    assert actor == ctx.creator.id
    assert %{"old_name" => ^old_name, "new_name" => "Renamed"} = meta
  end

  test "the same title writes and broadcasts nothing", ctx do
    assert {:ok, _} = Chat.rename_thread(scope_for(ctx.creator), ctx.thread.id, "Fixed")
    Repo.delete_all(AuditLogEntry)
    Topics.subscribe_server()

    assert {:ok, _} = rename_elsewhere(scope_for(ctx.creator), ctx.thread.id, "Fixed")

    refute_receive {:channel_updated, _}, 50
    refute Repo.get_by(AuditLogEntry, channel_id: ctx.thread.id)
  end

  # A broadcast skips the process that makes it, so the test renames from another process.
  defp rename_elsewhere(scope, thread_id, name) do
    Task.async(fn -> Chat.rename_thread(scope, thread_id, name) end) |> Task.await()
  end
end
