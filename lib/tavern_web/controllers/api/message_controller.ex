defmodule TavernWeb.API.MessageController do
  use TavernWeb, :controller

  alias Tavern.Bots
  alias TavernWeb.API.ErrorHelpers

  def index(conn, %{"channel_id" => channel_id} = params) do
    command_params =
      params
      |> Map.take(["limit", "after", "before"])
      |> Map.put("channel_id", channel_id)

    case Bots.command_list_messages(conn.assigns.current_bot_scope, command_params) do
      {:ok, %{messages: messages}} ->
        render(conn, :index, messages: messages)

      {:error, :forbidden} ->
        ErrorHelpers.render_error(conn, :forbidden, "forbidden", "Bot cannot read that channel.")

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Channel not found.")

      {:error, _} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_params",
          "Invalid message query."
        )
    end
  end

  def create(conn, %{"channel_id" => channel_id, "message" => message_params})
      when is_map(message_params) do
    params = Map.put(message_params, "channel_id", channel_id)

    case Bots.command_send_message(conn.assigns.current_bot_scope, params) do
      {:ok, %{message: message}} ->
        conn
        |> put_status(:created)
        |> render(:show, message: message)

      {:error, :forbidden} ->
        ErrorHelpers.render_error(
          conn,
          :forbidden,
          "forbidden",
          "Bot cannot send to that channel."
        )

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Channel not found.")

      {:error, %Ecto.Changeset{} = changeset} ->
        ErrorHelpers.render_changeset_error(
          conn,
          :unprocessable_entity,
          "invalid_message",
          changeset
        )

      {:error, {:slowmode, seconds_left}} ->
        ErrorHelpers.render_slowmode(conn, seconds_left)

      {:error, {:rate_limited, seconds_left}} ->
        ErrorHelpers.render_rate_limited(conn, seconds_left)

      {:error, reason} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_message",
          to_string(reason)
        )
    end
  end

  def create(conn, _params), do: ErrorHelpers.render_invalid_body(conn)

  def update(conn, %{"channel_id" => channel_id, "message_id" => message_id, "body" => body}) do
    params = %{"channel_id" => channel_id, "message_id" => message_id, "body" => body}

    case Bots.command_edit_message(conn.assigns.current_bot_scope, params) do
      {:ok, %{message: message}} ->
        render(conn, :show, message: message)

      {:error, :forbidden} ->
        ErrorHelpers.render_error(conn, :forbidden, "forbidden", "Bot cannot edit that message.")

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Message not found.")

      {:error, {:rate_limited, seconds}} ->
        ErrorHelpers.render_rate_limited(conn, seconds)

      {:error, :unavailable} ->
        ErrorHelpers.render_error(
          conn,
          :service_unavailable,
          "unavailable",
          "Edit limits are unavailable. Try again."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        ErrorHelpers.render_changeset_error(
          conn,
          :unprocessable_entity,
          "invalid_message",
          changeset
        )

      {:error, _} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_message",
          "Invalid message edit."
        )
    end
  end

  def update(conn, _params), do: ErrorHelpers.render_invalid_body(conn)

  def typing(conn, %{"channel_id" => channel_id}) do
    case Bots.command_typing(conn.assigns.current_bot_scope, %{"channel_id" => channel_id}) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :forbidden} ->
        ErrorHelpers.render_error(
          conn,
          :forbidden,
          "forbidden",
          "Bot cannot send to that channel."
        )

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Channel not found.")

      {:error, _} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_params",
          "Invalid typing request."
        )
    end
  end

  def show(conn, %{"message_id" => message_id}) do
    case Bots.get_message(conn.assigns.current_bot_scope, message_id) do
      {:ok, %{message: message}} ->
        render(conn, :show, message: message)

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Message not found.")
    end
  end

  def thread(conn, %{"message_id" => message_id}) do
    case Bots.get_thread_for_starter_message(conn.assigns.current_bot_scope, message_id) do
      {:ok, %{thread: thread}} ->
        json(conn, %{data: thread})

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Thread not found.")

      {:error, _} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_params",
          "Invalid thread query."
        )
    end
  end

  def create_thread(conn, %{"message_id" => message_id} = params) do
    thread_params = Map.get(params, "thread", %{})

    case Bots.create_public_thread(conn.assigns.current_bot_scope, message_id, thread_params) do
      {:ok, %{thread: thread}} ->
        conn
        |> put_status(:created)
        |> json(%{data: thread})

      {:error, :forbidden} ->
        ErrorHelpers.render_error(
          conn,
          :forbidden,
          "forbidden",
          "Bot cannot create a thread from that message."
        )

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Starter message not found.")

      {:error, %Ecto.Changeset{} = changeset} ->
        ErrorHelpers.render_changeset_error(
          conn,
          :unprocessable_entity,
          "invalid_thread",
          changeset
        )

      {:error, _} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_thread",
          "Invalid thread request."
        )
    end
  end
end
