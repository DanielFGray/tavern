defmodule TavernWeb.API.BotApiReactionsTest do
  @moduledoc """
  Reactions through the bot API: `reaction.added` and `reaction.removed` say who reacted with
  what, only for channels the bot can view, and a serialized message carries a `reactions` summary.
  """
  use TavernWeb.ConnCase

  import Tavern.ChatFixtures

  alias Tavern.Bots
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias TavernWeb.API.BotController
  alias TavernWeb.TestStreamAdapter

  setup do
    owner = owner_fixture(%{email: "react-owner@example.com", username: "react_owner"})
    role = role_fixture(%{permissions: PermissionBits.combine([:view_channel, :send_messages])})
    channel = channel_fixture(%{name: "React", slug: unique_slug()})
    bot = bot_fixture(owner, %{"role_ids" => [role.id]})
    {:ok, %{token: token}} = Bots.create_bot_token(bot, %{"label" => "react"}, owner)
    {:ok, scope} = Bots.get_bot_scope_by_token(token)

    %{owner: owner, channel: channel, bot: bot, scope: scope}
  end

  describe "events" do
    test "a unicode reaction arrives as reaction.added, then reaction.removed", ctx do
      message = message_fixture(ctx.channel, ctx.owner, %{body: "stop"})
      {task, ref} = open_stream(ctx.scope)

      {:ok, _} = Chat.toggle_reaction(scope_for(ctx.owner), message.id, "🛑")
      {:ok, _} = Chat.toggle_reaction(scope_for(ctx.owner), message.id, "🛑")

      added_chunk = receive_event(ref, "reaction.added")
      removed_chunk = receive_event(ref, "reaction.removed")
      Task.shutdown(task, :brutal_kill)

      assert added_chunk =~ "event: reaction.added\n"

      assert payload(added_chunk) == %{
               "message_id" => message.id,
               "channel_id" => ctx.channel.id,
               "user_id" => ctx.owner.id,
               "emoji" => "🛑"
             }

      assert removed_chunk =~ "event: reaction.removed\n"
      assert payload(removed_chunk)["emoji"] == "🛑"
      assert payload(removed_chunk)["user_id"] == ctx.owner.id
    end

    test "a custom emoji arrives with its id and name, on add and on remove", ctx do
      emoji = emoji_fixture(ctx.owner, %{name: "stopsign"})
      message = message_fixture(ctx.channel, ctx.owner, %{body: "stop"})
      {task, ref} = open_stream(ctx.scope)

      {:ok, _} = Chat.toggle_reaction(scope_for(ctx.owner), message.id, %{"emoji_id" => emoji.id})
      {:ok, _} = Chat.toggle_reaction(scope_for(ctx.owner), message.id, %{"emoji_id" => emoji.id})

      added_chunk = receive_event(ref, "reaction.added")
      removed_chunk = receive_event(ref, "reaction.removed")
      Task.shutdown(task, :brutal_kill)

      expected = %{"id" => emoji.id, "name" => "stopsign"}
      assert added_chunk =~ "event: reaction.added\n"
      assert payload(added_chunk)["emoji"] == expected
      assert removed_chunk =~ "event: reaction.removed\n"
      assert payload(removed_chunk)["emoji"] == expected
    end

    test "a reaction in a channel the bot cannot view is not sent", ctx do
      hidden = channel_fixture(%{name: "Hidden", slug: unique_slug()})

      channel_permission_overwrite_fixture(hidden, %{
        user_id: ctx.bot.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      {:ok, scope} = fresh_scope(ctx)
      hidden_message = message_fixture(hidden, ctx.owner, %{body: "secret"})
      visible_message = message_fixture(ctx.channel, ctx.owner, %{body: "open"})
      {task, ref} = open_stream(scope)

      {:ok, _} = Chat.toggle_reaction(scope_for(ctx.owner), hidden_message.id, "🛑")
      {:ok, _} = Chat.toggle_reaction(scope_for(ctx.owner), visible_message.id, "👍")

      chunk = receive_event(ref, "reaction.added")
      Task.shutdown(task, :brutal_kill)

      assert chunk =~ "event: reaction.added\n"
      assert payload(chunk)["message_id"] == visible_message.id
    end
  end

  describe "message reactions summary" do
    test "counts each emoji without voters, in first-used order", ctx do
      emoji = emoji_fixture(ctx.owner, %{name: "blobby"})
      other = owner_fixture(%{email: "react-other@example.com", username: "react_other"})
      message = message_fixture(ctx.channel, ctx.owner, %{body: "tally"})

      {:ok, _} = Chat.toggle_reaction(scope_for(ctx.owner), message.id, "👍")
      {:ok, _} = Chat.toggle_reaction(scope_for(ctx.owner), message.id, %{"emoji_id" => emoji.id})
      {:ok, _} = Chat.toggle_reaction(scope_for(other), message.id, "👍")

      serialized = Bots.serialize_message(Chat.get_message(ctx.scope, message.id))

      assert serialized.reactions == [
               %{emoji: "👍", count: 2},
               %{emoji: %{id: emoji.id, name: "blobby"}, count: 1}
             ]
    end

    test "a message with no reactions has an empty list", ctx do
      message = message_fixture(ctx.channel, ctx.owner, %{body: "quiet"})
      serialized = Bots.serialize_message(Chat.get_message(ctx.scope, message.id))
      assert serialized.reactions == []
    end
  end

  defp open_stream(scope) do
    {conn, ref} = Phoenix.ConnTest.build_conn() |> TestStreamAdapter.wrap()
    conn = assign(conn, :current_bot_scope, scope)

    task = Task.async(fn -> catch_exit(BotController.events(conn, %{})) end)
    assert_receive {:plug_conn, :sent}
    assert_receive {^ref, :chunk, _ready}
    {task, ref}
  end

  # A toggle sends `message.updated` first, so skip chunks until the named event.
  defp receive_event(ref, name) do
    assert_receive {^ref, :chunk, chunk}
    if chunk =~ "event: #{name}\n", do: chunk, else: receive_event(ref, name)
  end

  defp fresh_scope(ctx) do
    {:ok, %{token: token}} = Bots.create_bot_token(ctx.bot, %{"label" => "fresh"}, ctx.owner)
    Bots.get_bot_scope_by_token(token)
  end

  defp payload(chunk) do
    [_, json] = Regex.run(~r/data: (.*)\n\n/, chunk)
    Jason.decode!(json)
  end
end
