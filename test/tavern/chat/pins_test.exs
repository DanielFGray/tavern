defmodule Tavern.Chat.PinsTest do
  @moduledoc """
  A member with `pin_messages` pins messages, up to the cap, and each pin posts a pin line. The
  pin line's text is the server's: it takes no edit, pin or thread, and search skips it.
  """
  use Tavern.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Tavern.ChatFixtures

  alias Tavern.Accounts.Scope
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Pins

  setup do
    owner = owner_fixture(%{email: "pins-owner@example.com", username: "pins_owner"})
    pinner = user_fixture(%{email: "pinner@example.com", username: "pinner"})
    reader = user_fixture(%{email: "pin-reader@example.com", username: "pin_reader"})

    member_role_fixture(
      pinner,
      role_fixture(%{
        name: "Pinner",
        permissions: PermissionBits.combine([:view_channel, :send_messages, :pin_messages])
      })
    )

    member_role_fixture(
      reader,
      role_fixture(%{
        name: "Reader",
        permissions: PermissionBits.combine([:view_channel, :send_messages, :manage_messages])
      })
    )

    channel = channel_fixture(%{name: "Pinboard", slug: unique_slug()})

    %{
      owner: owner,
      pinner: %Scope{user_id: pinner.id},
      reader: %Scope{user_id: reader.id},
      channel: channel,
      message: message_fixture(channel, owner, %{body: "remember this"})
    }
  end

  test "pinning sets the pin, posts one pin line, and repeats change nothing", ctx do
    assert {:ok, %{message: pinned, line: line}} = Chat.pin_message(ctx.pinner, ctx.message.id)
    assert pinned.pinned_at
    assert line.reply_to.id == ctx.message.id
    assert {:ok, %{line: nil}} = Chat.pin_message(ctx.pinner, ctx.message.id)

    lines = Repo.all(from m in Tavern.Chat.Message, where: m.kind == :pin)
    assert [%{reply_to_id: reply_to_id, author_id: author_id}] = lines
    assert reply_to_id == ctx.message.id
    assert author_id == ctx.pinner.user_id

    assert {:ok, [listed]} = Chat.list_pins(ctx.reader, ctx.channel.id)
    assert listed.id == ctx.message.id
  end

  test "pinning needs pin_messages; manage_messages alone is not enough", ctx do
    assert {:error, :forbidden} = Chat.pin_message(ctx.reader, ctx.message.id)
    assert {:error, :forbidden} = Chat.unpin_message(ctx.reader, ctx.message.id)
  end

  test "a timed-out member may not pin", ctx do
    Repo.update_all(
      from(membership in Tavern.Chat.Membership,
        where: membership.user_id == ^ctx.pinner.user_id
      ),
      set: [timeout_until: DateTime.add(DateTime.utc_now(), 3600, :second)]
    )

    assert {:error, :forbidden} = Chat.pin_message(ctx.pinner, ctx.message.id)
  end

  test "a hidden channel answers as a missing one", ctx do
    hidden = channel_fixture(%{name: "Hidden", slug: unique_slug()})
    secret = message_fixture(hidden, ctx.owner, %{body: "secret"})

    channel_permission_overwrite_fixture(hidden, %{
      user_id: ctx.pinner.user_id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    assert {:error, :not_found} = Chat.pin_message(ctx.pinner, secret.id)
    assert {:error, :not_found} = Chat.list_pins(ctx.pinner, hidden.id)
  end

  test "unpinning removes the pin and posts nothing", ctx do
    {:ok, _} = Chat.pin_message(ctx.pinner, ctx.message.id)
    assert {:ok, unpinned} = Chat.unpin_message(ctx.pinner, ctx.message.id)
    assert unpinned.pinned_at == nil
    assert {:ok, []} = Chat.list_pins(ctx.reader, ctx.channel.id)
    assert Repo.aggregate(from(m in Tavern.Chat.Message, where: m.kind == :pin), :count) == 1
  end

  test "a conversation holds at most the cap; a deleted pin frees its place", ctx do
    messages =
      for n <- 1..Pins.limit(), do: message_fixture(ctx.channel, ctx.owner, %{body: "m#{n}"})

    for message <- messages, do: {:ok, _} = Chat.pin_message(ctx.pinner, message.id)

    assert {:error, :pin_limit} = Chat.pin_message(ctx.pinner, ctx.message.id)

    {:ok, _} = Chat.delete_message(%Scope{user_id: ctx.owner.id}, hd(messages).id)
    assert {:ok, _} = Chat.pin_message(ctx.pinner, ctx.message.id)
    assert {:ok, pins} = Chat.list_pins(ctx.reader, ctx.channel.id)
    assert length(pins) == Pins.limit()
  end

  test "a pin line takes no edit, pin or thread, and search skips it", ctx do
    {:ok, _} = Chat.pin_message(ctx.pinner, ctx.message.id)
    line = Repo.one!(from m in Tavern.Chat.Message, where: m.kind == :pin)

    assert {:error, :forbidden} = Chat.update_message(ctx.pinner, line.id, %{body: "edited"})
    assert {:error, :forbidden} = Chat.pin_message(ctx.pinner, line.id)

    assert {:error, :forbidden} =
             Chat.create_public_thread(%Scope{user_id: ctx.owner.id}, line.id, %{})

    assert {:ok, %{messages: []}} = Chat.search_messages(ctx.reader, "pinned")
  end
end
