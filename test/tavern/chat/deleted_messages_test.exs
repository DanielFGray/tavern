defmodule Tavern.Chat.DeletedMessagesTest do
  @moduledoc """
  A deleted message keeps its row but no list shows it: channel and thread pages leave it out. A
  reply to it still loads its quoted message, so the reply can say the original is gone.
  """
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits

  setup do
    _owner = owner_fixture()

    bits = [:view_channel, :send_messages, :send_messages_in_threads, :create_public_threads]
    role = role_fixture(%{permissions: PermissionBits.combine(bits)})

    author = user_fixture()
    member_role_fixture(author, role)
    %{author: author, scope: scope_for(author), channel: channel_fixture(%{})}
  end

  test "a channel page leaves out deleted messages", ctx do
    keep = message_fixture(ctx.channel, ctx.author, %{body: "keep"})
    gone = message_fixture(ctx.channel, ctx.author, %{body: "gone"})
    {:ok, _} = Chat.delete_message(ctx.scope, gone.id)

    assert {:ok, [%{id: id}]} = Chat.list_messages(ctx.scope, ctx.channel.id)
    assert id == keep.id
  end

  test "a thread page leaves out deleted messages", ctx do
    starter = message_fixture(ctx.channel, ctx.author, %{body: "starter"})
    thread = thread_fixture(ctx.channel, starter, ctx.author)
    keep = message_fixture(thread, ctx.author, %{body: "keep"})
    gone = message_fixture(thread, ctx.author, %{body: "gone"})
    {:ok, _} = Chat.delete_message(ctx.scope, gone.id)

    assert {:ok, [%{id: id}]} = Chat.list_messages(ctx.scope, thread.id)
    assert id == keep.id
  end

  test "a deleted starter stays on the channel page as its thread's tombstone", ctx do
    starter = message_fixture(ctx.channel, ctx.author, %{body: "starter"})
    thread = thread_fixture(ctx.channel, starter, ctx.author)
    {:ok, _} = Chat.delete_message(ctx.scope, starter.id)

    assert {:ok, [%{id: id, deleted_at: %DateTime{}}]} =
             Chat.list_messages(ctx.scope, ctx.channel.id)

    assert id == starter.id

    assert {:ok, %{entries: [%{thread: %{id: thread_id}}]}} =
             Chat.browse_threads(ctx.scope, ctx.channel.id)

    assert thread_id == thread.id
  end

  test "a reply still loads its deleted quoted message", ctx do
    target = message_fixture(ctx.channel, ctx.author, %{body: "quoted"})
    reply = message_fixture(ctx.channel, ctx.author, %{body: "reply", reply_to_id: target.id})
    {:ok, _} = Chat.delete_message(ctx.scope, target.id)

    assert {:ok, [%{id: id, reply_to: quoted}]} = Chat.list_messages(ctx.scope, ctx.channel.id)
    assert id == reply.id
    assert quoted.id == target.id
    assert quoted.deleted_at
  end

  describe "a deleted message takes no further action" do
    setup ctx do
      message = message_fixture(ctx.channel, ctx.author, %{body: "doomed"})
      {:ok, _} = Chat.delete_message(ctx.scope, message.id)
      %{doomed: message}
    end

    test "it cannot be quoted by a new reply", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Chat.create_message(ctx.scope, ctx.channel.id, %{
                 "body" => "late reply",
                 "reply_to_id" => ctx.doomed.id
               })

      assert %{reply_to_id: [_]} = errors_on(changeset)
    end

    test "it cannot start a thread", ctx do
      assert {:error, :not_found} = Chat.create_public_thread(ctx.scope, ctx.doomed.id)
    end

    test "it cannot be edited or reacted to", ctx do
      assert {:error, :not_found} = Chat.update_message(ctx.scope, ctx.doomed.id, %{body: "back"})
      assert {:error, :not_found} = Chat.toggle_reaction(ctx.scope, ctx.doomed.id, "👍")
    end

    test "the channel's message count leaves it out", ctx do
      assert Chat.message_count(ctx.scope, ctx.channel.id) == 0
    end
  end
end
