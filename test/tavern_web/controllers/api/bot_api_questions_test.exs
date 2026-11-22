defmodule TavernWeb.API.BotApiQuestionsTest do
  @moduledoc """
  Questions through the bot API: a bot sends a poll or a prompt (an ask or a permission request)
  with its own option labels, reads its results and closes it, and receives `question.answered`
  (which options and what Other text) and `question.closed` on its event stream. A prompt closes
  on its first answer.
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
    owner = owner_fixture(%{email: "question-owner@example.com", username: "question_owner"})
    role = role_fixture(%{permissions: PermissionBits.combine(@speaker)})
    channel = channel_fixture(%{name: "Agent Channel", slug: unique_slug()})
    bot = bot_fixture(owner, %{"role_ids" => [role.id]})

    {:ok, %{token: token}} =
      Bots.create_bot_token(scope_for(owner), bot.id, %{"label" => "agent"})

    %{owner: owner, channel: channel, bot: bot, token: token}
  end

  describe "POST /channels/:channel_id/questions" do
    test "sends a permission request with the bot's labels and option kinds", ctx do
      conn =
        ctx.token
        |> api()
        |> post(~p"/api/v1/channels/#{ctx.channel.id}/questions", %{
          question: permission_request(ctx.owner)
        })

      assert %{"data" => %{"body" => "Allow `rm -rf build`?", "question" => question}} =
               json_response(conn, 201)

      assert question["kind"] == "permission"

      assert Enum.map(question["options"], &{&1["label"], &1["kind"]}) == [
               {"once", "allow_once"},
               {"always", "allow_always"},
               {"reject", "reject"}
             ]

      assert question["answerer_user_ids"] == [ctx.owner.id]
      assert question["max_answers"] == 1
      assert question["allow_other"]
      refute question["closed"]
    end

    test "sends a poll by default", ctx do
      conn =
        ctx.token
        |> api()
        |> post(~p"/api/v1/channels/#{ctx.channel.id}/questions", %{
          question: %{question: "Lunch?", options: [%{label: "soup"}, %{label: "salad"}]}
        })

      assert %{"data" => %{"question" => %{"kind" => "poll", "max_answers" => nil}}} =
               json_response(conn, 201)
    end

    test "refuses one option, and a poll-only field on a prompt, with the errors", ctx do
      for question <- [
            %{question: "Yes?", options: [%{label: "yes"}]},
            %{
              kind: "ask",
              question: "Yes?",
              options: [%{label: "a"}, %{label: "b"}],
              anonymous: true
            }
          ] do
        conn =
          ctx.token
          |> api()
          |> post(~p"/api/v1/channels/#{ctx.channel.id}/questions", %{question: question})

        assert %{"error" => %{"code" => "invalid_question"}} = json_response(conn, 422)
      end
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
        |> post(~p"/api/v1/channels/#{hidden.id}/questions", %{
          question: %{question: "Q", options: [%{label: "a"}, %{label: "b"}]}
        })

      assert json_response(conn, 404)
    end
  end

  describe "GET /messages/:message_id/question and POST .../question/close" do
    test "reads the Other answer that closed a prompt, then refuses a second close", ctx do
      message = bot_permission_request(ctx)
      [once | _] = message.question.options

      {:ok, _} =
        Chat.answer_question(scope_for(ctx.owner), message.id, %{
          "option_ids" => [],
          "other_text" => "only in CI"
        })

      shown = ctx.token |> api() |> get(~p"/api/v1/messages/#{message.id}/question")
      assert %{"data" => %{"question" => question}} = json_response(shown, 200)
      assert question["closed"]

      assert question["other"]["answers"] == [
               %{"text" => "only in CI", "user_id" => ctx.owner.id}
             ]

      assert Enum.find(question["options"], &(&1["id"] == once.id))["count"] == 0

      closed = ctx.token |> api() |> post(~p"/api/v1/messages/#{message.id}/question/close")
      assert %{"error" => %{"code" => "question_closed"}} = json_response(closed, 409)
    end

    test "the bot closes its own open question", ctx do
      message = bot_permission_request(ctx)

      conn = ctx.token |> api() |> post(~p"/api/v1/messages/#{message.id}/question/close")
      assert %{"data" => %{"question" => %{"closed" => true}}} = json_response(conn, 200)
    end

    test "a message without a question is not found", ctx do
      message = message_fixture(ctx.channel, ctx.owner, %{body: "plain"})

      conn = ctx.token |> api() |> get(~p"/api/v1/messages/#{message.id}/question")
      assert json_response(conn, 404)
    end
  end

  describe "events" do
    test "an answer arrives as question.answered with the option, then question.closed", ctx do
      message = bot_permission_request(ctx)
      [_once, always, _reject] = message.question.options
      {conn, ref} = Phoenix.ConnTest.build_conn() |> TestStreamAdapter.wrap()
      conn = assign(conn, :current_bot_scope, bot_scope(ctx))

      task = Task.async(fn -> catch_exit(BotController.events(conn, %{})) end)
      assert_receive {:plug_conn, :sent}
      assert_receive {^ref, :chunk, _ready}

      {:ok, _} =
        Chat.answer_question(scope_for(ctx.owner), message.id, %{"option_ids" => [always.id]})

      assert_receive {^ref, :chunk, answered_chunk}
      assert_receive {^ref, :chunk, closed_chunk}
      Task.shutdown(task, :brutal_kill)

      assert answered_chunk =~ "event: question.answered\n"
      answered = payload(answered_chunk)
      assert answered["message_id"] == message.id

      assert answered["answer"] == %{
               "user_id" => ctx.owner.id,
               "option_ids" => [always.id],
               "options" => [%{"id" => always.id, "label" => "always", "kind" => "allow_always"}],
               "other_text" => nil
             }

      assert closed_chunk =~ "event: question.closed\n"

      assert %{"reason" => "answered", "question" => %{"closed" => true}} =
               payload(closed_chunk)
    end

    test "an anonymous poll's answer carries counts and no answerer", ctx do
      {:ok, message} =
        Chat.create_question(bot_scope(ctx), ctx.channel.id, %{
          "question" => "Lunch?",
          "options" => [%{"label" => "soup"}, %{"label" => "salad"}],
          "anonymous" => true
        })

      [soup, _salad] = message.question.options

      {:ok, answered} =
        Chat.answer_question(scope_for(ctx.owner), message.id, %{"option_ids" => [soup.id]})

      payload =
        Bots.serialize_question_answer(answered, %{user_id: ctx.owner.id, option_ids: [soup.id]})

      assert payload.answer == nil
      assert [%{count: 1, answerer_ids: nil}, %{count: 0}] = payload.question.options
    end
  end

  defp api(token) do
    Phoenix.ConnTest.build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end

  defp permission_request(answerer) do
    %{
      kind: "permission",
      question: "Allow `rm -rf build`?",
      options: [
        %{label: "once", kind: "allow_once"},
        %{label: "always", kind: "allow_always"},
        %{label: "reject", kind: "reject"}
      ],
      allow_other: true,
      answerer_user_ids: [answerer.id]
    }
  end

  defp bot_permission_request(ctx) do
    {:ok, message} =
      Chat.create_question(
        bot_scope(ctx),
        ctx.channel.id,
        ctx.owner |> permission_request() |> Jason.encode!() |> Jason.decode!()
      )

    message
  end

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
