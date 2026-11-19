defmodule TavernWeb.API.MemberController do
  @moduledoc """
  A member's display name and role ids for bots, so a bot can check whether a person who
  mentioned it holds a role it listens to. A user who is not a visible member is not found.
  """
  use TavernWeb, :controller

  alias Tavern.Bots
  alias TavernWeb.API.ErrorHelpers

  def show(conn, %{"user_id" => user_id}) do
    case Bots.get_member(conn.assigns.current_bot_scope, user_id) do
      nil -> ErrorHelpers.render_error(conn, :not_found, "not_found", "Member not found.")
      member -> json(conn, %{data: member})
    end
  end
end
