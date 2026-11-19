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

  test "a deleted starter leaves the channel page but not its thread", ctx do
    starter = message_fixture(ctx.channel, ctx.author, %{body: "starter"})
    thread = thread_fixture(ctx.channel, starter, ctx.author)
    {:ok, _} = Chat.delete_message(ctx.scope, starter.id)

    assert {:ok, []} = Chat.list_messages(ctx.scope, ctx.channel.id)

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
end
