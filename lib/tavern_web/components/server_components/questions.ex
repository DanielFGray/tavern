defmodule TavernWeb.ServerComponents.Questions do
  @moduledoc """
  The question card in a message row (a poll, an ask or a permission request) and the poll form
  the composer opens (docs/design/questions.md). Every card draws its options with
  `question_options/1`; the poll card adds the counts and voters, the prompt cards do not. A card
  only offers what the server would allow; `Tavern.Chat.Questions` decides every answer.
  """
  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  alias Phoenix.LiveView.JS
  alias Tavern.Chat
  alias Tavern.Chat.Question

  @durations [
    {"Until I end it", ""},
    {"1 hour", 60},
    {"4 hours", 240},
    {"8 hours", 480},
    {"24 hours", 1440},
    {"3 days", 4320},
    {"7 days", 10080}
  ]

  attr :message, :map, required: true
  attr :server, :map, required: true
  attr :rights, :map, required: true

  @doc "The card for the message's question, by its kind."
  def question_card(assigns) do
    question = assigns.message.question
    user = assigns.server.current_user
    results = Chat.question_results(question, user.id)
    role_ids = Enum.map(user.member_roles, & &1.role_id)

    assigns =
      assign(assigns,
        question: question,
        results: results,
        can_answer?:
          can_answer?(assigns.server, assigns.rights, question, results, user.id, role_ids),
        can_close?:
          not results.closed? and (own_message?(assigns.message, user) or assigns.rights.manage?)
      )

    case question.kind do
      :poll -> poll_card(assigns)
      :ask -> ask_card(assigns)
      :permission -> permission_card(assigns)
    end
  end

  # A poll: its question, options with live counts and voters, Other answers and its state.
  defp poll_card(assigns) do
    ~H"""
    <section
      id={"question-#{@message.id}"}
      data-kind="poll"
      data-closed={to_string(@results.closed?)}
      class="mt-2 max-w-lg rounded-xl border border-base-300 bg-base-100 p-3 shadow-sm"
    >
      <header class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] font-semibold uppercase tracking-wide text-base-content/55">
        <.icon name="hero-chart-bar" class="size-3.5 text-violet-300" />
        <span>Poll</span>
        <span>·</span>
        <span>{if(@question.multi_select, do: "Choose any", else: "Choose one")}</span>
        <span :if={@question.anonymous}>· Anonymous</span>
      </header>

      <h3 class="mt-1.5 break-words text-[15px] font-semibold leading-6 text-base-content">
        {@message.body}
      </h3>

      <.question_options
        message={@message}
        question={@question}
        results={@results}
        can_answer?={@can_answer?}
        tally?={true}
      />

      <footer class="mt-2.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/55">
        <span id={"question-answer-count-#{@message.id}"}>
          {vote_count_label(@results.answer_count)}
        </span>
        <span
          id={"question-status-#{@message.id}"}
          class={@results.closed? && "font-semibold text-base-content/75"}
        >
          {poll_status_label(@question, @results)}
        </span>
        <span :if={Question.narrowed?(@question)}>Only named members can vote</span>
        <span class="flex-1" />
        <button
          :if={@can_answer? and @results.mine}
          type="button"
          id={"question-withdraw-#{@message.id}"}
          phx-click="withdraw_answer"
          phx-value-id={@message.id}
          class="rounded px-1.5 py-0.5 font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          Remove vote
        </button>
        <.close_button
          :if={@can_close?}
          message={@message}
          label="End poll"
          confirm="End this poll now?"
        />
      </footer>
    </section>
    """
  end

  # A bot's question to one member: the text as Markdown and the options, with no counts or
  # voters. Once answered it marks the answer and says who gave it.
  defp ask_card(assigns) do
    ~H"""
    <section
      id={"question-#{@message.id}"}
      data-kind="ask"
      data-closed={to_string(@results.closed?)}
      class="mt-2 max-w-lg rounded-xl border border-base-300 bg-base-100 p-3 shadow-sm"
    >
      <header class="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-base-content/55">
        <.icon name="hero-chat-bubble-left-ellipsis" class="size-3.5 text-info" />
        <span>Question</span>
        <span :if={@question.multi_select}>· Choose any</span>
      </header>

      <div
        class={["message-body mt-1.5", message_body_classes()]}
        data-markdown-source={@message.body}
      >
        {@message.body}
      </div>

      <%= if @question.multi_select and @can_answer? do %>
        <.answer_form message={@message} question={@question} results={@results} />
      <% else %>
        <.question_options
          message={@message}
          question={@question}
          results={@results}
          can_answer?={@can_answer?}
          tally?={false}
        />
      <% end %>

      <.prompt_footer message={@message} results={@results} can_close?={@can_close?} />
    </section>
    """
  end

  attr :message, :map, required: true
  attr :question, :map, required: true
  attr :results, :map, required: true

  # A multi-select ask closes on its first answer, so a click cannot send each option as it is
  # picked. The member checks the options here, adds Other text if allowed, and sends them as one
  # answer. Until then the checks live only in the browser, so the form ignores patches: a
  # re-render of the row would clear them. Once answered, the card renders the options instead.
  defp answer_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:answer}
      id={"question-answer-form-#{@message.id}"}
      phx-submit="send_answer"
      phx-update="ignore"
      class="mt-2 grid gap-1.5"
    >
      <input type="hidden" name="message_id" value={@message.id} />
      <label
        :for={option <- @results.options}
        id={"question-option-#{option.id}"}
        class="flex cursor-pointer items-center gap-2 rounded-lg border border-base-300 bg-base-200/40 px-3 py-2 transition hover:border-violet-400/50 has-checked:border-violet-400/70 has-checked:bg-violet-500/10"
      >
        <input
          type="checkbox"
          name="option_ids[]"
          value={option.id}
          id={"question-option-check-#{option.id}"}
          class="size-4 shrink-0 rounded accent-violet-500"
        />
        <span class="min-w-0 flex-1 break-words text-sm text-base-content">{option.label}</span>
      </label>
      <input
        :if={@question.allow_other}
        type="text"
        name="other_text"
        id={"question-other-text-#{@message.id}"}
        maxlength="200"
        placeholder="Other answer"
        class="min-w-0 rounded-lg border border-dashed border-base-300 bg-base-200/40 px-3 py-2 text-sm text-base-content outline-none transition focus:border-violet-400"
      />
      <div class="flex justify-end">
        <button
          type="submit"
          id={"question-send-#{@message.id}"}
          class="rounded-lg bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400"
        >
          Send answer
        </button>
      </div>
    </.form>
    """
  end

  # A bot's request to run something. Its options carry a kind, so an allow and a reject look
  # apart. A closed request leaves the transcript (docs/design/questions.md), so this card shows
  # only while it waits.
  defp permission_card(assigns) do
    ~H"""
    <section
      id={"question-#{@message.id}"}
      data-kind="permission"
      data-closed={to_string(@results.closed?)}
      class="mt-2 max-w-lg rounded-xl border border-warning/40 bg-base-100 p-3 shadow-sm"
    >
      <header class="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-base-content/55">
        <.icon name="hero-shield-exclamation" class="size-3.5 text-warning" />
        <span>Permission request</span>
      </header>

      <div
        class={["message-body mt-1.5", message_body_classes()]}
        data-markdown-source={@message.body}
      >
        {@message.body}
      </div>

      <.question_options
        message={@message}
        question={@question}
        results={@results}
        can_answer?={@can_answer?}
        tally?={false}
      />

      <.prompt_footer message={@message} results={@results} can_close?={@can_close?} />
    </section>
    """
  end

  attr :message, :map, required: true
  attr :results, :map, required: true
  attr :can_close?, :boolean, required: true

  # A prompt's state: waiting, who answered, or closed with no answer; and Dismiss for the bot's
  # moderators.
  defp prompt_footer(assigns) do
    ~H"""
    <footer class="mt-2.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/55">
      <span
        id={"question-status-#{@message.id}"}
        class={@results.closed? && "font-semibold text-base-content/75"}
      >
        {prompt_status_label(@results)}
      </span>
      <span class="flex-1" />
      <.close_button
        :if={@can_close?}
        message={@message}
        label="Dismiss"
        confirm="Dismiss this request? The bot reads it as no answer."
      />
    </footer>
    """
  end

  attr :message, :map, required: true
  attr :label, :string, required: true
  attr :confirm, :string, required: true

  defp close_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"question-close-#{@message.id}"}
      phx-click="close_question"
      phx-value-id={@message.id}
      data-confirm={@confirm}
      class="rounded px-1.5 py-0.5 font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
    >
      {@label}
    </button>
    """
  end

  attr :message, :map, required: true
  attr :question, :map, required: true
  attr :results, :map, required: true
  attr :can_answer?, :boolean, required: true
  attr :tally?, :boolean, required: true, doc: "show each option's bar, count and voters (a poll)"

  @doc """
  A question's options and its Other answer, shared by every card. A click on an option answers
  with it; with `tally?` each option also shows its share, count and voters.
  """
  def question_options(assigns) do
    ~H"""
    <ul id={"question-options-#{@message.id}"} class="mt-2 grid gap-1.5">
      <li :for={option <- @results.options}>
        <button
          type="button"
          id={"question-option-#{option.id}"}
          phx-click="answer_question"
          phx-value-id={@message.id}
          phx-value-option={option.id}
          disabled={!@can_answer?}
          data-option-kind={option.kind}
          aria-pressed={to_string(chosen?(@results, option.id))}
          class={[
            "group/option relative w-full overflow-hidden rounded-lg border px-3 py-2 text-left transition",
            option_classes(option.kind, chosen?(@results, option.id), @can_answer?)
          ]}
        >
          <span
            :if={@tally?}
            class="absolute inset-y-0 left-0 bg-violet-500/15 transition-[width] duration-500 ease-out"
            style={"width: #{percent(option.count, @results.answer_count)}%"}
          />
          <span class="relative flex items-center gap-2">
            <span class={[
              "flex size-4 shrink-0 items-center justify-center border transition",
              if(@question.multi_select, do: "rounded", else: "rounded-full"),
              mark_classes(option.kind, chosen?(@results, option.id))
            ]}>
              <.icon :if={chosen?(@results, option.id)} name="hero-check-mini" class="size-3" />
            </span>
            <span class="min-w-0 flex-1 break-words text-sm text-base-content">
              {option.label}
            </span>
            <span
              :if={@tally?}
              id={"question-option-count-#{option.id}"}
              class="shrink-0 text-xs font-semibold tabular-nums text-base-content/70"
            >
              {option.count}
            </span>
          </span>
          <span
            :if={@tally? and option.answerers not in [nil, []]}
            id={"question-option-voters-#{option.id}"}
            class="relative mt-1 block truncate pl-6 text-[11px] text-base-content/55"
          >
            {answerer_names(option.answerers)}
          </span>
        </button>
      </li>

      <li :if={@results.other}>
        <button
          type="button"
          id={"question-other-#{@message.id}"}
          phx-click={JS.toggle(to: "#question-other-form-#{@message.id}")}
          disabled={!@can_answer?}
          aria-pressed={to_string(other_chosen?(@results))}
          class={[
            "relative w-full rounded-lg border px-3 py-2 text-left transition",
            other_chosen?(@results) && "border-violet-400/70 bg-violet-500/10",
            !other_chosen?(@results) && "border-dashed border-base-300 bg-base-200/40",
            @can_answer? && "hover:border-violet-400/50",
            !@can_answer? && "cursor-default"
          ]}
        >
          <span class="flex items-center gap-2">
            <.icon name="hero-pencil-square" class="size-4 shrink-0 text-base-content/50" />
            <span class="flex-1 text-sm text-base-content">Other</span>
            <span
              :if={@tally?}
              class="text-xs font-semibold tabular-nums text-base-content/70"
            >
              {@results.other.count}
            </span>
          </span>
        </button>

        <.form
          :if={@can_answer?}
          for={%{}}
          as={:other}
          id={"question-other-form-#{@message.id}"}
          phx-submit="answer_question_other"
          class="mt-1.5 hidden"
        >
          <input type="hidden" name="message_id" value={@message.id} />
          <div class="flex gap-1.5">
            <input
              type="text"
              name="other_text"
              id={"question-other-text-#{@message.id}"}
              value={@results.mine && @results.mine.other_text}
              maxlength="200"
              placeholder="Your answer"
              class="min-w-0 flex-1 rounded-lg border border-base-300 bg-base-200 px-3 py-1.5 text-sm text-base-content outline-none transition focus:border-violet-400"
            />
            <button
              type="submit"
              class="rounded-lg bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400"
            >
              Answer
            </button>
          </div>
        </.form>

        <ul
          :if={@results.other.answers != []}
          id={"question-other-answers-#{@message.id}"}
          class="mt-1.5 grid gap-1 pl-6"
        >
          <li
            :for={answer <- @results.other.answers}
            class="break-words text-xs text-base-content/75"
          >
            <span :if={@tally? and answer.user} class="font-semibold text-base-content/85">
              {answer.user.display_name}:
            </span>
            {answer.text}
          </li>
        </ul>
      </li>
    </ul>
    """
  end

  attr :server, :map, required: true

  @doc """
  The form for a new poll, shown above the composer. It writes to the conversation the composer
  writes to: the open thread, or the open channel.
  """
  def poll_composer(assigns) do
    assigns =
      assign(assigns,
        form: assigns.server.poll_form,
        option_values: option_values(assigns.server.poll_form),
        durations: @durations
      )

    ~H"""
    <.form
      for={@form}
      id="poll-form"
      phx-change="validate_poll"
      phx-submit="create_poll"
      class="mb-2 rounded-lg border border-base-300 bg-base-100 p-3 shadow-sm"
    >
      <div class="flex items-center justify-between">
        <p class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          <.icon name="hero-chart-bar" class="size-4 text-violet-300" /> New poll
        </p>
        <button
          type="button"
          id="cancel-poll-button"
          phx-click="cancel_poll"
          aria-label="Cancel poll"
          class="inline-flex size-7 items-center justify-center rounded-md text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <.input
        field={@form[:question]}
        id="poll-question"
        label="Question"
        placeholder="Ask something"
        maxlength="300"
        autocomplete="off"
      />

      <fieldset class="mt-1">
        <legend class="mb-1 text-sm font-medium text-base-content/80">Options</legend>
        <div id="poll-option-inputs" class="grid gap-1.5">
          <div :for={{value, index} <- Enum.with_index(@option_values)} class="flex gap-1.5">
            <input
              type="text"
              name={@form[:options].name <> "[]"}
              id={"poll-option-input-#{index}"}
              value={value}
              maxlength="80"
              placeholder={"Option #{index + 1}"}
              autocomplete="off"
              class="min-w-0 flex-1 rounded-lg border border-base-300 bg-base-200 px-3 py-1.5 text-sm text-base-content outline-none transition focus:border-violet-400"
            />
            <button
              :if={length(@option_values) > 2}
              type="button"
              id={"remove-poll-option-#{index}"}
              phx-click="remove_poll_option"
              phx-value-index={index}
              aria-label={"Remove option #{index + 1}"}
              class="inline-flex size-8 shrink-0 items-center justify-center rounded-md text-base-content/50 transition hover:bg-base-200 hover:text-base-content"
            >
              <.icon name="hero-minus-circle" class="size-4" />
            </button>
          </div>
        </div>
        <p :for={error <- poll_errors(@form, :options)} class="mt-1 text-xs text-error">{error}</p>
        <button
          :if={length(@option_values) < 10}
          type="button"
          id="add-poll-option"
          phx-click="add_poll_option"
          class="mt-1.5 inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs font-semibold text-violet-300 transition hover:bg-violet-500/10"
        >
          <.icon name="hero-plus" class="size-3.5" /> Add option
        </button>
      </fieldset>

      <div class="mt-2 grid gap-x-4 sm:grid-cols-2">
        <.input
          field={@form[:duration_minutes]}
          id="poll-duration"
          type="select"
          label="Ends"
          options={@durations}
        />
        <div class="grid content-start gap-0.5 pt-1">
          <.input
            field={@form[:multi_select]}
            id="poll-multi-select"
            type="checkbox"
            label="Allow several answers"
          />
          <.input
            field={@form[:allow_other]}
            id="poll-allow-other"
            type="checkbox"
            label="Add an Other answer"
          />
          <.input
            field={@form[:anonymous]}
            id="poll-anonymous"
            type="checkbox"
            label="Hide who voted"
          />
        </div>
      </div>

      <div class="mt-2 flex justify-end">
        <button
          type="submit"
          id="send-poll-button"
          class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400"
        >
          Send poll
        </button>
      </div>
    </.form>
    """
  end

  @doc "A blank poll form: two empty options, open for 24 hours."
  def new_poll_form,
    do: poll_form(%{"options" => ["", ""], "duration_minutes" => "1440"})

  @doc "The poll form for `params`; `action` set shows the errors."
  def poll_form(params, action \\ nil) do
    params
    |> poll_params()
    |> Chat.change_question()
    |> Map.put(:action, action)
    |> to_form(as: :poll)
  end

  @doc """
  The question attributes for the poll form's `params`. The form sends each option as a plain
  label, and a person sends only polls, so the kind is set here and never read from the form.
  Params this already shaped pass through unchanged.
  """
  def poll_params(params) do
    options =
      case params["options"] do
        options when is_list(options) -> Enum.map(options, &%{"label" => option_label(&1)})
        _ -> nil
      end

    params
    |> Map.put("kind", "poll")
    |> Map.put("options", options)
  end

  # The option inputs render from the raw params, so an empty input the user just added stays.
  defp option_values(form) do
    case form.params["options"] do
      [_ | _] = options -> Enum.map(options, &option_label/1)
      _ -> ["", ""]
    end
  end

  defp option_label(%{"label" => label}), do: label
  defp option_label(label), do: label

  defp poll_errors(form, field) do
    if form.source.action,
      do: Enum.map(form[field].errors, &translate_error/1),
      else: []
  end

  # An answer needs a send in this conversation, an open thread (or a manager), the question's
  # answerer list and an open question. The server decides the same rules in the answer's
  # transaction.
  defp can_answer?(server, rights, question, results, user_id, role_ids) do
    thread_open? =
      not rights.thread? or rights.manage? or
        (is_nil(server.active_thread.archived_at) and is_nil(server.active_thread.locked_at))

    rights.send? and thread_open? and not results.closed? and
      Question.listed_answerer?(question, user_id, role_ids)
  end

  defp chosen?(%{mine: nil}, _option_id), do: false
  defp chosen?(%{mine: mine}, option_id), do: option_id in mine.option_ids

  defp other_chosen?(%{mine: nil}), do: false
  defp other_chosen?(%{mine: mine}), do: not is_nil(mine.other_text)

  # A permission option is tinted by what it does: an allow in the success colour, a reject in
  # the error colour. Other options use the poll's violet.
  defp option_classes(kind, chosen?, can_answer?) do
    {chosen, idle, hover} =
      case kind do
        kind when kind in [:allow_once, :allow_always] ->
          {"border-success/70 bg-success/15", "border-success/40 bg-success/5",
           "hover:border-success/70 hover:bg-success/10"}

        :reject ->
          {"border-error/70 bg-error/15", "border-error/40 bg-error/5",
           "hover:border-error/70 hover:bg-error/10"}

        nil ->
          {"border-violet-400/70 bg-violet-500/10", "border-base-300 bg-base-200/60",
           "hover:border-violet-400/50 hover:bg-base-200"}
      end

    [
      if(chosen?, do: chosen, else: idle),
      if(can_answer?, do: hover, else: "cursor-default")
    ]
  end

  defp mark_classes(kind, true) when kind in [:allow_once, :allow_always],
    do: "border-success bg-success text-success-content"

  defp mark_classes(:reject, true), do: "border-error bg-error text-error-content"
  defp mark_classes(nil, true), do: "border-violet-300 bg-violet-400 text-base-100"
  defp mark_classes(_kind, false), do: "border-base-content/30"

  defp percent(_count, 0), do: 0
  defp percent(count, answers), do: round(count * 100 / answers)

  defp answerer_names(answerers) do
    {shown, rest} = Enum.split(answerers, 3)
    names = Enum.map_join(shown, ", ", & &1.display_name)
    if rest == [], do: names, else: "#{names} +#{length(rest)}"
  end

  defp vote_count_label(1), do: "1 vote"
  defp vote_count_label(count), do: "#{count} votes"

  defp poll_status_label(question, %{closed?: true}),
    do: "Closed #{message_timestamp(question.closed_at || question.closes_at)}"

  defp poll_status_label(%Question{closes_at: nil}, _results), do: "Open until ended"

  defp poll_status_label(%Question{closes_at: closes_at}, _results),
    do: "Ends #{message_timestamp(closes_at)}"

  # A prompt closes on its first answer, so a closed prompt has one answer or none.
  defp prompt_status_label(%{closed?: false}), do: "Waiting for an answer"

  defp prompt_status_label(%{closed?: true} = results) do
    case answerer(results) do
      nil -> "Closed without an answer"
      user -> "Answered by #{user.display_name}"
    end
  end

  defp answerer(results) do
    Enum.find_value(results.options, &List.first(&1.answerers || [])) ||
      (results.other && Enum.find_value(results.other.answers, & &1.user))
  end
end
