defmodule Tavern.Chat.Polls do
  @moduledoc """
  Polls (docs/design/polls.md). A poll is a message whose body is the question, with 2 to 10
  options. Members vote while it is open, may change or withdraw their vote, and see the results
  after it closes.

  Who may vote is decided twice, in the vote's transaction: `Tavern.Chat.Visibility` decides
  `:vote_in_poll` (the channel's send rule, with timeouts and closed threads), then the poll's own
  voter list may narrow that to named members and roles. A vote, a close by hand and the timer
  each lock the poll row, so a vote never lands on a closed poll and a poll closes once.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Ids
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageRows
  alias Tavern.Chat.Messages
  alias Tavern.Chat.Poll
  alias Tavern.Chat.PollBallot
  alias Tavern.Chat.PollCloser
  alias Tavern.Chat.PollOption
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @min_options 2
  @max_options 10
  @min_duration_minutes 60
  @max_duration_minutes 7 * 24 * 60

  @poll_types %{
    question: :string,
    options: {:array, :string},
    multi_select: :boolean,
    anonymous: :boolean,
    allow_other: :boolean,
    duration_minutes: :integer,
    max_voters: :integer,
    voter_user_ids: {:array, :binary_id},
    voter_role_ids: {:array, :binary_id}
  }

  @poll_defaults %{
    multi_select: false,
    anonymous: false,
    allow_other: false,
    duration_minutes: nil,
    max_voters: nil,
    voter_user_ids: [],
    voter_role_ids: []
  }

  @doc """
  A changeset for a new poll. `duration_minutes` is the time it stays open, from 1 hour to 7 days,
  or nil for a poll its author ends by hand. `max_voters` closes it after that many members voted.
  `voter_user_ids` and `voter_role_ids` narrow who may vote; both empty means every member who
  may send in the channel.
  """
  def change_poll(attrs \\ %{}) do
    {@poll_defaults, @poll_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@poll_types))
    |> Ecto.Changeset.update_change(:question, &String.trim/1)
    |> Ecto.Changeset.update_change(:options, &clean_options/1)
    |> Ecto.Changeset.validate_required([:question, :options])
    |> Ecto.Changeset.validate_length(:question, max: 300)
    |> Ecto.Changeset.validate_length(:options,
      min: @min_options,
      max: @max_options,
      message: "needs #{@min_options} to #{@max_options} distinct options"
    )
    |> validate_option_labels()
    |> Ecto.Changeset.validate_number(:duration_minutes,
      greater_than_or_equal_to: @min_duration_minutes,
      less_than_or_equal_to: @max_duration_minutes
    )
    |> Ecto.Changeset.validate_number(:max_voters, greater_than: 0)
  end

  @doc """
  Sends a poll to a channel or thread: a message whose body is the question, with its poll, in one
  transaction under every rule a message send follows (`Chat.create_message/3`). Returns `{:ok,
  message}` with the poll loaded, `{:error, changeset}` for a poll the form refuses, and the
  refusals of `Chat.create_message/3`.
  """
  def create_poll(%Scope{} = scope, channel_id, attrs) do
    with {:ok, spec} <- Ecto.Changeset.apply_action(change_poll(attrs), :insert),
         {:ok, message} <-
           Messages.send_message(
             scope,
             channel_id,
             %{"body" => spec.question, "metadata" => %{}},
             &insert_poll(&1, spec)
           ) do
      if message.poll.closes_at, do: PollCloser.schedule(message.poll.closes_at)
      {:ok, message}
    end
  end

  defp insert_poll({%Message{} = message, followers}, spec) do
    closes_at =
      spec.duration_minutes &&
        DateTime.add(DateTime.utc_now(), spec.duration_minutes * 60, :second)

    poll =
      Repo.insert!(%Poll{
        message_id: message.id,
        multi_select: spec.multi_select,
        anonymous: spec.anonymous,
        allow_other: spec.allow_other,
        closes_at: closes_at,
        max_voters: spec.max_voters,
        voter_user_ids: Enum.uniq(spec.voter_user_ids),
        voter_role_ids: Enum.uniq(spec.voter_role_ids)
      })

    options =
      spec.options
      |> Enum.with_index()
      |> Enum.map(fn {label, position} ->
        %{id: Ecto.UUID.generate(), poll_id: poll.id, position: position, label: label}
      end)

    Repo.insert_all(PollOption, options)
    {:ok, {MessageRows.reload_message(message.id), followers}}
  end

  @doc """
  Sets the scope's vote in the poll on `message_id` to `choice`, replacing any vote it had.
  `choice` holds `"option_ids"` (a list) and `"other_text"` (the "Other" answer, or nil). A choice
  with no option and no Other text withdraws the vote. A single-choice poll takes one answer.

  The vote that reaches the poll's `max_voters` closes it. Returns `{:ok, message}`. Refusals:
  `{:error, :not_found}` for a hidden or missing poll, `{:error, :forbidden}` for a member who may
  not vote, `{:error, :poll_closed}`, and `{:error, :invalid_choice}`.
  """
  def vote(%Scope{} = scope, message_id, choice) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      with {:ok, message} <- authorize_poll_write(scope, :vote_in_poll, message_id),
           %Poll{} = poll <- lock_poll(message.id),
           :ok <- ensure_open(poll, now),
           :ok <- ensure_listed(scope, poll),
           {:ok, ballot} <- parse_choice(poll, choice),
           :ok <- write_ballot(poll, scope.user_id, ballot),
           closed? = close_at_limit(poll, now) do
        {:ok, {MessageRows.reload_message(message.id), ballot, closed?}}
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
    |> case do
      {:ok, {message, ballot, closed?}} ->
        vote = Map.put(ballot, :user_id, scope.user_id)
        Topics.broadcast_channel(message.channel_id, {:poll_voted, message, vote})

        if closed?,
          do: Topics.broadcast_channel(message.channel_id, {:poll_closed, message, :max_voters})

        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  Ends the poll on `message_id` now. Its author may end it, and so may a member with
  `manage_messages` in its channel. Returns `{:ok, message}`, or `{:error, :poll_closed}`,
  `{:error, :forbidden}` and `{:error, :not_found}`.
  """
  def close_poll(%Scope{} = scope, message_id) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      with {:ok, message} <- authorize_poll_write(scope, :close_poll, message_id),
           %Poll{} = poll <- lock_poll(message.id),
           :ok <- ensure_open(poll, now) do
        mark_closed!(poll, now)
        {:ok, MessageRows.reload_message(message.id)}
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
    |> case do
      {:ok, message} ->
        Topics.broadcast_channel(message.channel_id, {:poll_closed, message, :closed_by_hand})
        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  Closes every open poll whose end time is at or before `now`, and broadcasts each close. A poll
  whose row another transaction holds is left for the next run. A poll on a deleted message is
  left open: nobody can vote on it. Returns the end time of the next poll still open, or nil.
  Server work with no actor: `Tavern.Chat.PollCloser` runs it.
  """
  def close_due(now \\ DateTime.utc_now()) do
    {:ok, closed} =
      Repo.transact(fn ->
        polls =
          Repo.all(
            from(poll in due_polls(),
              where: poll.closes_at <= ^now,
              lock: "FOR UPDATE SKIP LOCKED"
            )
          )

        Enum.each(polls, &mark_closed!(&1, &1.closes_at))
        {:ok, Enum.map(polls, & &1.message_id)}
      end)

    for message_id <- closed do
      message = MessageRows.reload_message(message_id)
      Topics.broadcast_channel(message.channel_id, {:poll_closed, message, :time})
    end

    Repo.one(from(poll in due_polls(), select: min(poll.closes_at)))
  end

  defp due_polls do
    from(poll in Poll,
      join: message in Message,
      on: message.id == poll.message_id,
      where: is_nil(poll.closed_at) and not is_nil(poll.closes_at) and is_nil(message.deleted_at)
    )
  end

  @doc """
  The results of a loaded poll (options and ballots with users), as `viewer_id` sees them. Each
  option has its `count` and its `voters`; an anonymous poll gives `voters: nil` and Other answers
  without their authors, so only counts and the answers' text show. `mine` is the viewer's own
  ballot or nil.
  """
  def results(%Poll{} = poll, viewer_id) do
    ballots = poll.ballots

    options =
      Enum.map(poll.options, fn option ->
        chosen_by = Enum.filter(ballots, &(option.id in &1.option_ids))

        %{
          id: option.id,
          label: option.label,
          count: length(chosen_by),
          voters: unless(poll.anonymous, do: Enum.map(chosen_by, & &1.user))
        }
      end)

    other =
      if poll.allow_other do
        answers =
          for ballot <- ballots, ballot.other_text do
            %{text: ballot.other_text, user: unless(poll.anonymous, do: ballot.user)}
          end

        %{count: length(answers), answers: answers}
      end

    %{
      options: options,
      other: other,
      voter_count: length(ballots),
      mine: Enum.find(ballots, &(&1.user_id == viewer_id)),
      closed?: Poll.closed?(poll)
    }
  end

  # The decision, then the message row lock, then (by the caller) the poll row lock: the order
  # every message write takes, so a delete and a vote queue behind each other.
  defp authorize_poll_write(scope, action, message_id) do
    with {:ok, message_id} <- Ids.cast(message_id),
         :ok <- Visibility.authorize_write(scope, action, %Message{id: message_id}) do
      case MessageRows.lock_live_message(message_id) do
        %Message{} = message -> {:ok, message}
        nil -> {:error, :not_found}
      end
    end
  end

  defp lock_poll(message_id),
    do: Repo.one(from(poll in Poll, where: poll.message_id == ^message_id, lock: "FOR UPDATE"))

  defp ensure_open(poll, now),
    do: if(Poll.closed?(poll, now), do: {:error, :poll_closed}, else: :ok)

  defp ensure_listed(scope, %Poll{} = poll) do
    if Poll.narrowed?(poll) do
      role_ids =
        case Visibility.member(scope) do
          nil -> []
          member -> Enum.map(member.member_roles, & &1.role_id)
        end

      if Poll.listed_voter?(poll, scope.user_id, role_ids), do: :ok, else: {:error, :forbidden}
    else
      :ok
    end
  end

  # A choice names options of this poll, at most one answer for a single-choice poll, and Other
  # text only where the poll allows it.
  defp parse_choice(%Poll{} = poll, choice) do
    option_ids = choice |> choice_field("option_ids") |> List.wrap() |> Enum.uniq()
    other_text = choice |> choice_field("other_text") |> clean_other_text()
    poll_option_ids = poll |> Repo.preload(:options) |> Map.fetch!(:options) |> Enum.map(& &1.id)
    answers = length(option_ids) + if(other_text, do: 1, else: 0)

    cond do
      not Enum.all?(option_ids, &(&1 in poll_option_ids)) -> {:error, :invalid_choice}
      other_text && not poll.allow_other -> {:error, :invalid_choice}
      other_text && String.length(other_text) > 200 -> {:error, :invalid_choice}
      answers > 1 and not poll.multi_select -> {:error, :invalid_choice}
      true -> {:ok, %{option_ids: option_ids, other_text: other_text}}
    end
  end

  defp choice_field(choice, key) when is_map(choice), do: Map.get(choice, key)
  defp choice_field(_choice, _key), do: nil

  defp clean_other_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp clean_other_text(_text), do: nil

  defp write_ballot(poll, user_id, %{option_ids: [], other_text: nil}) do
    Repo.delete_all(
      from(ballot in PollBallot, where: ballot.poll_id == ^poll.id and ballot.user_id == ^user_id)
    )

    :ok
  end

  defp write_ballot(poll, user_id, ballot) do
    now = DateTime.utc_now()

    Repo.insert!(
      %PollBallot{
        poll_id: poll.id,
        user_id: user_id,
        option_ids: ballot.option_ids,
        other_text: ballot.other_text,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [
        set: [option_ids: ballot.option_ids, other_text: ballot.other_text, updated_at: now]
      ],
      conflict_target: [:poll_id, :user_id]
    )

    :ok
  end

  # Under the poll row lock the ballot count is exact, so the vote that reaches the limit is the
  # one that closes the poll.
  defp close_at_limit(%Poll{max_voters: nil}, _now), do: false

  defp close_at_limit(%Poll{max_voters: max_voters} = poll, now) do
    voters = Repo.aggregate(from(ballot in PollBallot, where: ballot.poll_id == ^poll.id), :count)

    if voters >= max_voters do
      mark_closed!(poll, now)
      true
    else
      false
    end
  end

  defp mark_closed!(poll, at),
    do: poll |> Ecto.Changeset.change(closed_at: at) |> Repo.update!()

  defp clean_options(options) do
    options
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp validate_option_labels(changeset) do
    Ecto.Changeset.validate_change(changeset, :options, fn :options, options ->
      if Enum.any?(options, &(String.length(&1) > 80)),
        do: [options: "each option is at most 80 characters"],
        else: []
    end)
  end
end
