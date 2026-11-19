defmodule TavernWeb.API.BotApiEventsAcceptTest do
  @moduledoc """
  `GET /api/v1/events` is a server-sent event stream, so a standard SSE client asks for it with
  `Accept: text/event-stream`. The route must reach bot auth for that request, not refuse it as
  an unacceptable format. A request with a valid token would open the stream and block, so these
  tests stop at auth.
  """
  use TavernWeb.ConnCase

  test "an SSE Accept header reaches bot auth", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/api/v1/events")

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "the JSON endpoints still refuse an SSE Accept header", %{conn: conn} do
    assert_raise Phoenix.NotAcceptableError, fn ->
      conn
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/api/v1/members/#{Ecto.UUID.generate()}")
    end
  end
end
