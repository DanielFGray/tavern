defmodule Tavern.Voice.CloudflareTest do
  use ExUnit.Case, async: false

  alias Tavern.Voice.Cloudflare

  @app_id "test-realtime-app"
  @new_session_path "/v1/apps/#{@app_id}/sessions/new"
  @new_tracks_path "/v1/apps/#{@app_id}/sessions/session-1/tracks/new"
  @renegotiate_path "/v1/apps/#{@app_id}/sessions/session-1/renegotiate"
  @close_tracks_path "/v1/apps/#{@app_id}/sessions/session-1/tracks/close"

  setup do
    Req.Test.stub(Cloudflare, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", @new_session_path} ->
          Req.Test.json(conn, %{"sessionId" => "session-1"})

        {"POST", @new_tracks_path} ->
          Req.Test.json(conn, %{
            "sessionDescription" => %{"type" => "answer", "sdp" => "answer-sdp"},
            "tracks" => [%{"mid" => "0", "trackName" => "mic"}]
          })

        {"PUT", @renegotiate_path} ->
          Req.Test.json(conn, %{"ok" => true})

        {"PUT", @close_tracks_path} ->
          Req.Test.json(conn, %{"tracks" => [%{"mid" => "0"}]})

        _ ->
          Req.Test.json(conn, %{"errorCode" => "not_found"})
      end
    end)

    :ok
  end

  test "configured?/0 is true in the test environment" do
    assert Cloudflare.configured?()
  end

  test "new_session/0 answers the session id" do
    assert {:ok, "session-1"} = Cloudflare.new_session()
  end

  test "new_tracks/2 posts the browser's offer and answers the body" do
    body = %{
      "sessionDescription" => %{"type" => "offer", "sdp" => "offer-sdp"},
      "tracks" => [%{"location" => "local", "mid" => "0", "trackName" => "mic"}]
    }

    assert {:ok,
            %{
              "sessionDescription" => %{"sdp" => "answer-sdp"},
              "tracks" => [%{"mid" => "0"}]
            }} = Cloudflare.new_tracks("session-1", body)
  end

  test "renegotiate/2 sends the browser's answer as an answer description" do
    assert {:ok, %{"ok" => true}} = Cloudflare.renegotiate("session-1", "browser-answer")
  end

  test "close_tracks/2 sends force-closed mids" do
    assert {:ok, %{"tracks" => [%{"mid" => "0"}]}} =
             Cloudflare.close_tracks("session-1", [%{"mid" => "0"}])
  end

  test "a non-2xx answer is an error carrying the status" do
    Req.Test.stub(Cloudflare, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"errorCode" => "bad"}))
    end)

    assert {:error, {:status, 400, %{"errorCode" => "bad"}}} = Cloudflare.new_session()
  end

  test "turn_ice_servers/1 falls back to STUN when no TURN key is configured" do
    assert [%{"urls" => urls}] = Cloudflare.turn_ice_servers()
    assert urls == "stun:stun.cloudflare.com:3478"
  end
end
