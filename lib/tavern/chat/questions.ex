defmodule Tavern.Chat.Questions do
  @moduledoc """
  Questions (docs/design/questions.md): a message whose body is the question, with 2 to 10
  options. A poll is voted on by members, who may change or withdraw their vote and see the
  results. An ask and a permission request are a bot's prompts: one member listed by the bot
  answers once, and that answer closes it.

  Who may answer is decided twice, in the answer's transaction: `Tavern.Chat.Visibility` decides
  `:answer_question` (the channel's send rule, with timeouts and closed threads), then the
  question's own answerer list may narrow that to named members and roles. An answer, a close by
  hand and the timer each lock the question row, so an answer never lands on a closed question
  and a question closes once.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Ids
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageRows
  alias Tavern.Chat.Messages
  alias Tavern.Chat.Question
  alias Tavern.Chat.QuestionAnswer
  alias Tavern.Chat.QuestionCloser
  alias Tavern.Chat.QuestionOption
  alias Tavern.Chat.ThreadFollows
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @min_options 2
  @max_options 10
  @min_duration_minutes 60
  @max_duration_minutes 7 * 24 * 60

  # A poll's question is a short plain line; a prompt may carry a command or a diff, so it takes
  # the message limit and renders as Markdown.
  @poll_question_max 300
  @prompt_question_max 4000

  @option_kind_type Ecto.ParameterizedType.init(Ecto.Enum, values: QuestionOption.kinds())

  @question_types %{
    kind: Ecto.ParameterizedType.init(Ecto.Enum, values: Question.kinds()),
    question: :string,
    options: {:array, :map},
    multi_select: :boolean,
    anonymous: :boolean,
    allow_other: :boolean,
    duration_minutes: :integer,
    max_answers: :integer,
    answerer_user_ids: {:array, :binary_id},
    answerer_role_ids: {:array, :binary_id}
  }

  @question_defaults %{
    kind: :poll,
    multi_select: false,
    anonymous: false,
    allow_other: false,
    duration_minutes: nil,
    max_answers: nil,
    answerer_user_ids: [],
    answerer_role_ids: []
  }

  @doc """
  A changeset for a new question. `options` is a list of `%{"label" => text}`; a permission
  request's options also carry `"kind"` (`allow_once`, `allow_always` or `reject`), and no other
  kind's options may.

  Poll-only fields: `anonymous`, `duration_minutes` (1 hour to 7 days, or nil for a poll its
  author ends by hand) and `max_answers` (it closes after that many members voted). A prompt
  refuses them, since one answer closes it. A permission request takes one answer, so it refuses
  `multi_select`. `answerer_user_ids` and `answerer_role_ids` narrow who may answer; both empty
  means every member who may send in the channel.
  """
  def change_question(attrs \\ %{}) do
    changeset =
      {@question_defaults, @question_types}
      |> Ecto.Changeset.cast(attrs, Map.keys(@question_types))
      |> Ecto.Changeset.validate_required([:kind])
      |> Ecto.Changeset.update_change(:question, &String.trim/1)
      |> Ecto.Changeset.validate_required([:question, :options])
      |> clean_options()
      |> Ecto.Changeset.validate_length(:options,
        min: @min_options,
        max: @max_options,
        message: "needs #{@min_options} to #{@max_options} distinct options"
      )
      |> Ecto.Changeset.validate_number(:duration_minutes,
        greater_than_or_equal_to: @min_duration_minutes,
        less_than_or_equal_to: @max_duration_minutes
      )
      |> Ecto.Changeset.validate_number(:max_answers, greater_than: 0)

    validate_kind(changeset, Ecto.Changeset.get_field(changeset, :kind))
  end

  defp validate_kind(changeset, :poll) do
    changeset
    |> Ecto.Changeset.validate_length(:question, max: @poll_question_max)
    |> validate_option_kinds(false)
  end

  defp validate_kind(changeset, kind) when kind in [:ask, :permission] do
    changeset
    |> Ecto.Changeset.validate_length(:question, max: @prompt_question_max)
    |> refuse_for_prompt(:anonymous, &(&1 == true))
    |> refuse_for_prompt(:duration_minutes, &(not is_nil(&1)))
    |> refuse_for_prompt(:max_answers, &(not is_nil(&1)))
    |> then(fn changeset ->
      if kind == :permission,
        do:
          changeset
          |> refuse_for_prompt(:multi_select, &(&1 == true))
          |> validate_option_kinds(true),
        else: validate_option_kinds(changeset, false)
    end)
  end

  defp validate_kind(changeset, _kind), do: changeset

  defp refuse_for_prompt(changeset, field, set?) do
    if set?.(Ecto.Changeset.get_field(changeset, field)),
      do: Ecto.Changeset.add_error(changeset, field, "is not allowed for this kind of question"),
      else: changeset
  end

  # A permission request's options each say what they mean; other questions' options never do.
  # Options that did not parse already carry their error.
  defp validate_option_kinds(changeset, wanted?) do
    if Keyword.has_key?(changeset.errors, :options),
      do: changeset,
      else: check_option_kinds(changeset, wanted?)
  end

  defp check_option_kinds(changeset, wanted?) do
    Ecto.Changeset.validate_change(changeset, :options, fn :options, options ->
      cond do
        wanted? and Enum.any?(options, &is_nil(&1.kind)) ->
          [options: "each option needs a kind: allow_once, allow_always or reject"]

        not wanted? and Enum.any?(options, & &1.kind) ->
          [options: "only a permission request's options have a kind"]

        true ->
          []
      end
    end)
  end

  @doc """
  Sends a question to a channel or thread: a message whose body is the question, with its rows, in
  one transaction under every rule a message send follows (`Chat.create_message/3`). Only a bot
  sends a prompt (`:ask` or `:permission`); a person's prompt is `{:error, :forbidden}`. Returns
  `{:ok, message}` with the question loaded, `{:error, changeset}` for a question the form
  refuses, and the refusals of `Chat.create_message/3`.
  """
  def create_question(%Scope{} = scope, channel_id, attrs) do
    with {:ok, spec} <- Ecto.Changeset.apply_action(change_question(attrs), :insert),
         :ok <- ensure_may_prompt(scope, spec.kind),
         {:ok, message} <-
           Messages.send_message(
             scope,
             channel_id,
             %{"body" => spec.question, "metadata" => %{}},
             &insert_question(&1, spec)
           ) do
      if message.question.closes_at, do: QuestionCloser.schedule(message.question.closes_at)
      {:ok, message}
    end
  end

  defp ensure_may_prompt(_scope, :poll), do: :ok
  defp ensure_may_prompt(%Scope{bot_token_id: nil}, _kind), do: {:error, :forbidden}
  defp ensure_may_prompt(%Scope{}, _kind), do: :ok

  defp insert_question({%Message{} = message, followers}, spec) do
    closes_at =
      spec.duration_minutes &&
        DateTime.add(DateTime.utc_now(), spec.duration_minutes * 60, :second)

    question =
      Repo.insert!(%Question{
        message_id: message.id,
        kind: spec.kind,
        multi_select: spec.multi_select,
        anonymous: spec.anonymous,
        allow_other: spec.allow_other,
        closes_at: closes_at,
        max_answers: if(spec.kind == :poll, do: spec.max_answers, else: 1),
        answerer_user_ids: Enum.uniq(spec.answerer_user_ids),
        answerer_role_ids: Enum.uniq(spec.answerer_role_ids)
      })

    options =
      spec.options
      |> Enum.with_index()
      |> Enum.map(fn {option, position} ->
        %{
          id: Ecto.UUID.generate(),
          question_id: question.id,
          position: position,
          label: option.label,
          kind: option.kind
        }
      end)

    Repo.insert_all(QuestionOption, options)
    {:ok, {MessageRows.reload_message(message.id), followers}}
  end

  @doc """
  Sets the scope's answer to the question on `message_id` to `choice`, replacing any answer it
  had. `choice` holds `"option_ids"` (a list) and `"other_text"` (the "Other" answer, or nil). A
  choice with no option and no Other text withdraws a poll vote; a prompt refuses it. A
  single-choice question takes one answer.

  The answer that reaches the question's `max_answers` closes it, so a prompt's first answer
  closes it. Returns `{:ok, message}`. Refusals: `{:error, :not_found}` for a hidden or missing
  question, `{:error, :forbidden}` for a member who may not answer, `{:error, :question_closed}`,
  and `{:error, :invalid_choice}`.
  """
  def answer(%Scope{} = scope, message_id, choice) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      with {:ok, message} <- authorize_question_write(scope, :answer_question, message_id),
           %Question{} = question <- lock_question(message.id),
           :ok <- ensure_open(question, now),
           :ok <- ensure_listed(scope, question),
           {:ok, answer} <- parse_choice(question, choice),
           :ok <- write_answer(question, scope.user_id, answer),
           closed? = close_at_limit(question, now) do
        {:ok, {MessageRows.reload_message(message.id), answer, closed?}}
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
    |> case do
      {:ok, {message, answer, closed?}} ->
        answer = Map.put(answer, :user_id, scope.user_id)
        Topics.broadcast_channel(message.channel_id, {:question_answered, message, answer})

        if closed?, do: broadcast_closed(message, :answered)

        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  Closes the question on `message_id` now. Its author may close it, and so may a member with
  `manage_messages` in its channel. Returns `{:ok, message}`, or `{:error, :question_closed}`,
  `{:error, :forbidden}` and `{:error, :not_found}`.
  """
  def close_question(%Scope{} = scope, message_id) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      with {:ok, message} <- authorize_question_write(scope, :close_question, message_id),
           %Question{} = question <- lock_question(message.id),
           :ok <- ensure_open(question, now) do
        mark_closed!(question, now)
        {:ok, MessageRows.reload_message(message.id)}
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
    |> case do
      {:ok, message} ->
        broadcast_closed(message, :closed_by_hand)
        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  Closes every open question whose end time is at or before `now`, and broadcasts each close. Only
  a poll has an end time. A question whose row another transaction holds is left for the next
  run. A question on a deleted message is left open: nobody can answer it. Returns the end time
  of the next question still open, or nil. Server work with no actor:
  `Tavern.Chat.QuestionCloser` runs it.
  """
  def close_due(now \\ DateTime.utc_now()) do
    {:ok, closed} =
      Repo.transact(fn ->
        questions =
          Repo.all(
            from(question in due_questions(),
              where: question.closes_at <= ^now,
              lock: "FOR UPDATE SKIP LOCKED"
            )
          )

        Enum.each(questions, &mark_closed!(&1, &1.closes_at))
        {:ok, Enum.map(questions, & &1.message_id)}
      end)

    for message_id <- closed do
      message_id |> MessageRows.reload_message() |> broadcast_closed(:time)
    end

    Repo.one(from(question in due_questions(), select: min(question.closes_at)))
  end

  # A closed permission request leaves every list (`Message.listed?/1`), so a thread's parent
  # channel also hears that the thread lost a reply.
  defp broadcast_closed(message, reason) do
    Topics.broadcast_channel(message.channel_id, {:question_closed, message, reason})
    unless Message.listed?(message), do: ThreadFollows.broadcast_message_unlisted(message)
  end

  defp due_questions do
    from(question in Question,
      join: message in Message,
      on: message.id == question.message_id,
      where:
        is_nil(question.closed_at) and not is_nil(question.closes_at) and
          is_nil(message.deleted_at)
    )
  end

  @doc """
  The results of a loaded question (options and answers with users), as `viewer_id` sees them.
  Each option has its `count` and its `answerers`; an anonymous poll gives `answerers: nil` and
  Other answers without their authors, so only counts and the answers' text show. `mine` is the
  viewer's own answer or nil.
  """
  def results(%Question{} = question, viewer_id) do
    answers = question.answers

    options =
      Enum.map(question.options, fn option ->
        chosen_by = Enum.filter(answers, &(option.id in &1.option_ids))

        %{
          id: option.id,
          label: option.label,
          kind: option.kind,
          count: length(chosen_by),
          answerers: unless(question.anonymous, do: Enum.map(chosen_by, & &1.user))
        }
      end)

    other =
      if question.allow_other do
        other_answers =
          for answer <- answers, answer.other_text do
            %{text: answer.other_text, user: unless(question.anonymous, do: answer.user)}
          end

        %{count: length(other_answers), answers: other_answers}
      end

    %{
      options: options,
      other: other,
      answer_count: length(answers),
      mine: Enum.find(answers, &(&1.user_id == viewer_id)),
      closed?: Question.closed?(question)
    }
  end

  # The decision, then the message row lock, then (by the caller) the question row lock: the
  # order every message write takes, so a delete and an answer queue behind each other.
  defp authorize_question_write(scope, action, message_id) do
    with {:ok, message_id} <- Ids.cast(message_id),
         :ok <- Visibility.authorize_write(scope, action, %Message{id: message_id}) do
      case MessageRows.lock_live_message(message_id) do
        %Message{} = message -> {:ok, message}
        nil -> {:error, :not_found}
      end
    end
  end

  defp lock_question(message_id),
    do:
      Repo.one(
        from(question in Question, where: question.message_id == ^message_id, lock: "FOR UPDATE")
      )

  defp ensure_open(question, now),
    do: if(Question.closed?(question, now), do: {:error, :question_closed}, else: :ok)

  defp ensure_listed(scope, %Question{} = question) do
    if Question.narrowed?(question) do
      role_ids =
        case Visibility.member(scope) do
          nil -> []
          member -> Enum.map(member.member_roles, & &1.role_id)
        end

      if Question.listed_answerer?(question, scope.user_id, role_ids),
        do: :ok,
        else: {:error, :forbidden}
    else
      :ok
    end
  end

  # A choice names options of this question, at most one answer for a single-choice question,
  # and Other text only where the question allows it. A prompt's answer closes it, so an empty
  # choice there would close it with no answer: only a poll's vote can be withdrawn.
  defp parse_choice(%Question{} = question, choice) do
    option_ids = choice |> choice_field("option_ids") |> List.wrap() |> Enum.uniq()
    other_text = choice |> choice_field("other_text") |> clean_other_text()

    question_option_ids =
      question |> Repo.preload(:options) |> Map.fetch!(:options) |> Enum.map(& &1.id)

    picks = length(option_ids) + if(other_text, do: 1, else: 0)

    cond do
      not Enum.all?(option_ids, &(&1 in question_option_ids)) -> {:error, :invalid_choice}
      other_text && not question.allow_other -> {:error, :invalid_choice}
      other_text && String.length(other_text) > 200 -> {:error, :invalid_choice}
      picks > 1 and not question.multi_select -> {:error, :invalid_choice}
      picks == 0 and Question.prompt?(question) -> {:error, :invalid_choice}
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

  defp write_answer(question, user_id, %{option_ids: [], other_text: nil}) do
    Repo.delete_all(
      from(answer in QuestionAnswer,
        where: answer.question_id == ^question.id and answer.user_id == ^user_id
      )
    )

    :ok
  end

  defp write_answer(question, user_id, answer) do
    now = DateTime.utc_now()

    Repo.insert!(
      %QuestionAnswer{
        question_id: question.id,
        user_id: user_id,
        option_ids: answer.option_ids,
        other_text: answer.other_text,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [
        set: [option_ids: answer.option_ids, other_text: answer.other_text, updated_at: now]
      ],
      conflict_target: [:question_id, :user_id]
    )

    :ok
  end

  # Under the question row lock the answer count is exact, so the answer that reaches the limit is
  # the one that closes the question.
  defp close_at_limit(%Question{max_answers: nil}, _now), do: false

  defp close_at_limit(%Question{max_answers: max_answers} = question, now) do
    answers =
      Repo.aggregate(
        from(answer in QuestionAnswer, where: answer.question_id == ^question.id),
        :count
      )

    if answers >= max_answers do
      mark_closed!(question, now)
      true
    else
      false
    end
  end

  defp mark_closed!(question, at),
    do: question |> Ecto.Changeset.change(closed_at: at) |> Repo.update!()

  # Each option arrives as `%{"label" => text}`, with `"kind"` on a permission request's options.
  # Labels are trimmed, blank ones dropped and duplicates (ignoring case) removed, so the length
  # check counts distinct options.
  defp clean_options(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :options) do
      {:ok, options} ->
        case parse_options(options) do
          {:ok, options} ->
            Ecto.Changeset.put_change(changeset, :options, options)

          {:error, message} ->
            Ecto.Changeset.add_error(changeset, :options, message)
        end

      :error ->
        changeset
    end
  end

  defp parse_options(options) do
    options
    |> Enum.reduce_while({:ok, []}, fn option, {:ok, parsed} ->
      case parse_option(option) do
        {:ok, option} -> {:cont, {:ok, [option | parsed]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} ->
        options =
          parsed
          |> Enum.reverse()
          |> Enum.reject(&(&1.label == ""))
          |> Enum.uniq_by(&String.downcase(&1.label))

        if Enum.any?(options, &(String.length(&1.label) > 80)),
          do: {:error, "each option is at most 80 characters"},
          else: {:ok, options}

      error ->
        error
    end
  end

  defp parse_option(option) when is_map(option) do
    label = option["label"] || option[:label]
    kind = option["kind"] || option[:kind]

    with true <- is_binary(label),
         {:ok, kind} <- cast_option_kind(kind) do
      {:ok, %{label: String.trim(label), kind: kind}}
    else
      _ ->
        {:error,
         "each option needs a label, and a kind only from allow_once, allow_always or reject"}
    end
  end

  defp parse_option(_option), do: {:error, "each option is an object with a label"}

  defp cast_option_kind(nil), do: {:ok, nil}

  defp cast_option_kind(kind) do
    case Ecto.Type.cast(@option_kind_type, kind) do
      {:ok, kind} -> {:ok, kind}
      :error -> :error
    end
  end
end
