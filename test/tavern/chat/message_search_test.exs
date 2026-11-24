defmodule Tavern.Chat.MessageSearchTest do
  @moduledoc """
  `Chat.search_messages/3` finds listed messages by word prefixes, newest first, only in channels
  and threads the scope may view.
  """
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Accounts.Scope
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits

  setup do
    owner = owner_fixture(%{email: "search-owner@example.com", username: "search_owner"})
    member = user_fixture(%{email: "search-member@example.com", username: "search_member"})

    viewer =
      role_fixture(%{
        name: "Search viewer",
        permissions:
          PermissionBits.combine([:view_channel, :send_messages, :create_public_threads])
      })

    member_role_fixture(member, viewer)

    open = channel_fixture(%{name: "Open", slug: unique_slug()})
    hidden = channel_fixture(%{name: "Hidden", slug: unique_slug()})

    channel_permission_overwrite_fixture(hidden, %{
      role_id: viewer.id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    %{owner: owner, member: member, scope: %Scope{user_id: member.id}, open: open, hidden: hidden}
  end

  defp found(scope, query, opts \\ []) do
    {:ok, %{messages: messages}} = Chat.search_messages(scope, query, opts)
    Enum.map(messages, & &1.body)
  end

  test "every word must start a word of the text, in any case", ctx do
    message_fixture(ctx.open, ctx.owner, %{body: "Deploying the Kraken tonight"})
    message_fixture(ctx.open, ctx.owner, %{body: "kraken sighting"})

    assert found(ctx.scope, "depl KRAK") == ["Deploying the Kraken tonight"]
    assert found(ctx.scope, "kraken") == ["kraken sighting", "Deploying the Kraken tonight"]
    assert found(ctx.scope, "raken") == []
  end

  test "punctuation is ignored and a query without words finds nothing", ctx do
    message_fixture(ctx.open, ctx.owner, %{body: "it's done"})

    assert found(ctx.scope, "it's & (done) | !") == ["it's done"]
    assert found(ctx.scope, " &|!:* ") == []
  end

  test "a hidden channel and a thread under it give no hits", ctx do
    starter = message_fixture(ctx.hidden, ctx.owner, %{body: "hidden starter"})
    thread = thread_fixture(ctx.hidden, starter, ctx.owner)
    message_fixture(thread, ctx.owner, %{body: "hidden reply"})

    assert found(ctx.scope, "hidden") == []
    assert found(%Scope{user_id: ctx.owner.id}, "hidden") == ["hidden reply", "hidden starter"]
  end

  test "a reply in a visible thread is found, with its thread as its channel", ctx do
    starter = message_fixture(ctx.open, ctx.owner, %{body: "starter"})
    thread = thread_fixture(ctx.open, starter, ctx.owner)
    message_fixture(thread, ctx.owner, %{body: "threaded needle"})

    {:ok, %{messages: [hit]}} = Chat.search_messages(ctx.scope, "needle")
    assert hit.channel.id == thread.id
  end

  test "a deleted message is not found, and an edited one matches only its new text", ctx do
    gone = message_fixture(ctx.open, ctx.owner, %{body: "vanishing words"})
    edited = message_fixture(ctx.open, ctx.owner, %{body: "first draft"})

    {:ok, _} = Chat.delete_message(%Scope{user_id: ctx.owner.id}, gone.id)

    {:ok, _} =
      Chat.update_message(%Scope{user_id: ctx.owner.id}, edited.id, %{body: "final copy"})

    assert found(ctx.scope, "vanishing") == []
    assert found(ctx.scope, "draft") == []
    assert found(ctx.scope, "final") == ["final copy"]
  end

  test "pages run newest first and end with a nil cursor", ctx do
    for n <- 1..5, do: message_fixture(ctx.open, ctx.owner, %{body: "paged #{n}"})

    {:ok, first} = Chat.search_messages(ctx.scope, "paged", limit: 2)
    assert Enum.map(first.messages, & &1.body) == ["paged 5", "paged 4"]

    {:ok, second} = Chat.search_messages(ctx.scope, "paged", limit: 2, after: first.next)
    {:ok, last} = Chat.search_messages(ctx.scope, "paged", limit: 2, after: second.next)
    assert Enum.map(second.messages, & &1.body) == ["paged 3", "paged 2"]
    assert Enum.map(last.messages, & &1.body) == ["paged 1"]
    assert last.next == nil

    assert found(ctx.scope, "paged", after: "not a cursor") == []
  end
end
