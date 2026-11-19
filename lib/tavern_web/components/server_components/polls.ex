defmodule TavernWeb.ServerComponents.Polls do
  @moduledoc """
  The poll card in a message row and the poll form the composer opens (docs/design/polls.md).
  The card only offers what the server would allow; `Tavern.Chat.Polls` decides every vote.
  """
  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  alias Phoenix.LiveView.JS
  alias Tavern.Chat
  alias Tavern.Chat.Poll

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

  @doc "A poll: its question, options with live counts and voters, Other answers and its state."
  def poll_card(assigns) do
    poll = assigns.message.poll
    user = assigns.server.current_user
    results = Chat.poll_results(poll, user.id)
    role_ids = Enum.map(user.member_roles, & &1.role_id)

    assigns =
      assign(assigns,
        poll: poll,
        results: results,
        can_vote?: can_vote?(assigns.server, assigns.rights, poll, results, user.id, role_ids),
        can_close?:
          not results.closed? and (own_message?(assigns.message, user) or assigns.rights.manage?)
      )

    ~H"""
    <section
      id={"poll-#{@message.id}"}
      data-closed={to_string(@results.closed?)}
      class="mt-2 max-w-lg rounded-xl border border-base-300 bg-base-100 p-3 shadow-sm"
    >
      <header class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] font-semibold uppercase tracking-wide text-base-content/55">
        <.icon name="hero-chart-bar" class="size-3.5 text-violet-300" />
        <span>Poll</span>
        <span>·</span>
        <span>{if(@poll.multi_select, do: "Choose any", else: "Choose one")}</span>
        <span :if={@poll.anonymous}>· Anonymous</span>
      </header>

      <h3 class="mt-1.5 break-words text-[15px] font-semibold leading-6 text-base-content">
        {@message.body}
      </h3>

      <ul id={"poll-options-#{@message.id}"} class="mt-2 grid gap-1.5">
        <li :for={option <- @results.options}>
          <button
            type="button"
            id={"poll-option-#{option.id}"}
            phx-click="vote_poll"
            phx-value-id={@message.id}
            phx-value-option={option.id}
            disabled={!@can_vote?}
            aria-pressed={to_string(chosen?(@results, option.id))}
            class={[
              "group/option relative w-full overflow-hidden rounded-lg border px-3 py-2 text-left transition",
              chosen?(@results, option.id) && "border-violet-400/70 bg-violet-500/10",
              !chosen?(@results, option.id) && "border-base-300 bg-base-200/60",
              @can_vote? && "hover:border-violet-400/50 hover:bg-base-200",
              !@can_vote? && "cursor-default"
            ]}
          >
            <span
              class="absolute inset-y-0 left-0 bg-violet-500/15 transition-[width] duration-500 ease-out"
              style={"width: #{percent(option.count, @results.voter_count)}%"}
            />
            <span class="relative flex items-center gap-2">
              <span class={[
                "flex size-4 shrink-0 items-center justify-center border transition",
                if(@poll.multi_select, do: "rounded", else: "rounded-full"),
                chosen?(@results, option.id) && "border-violet-300 bg-violet-400 text-base-100",
                !chosen?(@results, option.id) && "border-base-content/30"
              ]}>
                <.icon :if={chosen?(@results, option.id)} name="hero-check-mini" class="size-3" />
              </span>
              <span class="min-w-0 flex-1 break-words text-sm text-base-content">
                {option.label}
              </span>
              <span
                id={"poll-option-count-#{option.id}"}
                class="shrink-0 text-xs font-semibold tabular-nums text-base-content/70"
              >
                {option.count}
              </span>
            </span>
            <span
              :if={option.voters not in [nil, []]}
              id={"poll-option-voters-#{option.id}"}
              class="relative mt-1 block truncate pl-6 text-[11px] text-base-content/55"
            >
              {voter_names(option.voters)}
            </span>
          </button>
        </li>

        <li :if={@results.other}>
          <button
            type="button"
            id={"poll-other-#{@message.id}"}
            phx-click={JS.toggle(to: "#poll-other-form-#{@message.id}")}
            disabled={!@can_vote?}
            aria-pressed={to_string(other_chosen?(@results))}
            class={[
              "relative w-full rounded-lg border px-3 py-2 text-left transition",
              other_chosen?(@results) && "border-violet-400/70 bg-violet-500/10",
              !other_chosen?(@results) && "border-dashed border-base-300 bg-base-200/40",
              @can_vote? && "hover:border-violet-400/50",
              !@can_vote? && "cursor-default"
            ]}
          >
            <span class="flex items-center gap-2">
              <.icon name="hero-pencil-square" class="size-4 shrink-0 text-base-content/50" />
              <span class="flex-1 text-sm text-base-content">Other</span>
              <span class="text-xs font-semibold tabular-nums text-base-content/70">
                {@results.other.count}
              </span>
            </span>
          </button>

          <.form
            :if={@can_vote?}
            for={%{}}
            as={:other}
            id={"poll-other-form-#{@message.id}"}
            phx-submit="vote_poll_other"
            class="mt-1.5 hidden"
          >
            <input type="hidden" name="message_id" value={@message.id} />
            <div class="flex gap-1.5">
              <input
                type="text"
                name="other_text"
                id={"poll-other-text-#{@message.id}"}
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
            id={"poll-other-answers-#{@message.id}"}
            class="mt-1.5 grid gap-1 pl-6"
          >
            <li
              :for={answer <- @results.other.answers}
              class="break-words text-xs text-base-content/75"
            >
              <span :if={answer.user} class="font-semibold text-base-content/85">
                {answer.user.display_name}:
              </span>
              {answer.text}
            </li>
          </ul>
        </li>
      </ul>

      <footer class="mt-2.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/55">
        <span id={"poll-voter-count-#{@message.id}"}>{voter_count_label(@results.voter_count)}</span>
        <span
          id={"poll-status-#{@message.id}"}
          class={@results.closed? && "font-semibold text-base-content/75"}
        >
          {status_label(@poll, @results)}
        </span>
        <span :if={Poll.narrowed?(@poll)}>Only named members can vote</span>
        <span class="flex-1" />
        <button
          :if={@can_vote? and @results.mine}
          type="button"
          id={"poll-withdraw-#{@message.id}"}
          phx-click="withdraw_poll_vote"
          phx-value-id={@message.id}
          class="rounded px-1.5 py-0.5 font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          Remove vote
        </button>
        <button
          :if={@can_close?}
          type="button"
          id={"poll-close-#{@message.id}"}
          phx-click="close_poll"
          phx-value-id={@message.id}
          data-confirm="End this poll now?"
          class="rounded px-1.5 py-0.5 font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          End poll
        </button>
      </footer>
    </section>
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
    |> Chat.change_poll()
    |> Map.put(:action, action)
    |> to_form(as: :poll)
  end

  # The option inputs render from the raw params, so an empty input the user just added stays.
  defp option_values(form) do
    case form.params["options"] do
      options when is_list(options) and options != [] -> options
      _ -> ["", ""]
    end
  end

  defp poll_errors(form, field) do
    if form.source.action,
      do: Enum.map(form[field].errors, &translate_error/1),
      else: []
  end

  # A vote needs a send in this conversation, an open thread (or a manager), the poll's voter
  # list and an open poll. The server decides the same rules in the vote's transaction.
  defp can_vote?(server, rights, poll, results, user_id, role_ids) do
    thread_open? =
      not rights.thread? or rights.manage? or
        (is_nil(server.active_thread.archived_at) and is_nil(server.active_thread.locked_at))

    rights.send? and thread_open? and not results.closed? and
      Poll.listed_voter?(poll, user_id, role_ids)
  end

  defp chosen?(%{mine: nil}, _option_id), do: false
  defp chosen?(%{mine: mine}, option_id), do: option_id in mine.option_ids

  defp other_chosen?(%{mine: nil}), do: false
  defp other_chosen?(%{mine: mine}), do: not is_nil(mine.other_text)

  defp percent(_count, 0), do: 0
  defp percent(count, voters), do: round(count * 100 / voters)

  defp voter_names(voters) do
    {shown, rest} = Enum.split(voters, 3)
    names = Enum.map_join(shown, ", ", & &1.display_name)
    if rest == [], do: names, else: "#{names} +#{length(rest)}"
  end

  defp voter_count_label(1), do: "1 vote"
  defp voter_count_label(count), do: "#{count} votes"

  defp status_label(poll, %{closed?: true}),
    do: "Closed #{message_timestamp(poll.closed_at || poll.closes_at)}"

  defp status_label(%Poll{closes_at: nil}, _results), do: "Open until ended"

  defp status_label(%Poll{closes_at: closes_at}, _results),
    do: "Ends #{message_timestamp(closes_at)}"
end
