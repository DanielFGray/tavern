defmodule TavernWeb.ServerLive.Events.Questions do
  @moduledoc """
  The poll form above the composer, and the answers on question cards (polls, asks and permission
  requests). A poll goes to the conversation the composer writes to: the open thread, or else the
  open channel.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias TavernWeb.ServerComponents.Questions, as: QuestionComponents
  alias TavernWeb.ServerLive.Events.Helpers
  alias TavernWeb.ServerLive.State

  @events ~w(
    open_poll
    cancel_poll
    validate_poll
    add_poll_option
    remove_poll_option
    create_poll
    answer_question
    answer_question_other
    send_answer
    withdraw_answer
    close_question
  )

  def events, do: @events

  def handle_info({event, message, _detail}, socket)
      when event in [:question_answered, :question_closed],
      do: {:noreply, State.stream_update_message(socket, message)}

  def handle_event("open_poll", _params, socket) do
    form = if socket.assigns.poll_form, do: nil, else: QuestionComponents.new_poll_form()
    {:noreply, put_poll_form(socket, form)}
  end

  def handle_event("cancel_poll", _params, socket),
    do: {:noreply, put_poll_form(socket, nil)}

  def handle_event("validate_poll", %{"poll" => params}, socket),
    do: {:noreply, put_poll_form(socket, QuestionComponents.poll_form(params))}

  def handle_event("add_poll_option", _params, socket) do
    {:noreply, update_options(socket, &(&1 ++ [""]))}
  end

  def handle_event("remove_poll_option", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {index, ""} -> {:noreply, update_options(socket, &List.delete_at(&1, index))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("create_poll", %{"poll" => params}, socket) do
    case socket.assigns.active_thread || socket.assigns.active_channel do
      nil ->
        {:noreply, put_flash(socket, :error, "Choose a channel before sending a poll.")}

      conversation ->
        case Chat.create_question(
               socket.assigns.current_scope,
               conversation.id,
               QuestionComponents.poll_params(params)
             ) do
          {:ok, message} ->
            {:noreply,
             socket
             |> put_poll_form(nil)
             |> State.insert_message(message)}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_poll_form(socket, QuestionComponents.poll_form(params, :insert))}

          {:error, {:slowmode, seconds_left}} ->
            {:noreply, put_flash(socket, :error, Helpers.slowmode_message(seconds_left))}

          {:error, {:rate_limited, seconds_left}} ->
            {:noreply, put_flash(socket, :error, Helpers.send_limit_message(seconds_left))}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, "You do not have permission to send a poll here.")}
        end
    end
  end

  # Picking an option: in a single-choice question it replaces the answer, and picking the chosen
  # option again withdraws it; in a multi-select question it toggles that option and keeps the
  # rest.
  def handle_event("answer_question", %{"id" => message_id, "option" => option_id}, socket) do
    with_question(socket, message_id, fn message, mine ->
      option_ids = if mine, do: mine.option_ids, else: []
      chosen? = option_id in option_ids

      choice =
        cond do
          message.question.multi_select and chosen? ->
            %{"option_ids" => List.delete(option_ids, option_id), "other_text" => other(mine)}

          message.question.multi_select ->
            %{"option_ids" => option_ids ++ [option_id], "other_text" => other(mine)}

          chosen? ->
            %{"option_ids" => []}

          true ->
            %{"option_ids" => [option_id]}
        end

      Chat.answer_question(socket.assigns.current_scope, message.id, choice)
    end)
  end

  # An Other answer: alone in a single-choice question, beside the chosen options in a
  # multi-select one. Blank text removes the Other answer.
  def handle_event(
        "answer_question_other",
        %{"message_id" => message_id, "other_text" => text},
        socket
      ) do
    with_question(socket, message_id, fn message, mine ->
      option_ids = if message.question.multi_select && mine, do: mine.option_ids, else: []

      Chat.answer_question(socket.assigns.current_scope, message.id, %{
        "option_ids" => option_ids,
        "other_text" => text
      })
    end)
  end

  # A multi-select ask's form: the checked options and the Other text, sent as one answer.
  def handle_event("send_answer", %{"message_id" => message_id} = params, socket) do
    with_question(socket, message_id, fn message, _mine ->
      Chat.answer_question(socket.assigns.current_scope, message.id, %{
        "option_ids" => Map.get(params, "option_ids", []),
        "other_text" => params["other_text"]
      })
    end)
  end

  def handle_event("withdraw_answer", %{"id" => message_id}, socket) do
    with_question(socket, message_id, fn message, _mine ->
      Chat.answer_question(socket.assigns.current_scope, message.id, %{"option_ids" => []})
    end)
  end

  def handle_event("close_question", %{"id" => message_id}, socket) do
    with_question(socket, message_id, fn message, _mine ->
      Chat.close_question(socket.assigns.current_scope, message.id)
    end)
  end

  defp with_question(socket, message_id, write) do
    with {:ok, %{question: %Tavern.Chat.Question{} = question} = message} <-
           State.fetch_open_message(socket, message_id),
         mine = Chat.question_results(question, socket.assigns.current_user.id).mine,
         {:ok, updated} <- write.(message, mine) do
      {:noreply, State.stream_update_message(socket, updated)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      _ -> {:noreply, socket}
    end
  end

  defp other(nil), do: nil
  defp other(mine), do: mine.other_text

  defp refusal(:question_closed), do: "This question has closed."
  defp refusal(:invalid_choice), do: "That answer does not fit this question."
  defp refusal(_reason), do: "You cannot answer this question."

  # The thread composer renders inside the starter message's stream row, so a change to the form
  # renders that row again.
  defp put_poll_form(socket, form),
    do: socket |> assign(:poll_form, form) |> State.rerender_active_thread_panel()

  defp update_options(socket, change) do
    form = socket.assigns.poll_form
    options = form.params["options"] || ["", ""]
    options = options |> change.() |> Enum.take(10)

    options =
      if length(options) < 2,
        do: options ++ List.duplicate("", 2 - length(options)),
        else: options

    put_poll_form(
      socket,
      QuestionComponents.poll_form(Map.put(form.params, "options", options))
    )
  end
end
