defmodule TavernWeb.API.BotApiPollsTest do
  @moduledoc """
  Polls through the bot API: a bot sends a poll with its own option labels, reads its results and
  ends it, and receives `poll.voted` (which options and what Other text) and `poll.closed` on its
  event stream. An agent question is a poll with one named voter that closes after one vote.
  """
  use TavernWeb.ConnCase

  import Tavern.ChatFixtures

  alias Tavern.Bots
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias TavernWeb.API.BotController
  alias TavernWeb.TestStreamAdapter

  @speaker [:view_channel, :send_messages, :send_messages_in_threads, :create_public_threads]

  setup do
    owner = owner_fixture(%{email: "poll-owner@example.com", username: "poll_owner"})
    role = role_fixture(%{permissions: PermissionBits.combine(@speaker)})
    channel = channel_fixture(%{name: "Agent Channel", slug: unique_slug()})
    bot = bot_fixture(owner, %{"role_ids" => [role.id]})

    {:ok, %{token: token}} =
      Bots.create_bot_token(scope_for(owner), bot.id, %{"label" => "agent"})

    %{owner: owner, channel: channel, bot: bot, token: token}
  end

  describe "POST /channels/:channel_id/polls" do
    test "sends a poll with the bot's own labels, narrowed voters and a vote limit", ctx do
      conn =
        ctx.token
        |> api()
        |> post(~p"/api/v1/channels/#{ctx.channel.id}/polls", %{
          poll: agent_question(ctx.owner)
        })

      assert %{"data" => %{"body" => "Allow `rm -rf build`?", "poll" => poll}} =
               json_response(conn, 201)

      assert Enum.map(poll["options"], & &1["label"]) == ["once", "always", "reject"]
      assert poll["voter_user_ids"] == [ctx.owner.id]
      assert poll["max_voters"] == 1
      assert poll["allow_other"]
      refute poll["closed"]
    end

    test "refuses one option with the changeset's errors", ctx do
      conn =
        ctx.token
        |> api()
        |> post(~p"/api/v1/channels/#{ctx.channel.id}/polls", %{
          poll: %{question: "Yes?", options: ["yes"]}
        })

      assert %{"error" => %{"code" => "invalid_poll"}} = json_response(conn, 422)
    end

    test "a channel the bot may not see is not found", ctx do
      hidden = channel_fixture(%{name: "Hidden", slug: unique_slug()})

      channel_permission_overwrite_fixture(hidden, %{
        user_id: ctx.bot.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      conn =
        ctx.token
        |> api()
        |> post(~p"/api/v1/channels/#{hidden.id}/polls", %{
          poll: %{question: "Q", options: ["a", "b"]}
        })

      assert json_response(conn, 404)
    end
  end

  describe "GET /messages/:message_id/poll and POST .../poll/close" do
    test "reads the votes with option and Other text, then ends the poll", ctx do
      message = bot_poll(ctx)
      [once | _] = message.poll.options

      {:ok, _} =
        Chat.vote_in_poll(scope_for(ctx.owner), message.id, %{
          "option_ids" => [],
          "other_text" => "only in CI"
        })

      shown = ctx.token |> api() |> get(~p"/api/v1/messages/#{message.id}/poll")
      assert %{"data" => %{"poll" => poll}} = json_response(shown, 200)
      assert poll["closed"]
      assert poll["other"]["answers"] == [%{"text" => "only in CI", "user_id" => ctx.owner.id}]
      assert Enum.find(poll["options"], &(&1["id"] == once.id))["count"] == 0

      closed = ctx.token |> api() |> post(~p"/api/v1/messages/#{message.id}/poll/close")
      assert %{"error" => %{"code" => "poll_closed"}} = json_response(closed, 409)
    end

    test "the bot ends its own open poll", ctx do
      {:ok, message} =
        Chat.create_poll(bot_scope(ctx), ctx.channel.id, %{
          "question" => "Q",
          "options" => ~w(a b)
        })

      conn = ctx.token |> api() |> post(~p"/api/v1/messages/#{message.id}/poll/close")
      assert %{"data" => %{"poll" => %{"closed" => true}}} = json_response(conn, 200)
    end

    test "a message without a poll is not found", ctx do
      message = message_fixture(ctx.channel, ctx.owner, %{body: "plain"})

      conn = ctx.token |> api() |> get(~p"/api/v1/messages/#{message.id}/poll")
      assert json_response(conn, 404)
    end
  end

  describe "events" do
    test "a vote arrives as poll.voted with the option label, then poll.closed", ctx do
      message = bot_poll(ctx)
      [_once, always, _reject] = message.poll.options
      {conn, ref} = Phoenix.ConnTest.build_conn() |> TestStreamAdapter.wrap()
      conn = assign(conn, :current_bot_scope, bot_scope(ctx))

      task = Task.async(fn -> catch_exit(BotController.events(conn, %{})) end)
      assert_receive {:plug_conn, :sent}
      assert_receive {^ref, :chunk, _ready}

      {:ok, _} =
        Chat.vote_in_poll(scope_for(ctx.owner), message.id, %{"option_ids" => [always.id]})

      assert_receive {^ref, :chunk, voted_chunk}
      assert_receive {^ref, :chunk, closed_chunk}
      Task.shutdown(task, :brutal_kill)

      assert voted_chunk =~ "event: poll.voted\n"
      voted = payload(voted_chunk)
      assert voted["message_id"] == message.id

      assert voted["vote"] == %{
               "user_id" => ctx.owner.id,
               "option_ids" => [always.id],
               "options" => [%{"id" => always.id, "label" => "always"}],
               "other_text" => nil
             }

      assert closed_chunk =~ "event: poll.closed\n"
      assert %{"reason" => "max_voters", "poll" => %{"closed" => true}} = payload(closed_chunk)
    end

    test "an anonymous poll's vote carries counts and no voter", ctx do
      {:ok, message} =
        Chat.create_poll(bot_scope(ctx), ctx.channel.id, %{
          "question" => "Lunch?",
          "options" => ~w(soup salad),
          "anonymous" => true
        })

      [soup, _salad] = message.poll.options

      {:ok, voted} =
        Chat.vote_in_poll(scope_for(ctx.owner), message.id, %{"option_ids" => [soup.id]})

      payload = Bots.serialize_poll_vote(voted, %{user_id: ctx.owner.id, option_ids: [soup.id]})
      assert payload.vote == nil
      assert [%{count: 1, voter_ids: nil}, %{count: 0}] = payload.poll.options
    end
  end

  defp api(token) do
    Phoenix.ConnTest.build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end

  defp agent_question(voter) do
    %{
      question: "Allow `rm -rf build`?",
      options: ["once", "always", "reject"],
      allow_other: true,
      voter_user_ids: [voter.id],
      max_voters: 1
    }
  end

  defp bot_poll(ctx) do
    {:ok, message} =
      Chat.create_poll(bot_scope(ctx), ctx.channel.id, stringify(agent_question(ctx.owner)))

    message
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp payload(chunk) do
    [_, json] = Regex.run(~r/data: (.*)\n\n/, chunk)
    Jason.decode!(json)
  end

  defp bot_scope(ctx) do
    {:ok, %{token: token}} =
      Bots.create_bot_token(scope_for(ctx.owner), ctx.bot.id, %{"label" => "scope"})

    {:ok, scope} = Bots.get_bot_scope_by_token(token)
    scope
  end
end
