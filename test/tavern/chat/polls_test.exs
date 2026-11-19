defmodule Tavern.Chat.PollsTest do
  @moduledoc """
  Polls: a message with a question and options. Members who may send in the channel vote, change
  and withdraw their vote while it is open; a poll closes by hand, at its end time or after its
  vote limit, and may narrow its voters to named members and roles.
  """
  use Tavern.DataCase, async: false

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query
  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.Membership
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Poll
  alias Tavern.Chat.Polls
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
    _owner = owner_fixture()
    member_role = role_fixture(%{permissions: PermissionBits.combine(@member_bits)})

    moderator_role =
      role_fixture(%{permissions: PermissionBits.combine([:manage_messages | @member_bits])})

    [author, voter, other_voter, moderator] = for _ <- 1..4, do: user_fixture()
    Enum.each([author, voter, other_voter], &member_role_fixture(&1, member_role))
    member_role_fixture(moderator, moderator_role)

    %{
      channel: channel_fixture(%{}),
      author: author,
      voter: voter,
      other_voter: other_voter,
      moderator: moderator,
      member_role: member_role
    }
  end

  describe "create_poll/3" do
    test "sends a message whose body is the question, with its options in order", ctx do
      {:ok, message} = new_poll(ctx, %{"options" => [" Red ", "Blue", "", "blue"]})

      assert message.body == "Which colour?"
      assert message.poll.closes_at == nil
      assert Enum.map(message.poll.options, & &1.label) == ["Red", "Blue"]
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

      assert_in_delta DateTime.diff(message.poll.closes_at, DateTime.utc_now()), 3600, 5
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

  describe "vote/3 on a single-choice poll" do
    setup ctx do
      {:ok, message} = new_poll(ctx, %{})
      Map.put(ctx, :message, message)
    end

    test "records one answer and lists its voter", ctx do
      [red, blue] = option_ids(ctx.message)

      {:ok, message} = vote(ctx.voter, ctx.message, [red])
      results = Polls.results(message.poll, ctx.voter.id)

      assert [%{count: 1, voters: [voter]}, %{count: 0, voters: []}] = results.options
      assert voter.id == ctx.voter.id
      assert results.mine.option_ids == [red]
      assert results.voter_count == 1
      refute blue in results.mine.option_ids
    end

    test "changes and withdraws the vote while open", ctx do
      [red, blue] = option_ids(ctx.message)

      {:ok, _} = vote(ctx.voter, ctx.message, [red])
      {:ok, changed} = vote(ctx.voter, ctx.message, [blue])
      assert [%{count: 0}, %{count: 1}] = Polls.results(changed.poll, nil).options

      {:ok, withdrawn} = vote(ctx.voter, ctx.message, [])
      assert %{voter_count: 0, mine: nil} = Polls.results(withdrawn.poll, ctx.voter.id)
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
      assert_receive {:poll_voted, %{id: _}, %{user_id: ^voter_id, option_ids: [^red]}}
    end
  end

  describe "vote/3 on a multi-select poll with Other" do
    test "takes several options and stores the Other text with the vote", ctx do
      {:ok, message} = new_poll(ctx, %{"multi_select" => true, "allow_other" => true})
      [red, blue] = option_ids(message)

      {:ok, message} = vote(ctx.voter, message, [red, blue], "  Green  ")
      results = Polls.results(message.poll, ctx.voter.id)

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
      results = Polls.results(message.poll, ctx.author.id)

      assert [%{count: 1, voters: nil}, %{count: 0, voters: nil}] = results.options
      assert %{answers: [%{text: "Green", user: nil}]} = results.other
    end
  end

  describe "closing" do
    test "by hand: the author or a moderator ends it, a voter may not", ctx do
      {:ok, message} = new_poll(ctx, %{})

      assert {:error, :forbidden} = Polls.close_poll(scope_for(ctx.voter), message.id)
      assert {:ok, closed} = Polls.close_poll(scope_for(ctx.moderator), message.id)
      assert Poll.closed?(closed.poll)
      assert {:error, :poll_closed} = Polls.close_poll(scope_for(ctx.author), message.id)

      assert {:error, :poll_closed} = vote(ctx.voter, message, [hd(option_ids(message))])
      assert Polls.results(closed.poll, nil).closed?
    end

    test "by time: a vote after the end is refused and close_due closes it once", ctx do
      forward_channel_events(ctx.channel)
      {:ok, message} = new_poll(ctx, %{"duration_minutes" => 60})
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      message.poll |> change(closes_at: past) |> Repo.update!()

      assert {:error, :poll_closed} = vote(ctx.voter, message, [hd(option_ids(message))])

      assert Polls.close_due(DateTime.utc_now()) == nil
      message_id = message.id
      assert_receive {:poll_closed, %{id: ^message_id}, :time}

      assert Polls.close_due(DateTime.utc_now()) == nil
      refute_receive {:poll_closed, _, _}
      assert Repo.get_by!(Poll, message_id: message.id).closed_at == past
    end

    test "the closer wakes at a scheduled end time and closes the poll", ctx do
      forward_channel_events(ctx.channel)
      closer = start_supervised!(Tavern.Chat.PollCloser)
      {:ok, message} = new_poll(ctx, %{"duration_minutes" => 60})
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      message.poll |> change(closes_at: past) |> Repo.update!()

      Tavern.Chat.PollCloser.schedule(past)
      _ = :sys.get_state(closer)

      message_id = message.id
      assert_receive {:poll_closed, %{id: ^message_id}, :time}
    end

    test "close_due leaves polls that end later and names the next end time", ctx do
      {:ok, message} = new_poll(ctx, %{"duration_minutes" => 60})

      assert Polls.close_due(DateTime.utc_now()) == message.poll.closes_at
      refute Poll.closed?(Repo.get_by!(Poll, message_id: message.id))
    end

    test "after N voters: the vote that reaches the limit closes it", ctx do
      forward_channel_events(ctx.channel)
      {:ok, message} = new_poll(ctx, %{"max_voters" => 2})
      [red, _blue] = option_ids(message)

      {:ok, after_one} = vote(ctx.voter, message, [red])
      refute Poll.closed?(after_one.poll)

      {:ok, after_two} = vote(ctx.other_voter, message, [red])
      assert Poll.closed?(after_two.poll)
      message_id = message.id
      assert_receive {:poll_closed, %{id: ^message_id}, :max_voters}
      assert {:error, :poll_closed} = vote(ctx.voter, message, [])
    end
  end

  describe "narrowed voters" do
    test "a named member may vote and others may not", ctx do
      {:ok, message} = new_poll(ctx, %{"voter_user_ids" => [ctx.voter.id]})
      [red, _blue] = option_ids(message)

      assert {:ok, _} = vote(ctx.voter, message, [red])
      assert {:error, :forbidden} = vote(ctx.other_voter, message, [red])
    end

    test "a named role lets its members vote", ctx do
      named = role_fixture(%{permissions: 0})
      member_role_fixture(ctx.other_voter, named)
      {:ok, message} = new_poll(ctx, %{"voter_role_ids" => [named.id]})
      [red, _blue] = option_ids(message)

      assert {:ok, _} = vote(ctx.other_voter, message, [red])
      assert {:error, :forbidden} = vote(ctx.voter, message, [red])
    end

    test "never widens: a named member who may not send still may not vote", ctx do
      channel_permission_overwrite_fixture(ctx.channel, %{
        user_id: ctx.voter.id,
        deny_permissions: PermissionBits.combine([:send_messages])
      })

      {:ok, message} = new_poll(ctx, %{"voter_user_ids" => [ctx.voter.id]})

      assert {:error, :forbidden} = vote(ctx.voter, message, [hd(option_ids(message))])
    end

    test "an agent question: one named voter, closed by the first vote, with Other text", ctx do
      {:ok, message} =
        new_poll(ctx, %{
          "question" => "Run the migration?",
          "options" => ["once", "always", "reject"],
          "voter_user_ids" => [ctx.voter.id],
          "max_voters" => 1,
          "allow_other" => true
        })

      {:ok, answered} = vote(ctx.voter, message, [], "only on staging")

      assert Poll.closed?(answered.poll)
      assert %{answers: [%{text: "only on staging"}]} = Polls.results(answered.poll, nil).other
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
    Polls.create_poll(
      scope_for(ctx.author),
      channel_id || ctx.channel.id,
      Map.merge(%{"question" => "Which colour?", "options" => ["Red", "Blue"]}, attrs)
    )
  end

  defp vote(user, message, option_ids, other_text \\ nil) do
    Polls.vote(scope_for(user), message.id, %{
      "option_ids" => option_ids,
      "other_text" => other_text
    })
  end

  defp option_ids(message), do: Enum.map(message.poll.options, & &1.id)

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
