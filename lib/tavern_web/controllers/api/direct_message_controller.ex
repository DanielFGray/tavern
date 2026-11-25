defmodule TavernWeb.API.DirectMessageController do
  @moduledoc """
  A bot's direct messages (docs/design/direct-messages.md, Bot API). Messages in a DM use the
  channel message endpoints with the DM's id.
  """
  use TavernWeb, :controller

  alias Tavern.Bots
  alias TavernWeb.API.ErrorHelpers

  def index(conn, _params) do
    json(conn, %{data: Bots.list_direct_messages(conn.assigns.current_bot_scope)})
  end

  # One answer for every refusal, so a bot cannot tell a block from an opt-out or an unknown id.
  def create(conn, %{"user_id" => user_id}) when is_binary(user_id) do
    case Bots.open_direct_message(conn.assigns.current_bot_scope, user_id) do
      {:ok, dm} ->
        json(conn, %{data: dm})

      {:error, :not_available} ->
        ErrorHelpers.render_error(
          conn,
          :not_found,
          "not_available",
          "You can't message this member."
        )
    end
  end

  def create(conn, _params) do
    ErrorHelpers.render_error(
      conn,
      :unprocessable_entity,
      "invalid_params",
      "user_id is required."
    )
  end
end
