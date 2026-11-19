defmodule TavernWeb.ServerLive.Events.Polls do
  @moduledoc """
  The poll form above the composer and the votes on poll cards. A poll goes to the conversation
  the composer writes to: the open thread, or else the open channel.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias TavernWeb.ServerComponents.Polls, as: PollComponents
  alias TavernWeb.ServerLive.Events.Helpers
  alias TavernWeb.ServerLive.State

  def handle_info({event, message, _detail}, socket) when event in [:poll_voted, :poll_closed],
    do: {:noreply, State.stream_update_message(socket, message)}

  def handle_event("open_poll", _params, socket) do
    form = if socket.assigns.poll_form, do: nil, else: PollComponents.new_poll_form()
    {:noreply, put_poll_form(socket, form)}
  end

  def handle_event("cancel_poll", _params, socket),
    do: {:noreply, put_poll_form(socket, nil)}

  def handle_event("validate_poll", %{"poll" => params}, socket),
    do: {:noreply, put_poll_form(socket, PollComponents.poll_form(params))}

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
        case Chat.create_poll(socket.assigns.current_scope, conversation.id, params) do
          {:ok, message} ->
            {:noreply,
             socket
             |> put_poll_form(nil)
             |> State.maybe_insert_message(message)
             |> State.maybe_insert_thread_message(message)}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_poll_form(socket, PollComponents.poll_form(params, :insert))}

          {:error, {:slowmode, seconds_left}} ->
            {:noreply, put_flash(socket, :error, Helpers.slowmode_message(seconds_left))}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, "You do not have permission to send a poll here.")}
        end
    end
  end

  # Picking an option: in a single-choice poll it replaces the vote, and picking the chosen option
  # again withdraws it; in a multi-select poll it toggles that option and keeps the rest.
  def handle_event("vote_poll", %{"id" => message_id, "option" => option_id}, socket) do
    with_poll(socket, message_id, fn message, mine ->
      option_ids = if mine, do: mine.option_ids, else: []
      chosen? = option_id in option_ids

      choice =
        cond do
          message.poll.multi_select and chosen? ->
            %{"option_ids" => List.delete(option_ids, option_id), "other_text" => other(mine)}

          message.poll.multi_select ->
            %{"option_ids" => option_ids ++ [option_id], "other_text" => other(mine)}

          chosen? ->
            %{"option_ids" => []}

          true ->
            %{"option_ids" => [option_id]}
        end

      Chat.vote_in_poll(socket.assigns.current_scope, message.id, choice)
    end)
  end

  # An Other answer: alone in a single-choice poll, beside the chosen options in a multi-select
  # one. Blank text removes the Other answer.
  def handle_event("vote_poll_other", %{"message_id" => message_id, "other_text" => text}, socket) do
    with_poll(socket, message_id, fn message, mine ->
      option_ids = if message.poll.multi_select && mine, do: mine.option_ids, else: []

      Chat.vote_in_poll(socket.assigns.current_scope, message.id, %{
        "option_ids" => option_ids,
        "other_text" => text
      })
    end)
  end

  def handle_event("withdraw_poll_vote", %{"id" => message_id}, socket) do
    with_poll(socket, message_id, fn message, _mine ->
      Chat.vote_in_poll(socket.assigns.current_scope, message.id, %{"option_ids" => []})
    end)
  end

  def handle_event("close_poll", %{"id" => message_id}, socket) do
    with_poll(socket, message_id, fn message, _mine ->
      Chat.close_poll(socket.assigns.current_scope, message.id)
    end)
  end

  defp with_poll(socket, message_id, write) do
    with {:ok, %{poll: %Tavern.Chat.Poll{} = poll} = message} <-
           State.fetch_open_message(socket, message_id),
         mine = Chat.poll_results(poll, socket.assigns.current_user.id).mine,
         {:ok, updated} <- write.(message, mine) do
      {:noreply, State.stream_update_message(socket, updated)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      _ -> {:noreply, socket}
    end
  end

  defp other(nil), do: nil
  defp other(mine), do: mine.other_text

  defp refusal(:poll_closed), do: "This poll has closed."
  defp refusal(:invalid_choice), do: "That answer does not fit this poll."
  defp refusal(_reason), do: "You cannot vote in this poll."

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

    put_poll_form(socket, PollComponents.poll_form(Map.put(form.params, "options", options)))
  end
end
