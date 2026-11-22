defmodule Tavern.Chat.QuestionsTest do
  @moduledoc """
  Questions: a message with a question and options. In a poll, members who may send in the
  channel vote, change and withdraw their vote while it is open; a poll closes by hand, at its end
  time or after its vote limit, and may narrow its voters to named members and roles. A bot's
  prompt (an ask or a permission request) closes on its first answer.
  """
  use Tavern.DataCase, async: false

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query
  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.Membership
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Question
  alias Tavern.Chat.Questions
  alias Tavern.Chat.Topics
  alias Tavern.Repo

  @member_bits [
    :view_channel,
    :send_messages,
    :send_messages_in_threads,
    :add_reactions,
    :create_public_threads
  ]

  setup do
    owner = owner_fixture()
    member_role = role_fixture(%{permissions: PermissionBits.combine(@member_bits)})

    moderator_role =
      role_fixture(%{permissions: PermissionBits.combine([:manage_messages | @member_bits])})

    [author, voter, other_voter, moderator] = for _ <- 1..4, do: user_fixture()
    Enum.each([author, voter, other_voter], &member_role_fixture(&1, member_role))
    member_role_fixture(moderator, moderator_role)

    bot = bot_fixture(owner, %{"role_ids" => [member_role.id]})

    {:ok, %{bot_token: bot_token}} =
      Tavern.Bots.create_bot_token(scope_for(owner), bot.id, %{"label" => "agent"})

    %{
      channel: channel_fixture(%{}),
      bot_scope: %Tavern.Accounts.Scope{user_id: bot.id, bot_token_id: bot_token.id},
      author: author,
      voter: voter,
      other_voter: other_voter,
      moderator: moderator,
      member_role: member_role
    }
  end

  describe "create_question/3 for a poll" do
    test "sends a message whose body is the question, with its options in order", ctx do
      {:ok, message} = new_poll(ctx, %{"options" => [" Red ", "Blue", "", "blue"]})

      assert message.body == "Which colour?"
      assert message.question.closes_at == nil
      assert Enum.map(message.question.options, & &1.label) == ["Red", "Blue"]
      assert [%{id: id}] = Chat.list_messages(scope_for(ctx.voter), ctx.channel.id) |> elem(1)
      assert id == message.id
    end

    test "refuses fewer than 2 or more than 10 options and a duration out of range", ctx do
      assert {:error, %Ecto.Changeset{} = one} = new_poll(ctx, %{"options" => ["Only"]})
      assert %{options: [_]} = errors_on(one)

      eleven = for n <- 1..11, do: "Option #{n}"
      assert {:error, %Ecto.Changeset{}} = new_poll(ctx, %{"options" => eleven})

      for minutes <- [59, 7 * 24 * 60 + 1] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 new_poll(ctx, %{"duration_minutes" => minutes})

        assert %{duration_minutes: [_]} = errors_on(changeset)
      end
    end

    test "sets the end time from the duration", ctx do
      {:ok, message} = new_poll(ctx, %{"duration_minutes" => 60})

      assert_in_delta DateTime.diff(message.question.closes_at, DateTime.utc_now()), 3600, 5
    end

    test "follows the send rules: a member who may not send gets :forbidden", ctx do
      channel_permission_overwrite_fixture(ctx.channel, %{
        user_id: ctx.author.id,
        deny_permissions: PermissionBits.combine([:send_messages])
      })

      assert {:error, :forbidden} = new_poll(ctx, %{})
    end

    test "keeps the question as voted on: the poll's message takes no edit", ctx do
      {:ok, message} = new_poll(ctx, %{})

      assert {:error, :forbidden} =
               Chat.update_message(scope_for(ctx.author), message.id, %{body: "Changed?"})
    end
  end

  describe "answer/3 on a single-choice poll" do
    setup ctx do
      {:ok, message} = new_poll(ctx, %{})
      Map.put(ctx, :message, message)
    end

    test "records one answer and lists its voter", ctx do
      [red, blue] = option_ids(ctx.message)

      {:ok, message} = vote(ctx.voter, ctx.message, [red])
      results = Questions.results(message.question, ctx.voter.id)

      assert [%{count: 1, answerers: [voter]}, %{count: 0, answerers: []}] = results.options
      assert voter.id == ctx.voter.id
      assert results.mine.option_ids == [red]
      assert results.answer_count == 1
      refute blue in results.mine.option_ids
    end

    test "changes and withdraws the vote while open", ctx do
      [red, blue] = option_ids(ctx.message)

      {:ok, _} = vote(ctx.voter, ctx.message, [red])
      {:ok, changed} = vote(ctx.voter, ctx.message, [blue])
      assert [%{count: 0}, %{count: 1}] = Questions.results(changed.question, nil).options

      {:ok, withdrawn} = vote(ctx.voter, ctx.message, [])
      assert %{answer_count: 0, mine: nil} = Questions.results(withdrawn.question, ctx.voter.id)
    end

    test "refuses two answers and an option of another poll", ctx do
      [red, blue] = option_ids(ctx.message)
      {:ok, other} = new_poll(ctx, %{})

      assert {:error, :invalid_choice} = vote(ctx.voter, ctx.message, [red, blue])

      assert {:error, :invalid_choice} =
               vote(ctx.voter, ctx.message, [hd(option_ids(other))])
    end

    test "refuses a member who may not send, and one who is timed out", ctx do
      channel_permission_overwrite_fixture(ctx.channel, %{
        user_id: ctx.voter.id,
        deny_permissions: PermissionBits.combine([:send_messages])
      })

      assert {:error, :forbidden} = vote(ctx.voter, ctx.message, [hd(option_ids(ctx.message))])

      Repo.update_all(from(m in Membership, where: m.user_id == ^ctx.other_voter.id),
        set: [timeout_until: DateTime.add(DateTime.utc_now(), 3600, :second)]
      )

      assert {:error, :forbidden} =
               vote(ctx.other_voter, ctx.message, [hd(option_ids(ctx.message))])
    end

    test "a poll in a hidden channel is not found", ctx do
      channel_permission_overwrite_fixture(ctx.channel, %{
        user_id: ctx.voter.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:error, :not_found} = vote(ctx.voter, ctx.message, [hd(option_ids(ctx.message))])
    end

    test "broadcasts the vote with the voter and choice on the channel topic", ctx do
      forward_channel_events(ctx.channel)
      [red, _blue] = option_ids(ctx.message)

      {:ok, _} = vote(ctx.voter, ctx.message, [red])

      voter_id = ctx.voter.id
      assert_receive {:question_answered, %{id: _}, %{user_id: ^voter_id, option_ids: [^red]}}
    end
  end

  describe "answer/3 on a multi-select poll with Other" do
    test "takes several options and stores the Other text with the vote", ctx do
      {:ok, message} = new_poll(ctx, %{"multi_select" => true, "allow_other" => true})
      [red, blue] = option_ids(message)

      {:ok, message} = vote(ctx.voter, message, [red, blue], "  Green  ")
      results = Questions.results(message.question, ctx.voter.id)

      assert [%{count: 1}, %{count: 1}] = results.options
      assert %{count: 1, answers: [%{text: "Green", user: user}]} = results.other
      assert user.id == ctx.voter.id
    end

    test "refuses Other text on a poll without Other", ctx do
      {:ok, message} = new_poll(ctx, %{})

      assert {:error, :invalid_choice} = vote(ctx.voter, message, [], "Green")
    end
  end

  describe "anonymous polls" do
    test "give counts and Other text, never who voted", ctx do
      {:ok, message} = new_poll(ctx, %{"anonymous" => true, "allow_other" => true})
      [red, _blue] = option_ids(message)

      {:ok, _} = vote(ctx.voter, message, [red])
      {:ok, message} = vote(ctx.other_voter, message, [], "Green")
      results = Questions.results(message.question, ctx.author.id)

      assert [%{count: 1, answerers: nil}, %{count: 0, answerers: nil}] = results.options
      assert %{answers: [%{text: "Green", user: nil}]} = results.other
    end
  end

  describe "closing" do
    test "by hand: the author or a moderator ends it, a voter may not", ctx do
      {:ok, message} = new_poll(ctx, %{})

      assert {:error, :forbidden} = Questions.close_question(scope_for(ctx.voter), message.id)
      assert {:ok, closed} = Questions.close_question(scope_for(ctx.moderator), message.id)
      assert Question.closed?(closed.question)

      assert {:error, :question_closed} =
               Questions.close_question(scope_for(ctx.author), message.id)

      assert {:error, :question_closed} = vote(ctx.voter, message, [hd(option_ids(message))])
      assert Questions.results(closed.question, nil).closed?
    end

    test "by time: a vote after the end is refused and close_due closes it once", ctx do
      forward_channel_events(ctx.channel)
      {:ok, message} = new_poll(ctx, %{"duration_minutes" => 60})
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      message.question |> change(closes_at: past) |> Repo.update!()

      assert {:error, :question_closed} = vote(ctx.voter, message, [hd(option_ids(message))])

      assert Questions.close_due(DateTime.utc_now()) == nil
      message_id = message.id
      assert_receive {:question_closed, %{id: ^message_id}, :time}

      assert Questions.close_due(DateTime.utc_now()) == nil
      refute_receive {:question_closed, _, _}
      assert Repo.get_by!(Question, message_id: message.id).closed_at == past
    end

    test "the closer wakes at a scheduled end time and closes the poll", ctx do
      forward_channel_events(ctx.channel)
      closer = start_supervised!(Tavern.Chat.QuestionCloser)
      {:ok, message} = new_poll(ctx, %{"duration_minutes" => 60})
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      message.question |> change(closes_at: past) |> Repo.update!()

      Tavern.Chat.QuestionCloser.schedule(past)
      _ = :sys.get_state(closer)

      message_id = message.id
      assert_receive {:question_closed, %{id: ^message_id}, :time}
    end

    test "close_due leaves polls that end later and names the next end time", ctx do
      {:ok, message} = new_poll(ctx, %{"duration_minutes" => 60})

      assert Questions.close_due(DateTime.utc_now()) == message.question.closes_at
      refute Question.closed?(Repo.get_by!(Question, message_id: message.id))
    end

    test "after N answerers: the vote that reaches the limit closes it", ctx do
      forward_channel_events(ctx.channel)
      {:ok, message} = new_poll(ctx, %{"max_answers" => 2})
      [red, _blue] = option_ids(message)

      {:ok, after_one} = vote(ctx.voter, message, [red])
      refute Question.closed?(after_one.question)

      {:ok, after_two} = vote(ctx.other_voter, message, [red])
      assert Question.closed?(after_two.question)
      message_id = message.id
      assert_receive {:question_closed, %{id: ^message_id}, :answered}
      assert {:error, :question_closed} = vote(ctx.voter, message, [])
    end
  end

  describe "narrowed voters" do
    test "a named member may vote and others may not", ctx do
      {:ok, message} = new_poll(ctx, %{"answerer_user_ids" => [ctx.voter.id]})
      [red, _blue] = option_ids(message)

      assert {:ok, _} = vote(ctx.voter, message, [red])
      assert {:error, :forbidden} = vote(ctx.other_voter, message, [red])
    end

    test "a named role lets its members vote", ctx do
      named = role_fixture(%{permissions: 0})
      member_role_fixture(ctx.other_voter, named)
      {:ok, message} = new_poll(ctx, %{"answerer_role_ids" => [named.id]})
      [red, _blue] = option_ids(message)

      assert {:ok, _} = vote(ctx.other_voter, message, [red])
      assert {:error, :forbidden} = vote(ctx.voter, message, [red])
    end

    test "never widens: a named member who may not send still may not vote", ctx do
      channel_permission_overwrite_fixture(ctx.channel, %{
        user_id: ctx.voter.id,
        deny_permissions: PermissionBits.combine([:send_messages])
      })

      {:ok, message} = new_poll(ctx, %{"answerer_user_ids" => [ctx.voter.id]})

      assert {:error, :forbidden} = vote(ctx.voter, message, [hd(option_ids(message))])
    end
  end

  describe "prompts" do
    test "only a bot sends one; a person's ask is forbidden", ctx do
      assert {:error, :forbidden} =
               Questions.create_question(scope_for(ctx.author), ctx.channel.id, %{
                 "kind" => "ask",
                 "question" => "Which?",
                 "options" => labels(["A", "B"])
               })

      assert {:ok, message} = new_prompt(ctx, "ask")
      assert %Question{kind: :ask, max_answers: 1, anonymous: false} = message.question
    end

    test "refuse the poll-only fields, and a permission request refuses several answers", ctx do
      for {field, value} <- [
            {"anonymous", true},
            {"duration_minutes", 60},
            {"max_answers", 3}
          ] do
        assert {:error, changeset} = new_prompt(ctx, "ask", %{field => value})
        assert Map.has_key?(errors_on(changeset), String.to_existing_atom(field))
      end

      assert {:error, changeset} = new_prompt(ctx, "permission", %{"multi_select" => true})
      assert %{multi_select: [_]} = errors_on(changeset)
      assert {:ok, _} = new_prompt(ctx, "ask", %{"multi_select" => true})
    end

    test "a permission request's options need a kind, and only theirs may have one", ctx do
      assert {:error, changeset} =
               new_prompt(ctx, "permission", %{"options" => labels(["Allow", "No"])})

      assert %{options: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               new_poll(ctx, %{"options" => [%{"label" => "A", "kind" => "reject"}, "B"]})

      assert %{options: [_]} = errors_on(changeset)

      {:ok, message} = new_prompt(ctx, "permission")
      assert Enum.map(message.question.options, & &1.kind) == [:allow_once, :reject]
    end

    test "take up to 4000 characters of text; a poll takes 300", ctx do
      long = String.duplicate("x", 301)

      assert {:error, changeset} = new_poll(ctx, %{"question" => long})
      assert %{question: [_]} = errors_on(changeset)
      assert {:ok, _} = new_prompt(ctx, "ask", %{"question" => long})
    end

    test "the first answer closes it, and nobody answers after", ctx do
      forward_channel_events(ctx.channel)
      {:ok, message} = new_prompt(ctx, "permission")
      [allow, _no] = option_ids(message)

      {:ok, answered} = vote(ctx.voter, message, [allow])
      assert Question.closed?(answered.question)
      message_id = message.id
      assert_receive {:question_closed, %{id: ^message_id}, :answered}

      assert {:error, :question_closed} = vote(ctx.other_voter, message, [allow])
    end

    test "refuse an empty answer, which would close them with no answer", ctx do
      {:ok, message} = new_prompt(ctx, "ask", %{"multi_select" => true})

      assert {:error, :invalid_choice} = vote(ctx.voter, message, [])
      refute Question.closed?(Repo.reload!(message.question))
    end

    test "a closed permission request leaves every list; reading it by id still finds it", ctx do
      {:ok, ask} = new_prompt(ctx, "ask")
      {:ok, permission} = new_prompt(ctx, "permission")
      reader = scope_for(ctx.other_voter)
      assert Chat.message_count(reader, ctx.channel.id) == 2

      {:ok, _} = vote(ctx.voter, permission, [hd(option_ids(permission))])

      ask_id = ask.id
      assert {:ok, [%{id: ^ask_id}]} = Chat.list_messages(reader, ctx.channel.id)
      assert Chat.message_count(reader, ctx.channel.id) == 1
      assert Chat.unread_counts(reader, [ctx.channel.id]) == %{ctx.channel.id => 1}

      permission_id = permission.id
      assert %{id: ^permission_id} = Chat.get_message(ctx.bot_scope, permission.id)
    end

    test "a permission request closed in a thread lowers its reply count and tells the parent",
         ctx do
      forward_channel_events(ctx.channel)
      starter = message_fixture(ctx.channel, ctx.author, %{body: "starter"})
      thread = thread_fixture(ctx.channel, starter, ctx.author)

      {:ok, permission} =
        Questions.create_question(ctx.bot_scope, thread.id, %{
          "kind" => "permission",
          "question" => "Read `mix.exs`?",
          "options" => [
            %{"label" => "Allow", "kind" => "allow_once"},
            %{"label" => "No", "kind" => "reject"}
          ]
        })

      assert Chat.thread_reply_count(scope_for(ctx.voter), thread.id) == 1
      {:ok, _} = Questions.close_question(ctx.bot_scope, permission.id)

      assert Chat.thread_reply_count(scope_for(ctx.voter), thread.id) == 0
      permission_id = permission.id
      assert_receive {:thread_message_unlisted, %{id: ^permission_id}}
    end

    test "the bot or a moderator closes it by hand, an answerer may not", ctx do
      {:ok, message} = new_prompt(ctx, "ask")

      assert {:error, :forbidden} = Questions.close_question(scope_for(ctx.voter), message.id)
      assert {:ok, _} = Questions.close_question(scope_for(ctx.moderator), message.id)

      {:ok, message} = new_prompt(ctx, "ask")
      assert {:ok, _} = Questions.close_question(ctx.bot_scope, message.id)
    end
  end

  describe "threads" do
    setup ctx do
      starter = message_fixture(ctx.channel, ctx.author, %{body: "starter"})
      thread = thread_fixture(ctx.channel, starter, ctx.author)
      {:ok, message} = new_poll(ctx, %{}, thread.id)
      Map.merge(ctx, %{thread: thread, message: message})
    end

    test "a locked or archived thread refuses a member's vote; a moderator may still vote", ctx do
      [red, _blue] = option_ids(ctx.message)

      ctx.thread |> change(locked_at: DateTime.utc_now()) |> Repo.update!()
      assert {:error, :forbidden} = vote(ctx.voter, ctx.message, [red])
      assert {:ok, _} = vote(ctx.moderator, ctx.message, [red])

      Repo.get!(Tavern.Chat.Channel, ctx.thread.id)
      |> change(locked_at: nil, archived_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:error, :forbidden} = vote(ctx.voter, ctx.message, [red])
    end
  end

  defp new_poll(ctx, attrs, channel_id \\ nil) do
    Questions.create_question(
      scope_for(ctx.author),
      channel_id || ctx.channel.id,
      %{"question" => "Which colour?", "options" => ["Red", "Blue"]}
      |> Map.merge(attrs)
      |> Map.update!("options", &labels/1)
    )
  end

  defp new_prompt(ctx, kind, attrs \\ %{}) do
    options =
      if kind == "permission",
        do: [
          %{"label" => "Allow", "kind" => "allow_once"},
          %{"label" => "No", "kind" => "reject"}
        ],
        else: labels(["Staging", "Production"])

    Questions.create_question(
      ctx.bot_scope,
      ctx.channel.id,
      Map.merge(
        %{
          "kind" => kind,
          "question" => "Run the migration?",
          "options" => options,
          "answerer_user_ids" => [ctx.voter.id, ctx.other_voter.id]
        },
        attrs
      )
    )
  end

  # The options as the form and the API send them: one object per label.
  defp labels(options), do: Enum.map(options, &if(is_binary(&1), do: %{"label" => &1}, else: &1))

  defp vote(user, message, option_ids, other_text \\ nil) do
    Questions.answer(scope_for(user), message.id, %{
      "option_ids" => option_ids,
      "other_text" => other_text
    })
  end

  defp option_ids(message), do: Enum.map(message.question.options, & &1.id)

  # Broadcasts skip the writing process, so a separate subscriber forwards the channel's events.
  defp forward_channel_events(channel) do
    parent = self()

    spawn_link(fn ->
      Topics.sync_channel_subscriptions(MapSet.new(), MapSet.new([channel.id]))
      send(parent, :subscribed)
      forward(parent)
    end)

    assert_receive :subscribed
  end

  defp forward(parent) do
    receive do
      event ->
        send(parent, event)
        forward(parent)
    end
  end
end
