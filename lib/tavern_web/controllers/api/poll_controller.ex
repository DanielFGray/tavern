defmodule TavernWeb.API.PollController do
  @moduledoc """
  Polls for bots (docs/design/polls.md). A bot sends a poll, reads its results and ends it; votes
  and closes reach it on the event stream as `poll.voted` and `poll.closed`.
  """
  use TavernWeb, :controller

  alias Tavern.Bots
  alias TavernWeb.API.ErrorHelpers

  def create(conn, %{"channel_id" => channel_id, "poll" => poll_params})
      when is_map(poll_params) do
    case Bots.create_poll(conn.assigns.current_bot_scope, channel_id, poll_params) do
      {:ok, %{message: message}} ->
        conn
        |> put_status(:created)
        |> json(%{data: message})

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
          "invalid_poll",
          changeset
        )

      {:error, {:slowmode, seconds_left}} ->
        ErrorHelpers.render_slowmode(conn, seconds_left)

      {:error, {:rate_limited, seconds_left}} ->
        ErrorHelpers.render_rate_limited(conn, seconds_left)

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  def create(conn, _params), do: ErrorHelpers.render_invalid_body(conn)

  def show(conn, %{"message_id" => message_id}) do
    case Bots.get_poll(conn.assigns.current_bot_scope, message_id) do
      {:ok, %{message: message}} -> json(conn, %{data: message})
      {:error, :not_found} -> poll_not_found(conn)
    end
  end

  def close(conn, %{"message_id" => message_id}) do
    case Bots.close_poll(conn.assigns.current_bot_scope, message_id) do
      {:ok, %{message: message}} ->
        json(conn, %{data: message})

      {:error, :poll_closed} ->
        ErrorHelpers.render_error(conn, :conflict, "poll_closed", "The poll is already closed.")

      {:error, :forbidden} ->
        ErrorHelpers.render_error(conn, :forbidden, "forbidden", "Bot cannot end that poll.")

      {:error, :not_found} ->
        poll_not_found(conn)

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  defp poll_not_found(conn),
    do: ErrorHelpers.render_error(conn, :not_found, "not_found", "Poll not found.")

  defp unauthorized(conn),
    do:
      ErrorHelpers.render_error(
        conn,
        :unauthorized,
        "unauthorized",
        "Valid bot bearer token required."
      )
end
