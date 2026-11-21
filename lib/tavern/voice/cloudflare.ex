defmodule Tavern.Voice.Cloudflare do
  @moduledoc """
  Calls the Cloudflare Realtime SFU Connection API for one voice room
  (docs/design/voice.md). Every call the browser needs is made here: the app secret never
  leaves the backend. The browser speaks plain WebRTC to Cloudflare; Tavern only relays the
  SDP this module exchanges.

  Paths are relative to `https://rtc.live.cloudflare.com/v1/apps/{app_id}`. Each answer carries
  per-request and per-track results; callers check both (`Cloudflare` returns the decoded body
  as it stands). Tests pin requests to `Req.Test` through `req_options` in the config, as
  `Tavern.Embeds.SafeHTTP` does.
  """

  @base_url "https://rtc.live.cloudflare.com/v1/apps"
  @turn_base_url "https://rtc.live.cloudflare.com/v1/turn"

  @doc "Whether the deploy holds a Realtime app id and secret. Without both, voice is off."
  def configured? do
    not is_nil(app_id()) and not is_nil(app_secret())
  end

  @doc """
  The ICE servers one browser session connects with: a freshly minted short-lived TURN
  credential when the deploy holds a TURN key (the key never leaves the backend), else
  Cloudflare's public STUN server. `ttl` is the credential's lifetime in seconds; it should
  cover the longest call a member is expected to make before a rejoin mints again.
  """
  def turn_ice_servers(ttl \\ 86_400) do
    case {turn_key_id(), turn_key_token()} do
      {key_id, token} when key_id != nil and token != nil ->
        case request_turn_credentials(key_id, token, ttl) do
          {:ok, ice_servers} -> ice_servers
          _ -> stun_only()
        end

      _ ->
        stun_only()
    end
  end

  defp request_turn_credentials(key_id, token, ttl) do
    [
      method: :post,
      url: @turn_base_url <> "/keys/#{key_id}/credentials/generate-ice-servers",
      json: %{"ttl" => ttl}
    ]
    |> Keyword.merge(Keyword.get(config(), :req_options, []))
    |> Req.new(
      headers: [{"authorization", "Bearer " <> token}],
      retry: false,
      receive_timeout: 10_000
    )
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: %{"iceServers" => servers}}}
      when status in 200..299 ->
        {:ok, servers}

      _ ->
        {:error, :turn_credentials}
    end
  end

  defp stun_only, do: [%{"urls" => "stun:stun.cloudflare.com:3478"}]

  @doc """
  Opens a session: `POST /sessions/new` with no body. Answers `{:ok, session_id}` or an error.
  """
  def new_session do
    case request(:post, "/sessions/new", %{}) do
      {:ok, %{"sessionId" => session_id}} -> {:ok, session_id}
      other -> other
    end
  end

  @doc """
  Publishes the browser's local tracks or subscribes to remote ones:
  `POST /sessions/{session_id}/tracks/new`. The body holds the browser's `sessionDescription`
  for a publish, or remote `tracks` entries for a subscribe; see the connection patterns.
  """
  def new_tracks(session_id, body), do: request(:post, "/sessions/#{session_id}/tracks/new", body)

  @doc """
  Answers an SFU offer with the browser's answer: `PUT /sessions/{session_id}/renegotiate`.
  """
  def renegotiate(session_id, answer_sdp) do
    request(:put, "/sessions/#{session_id}/renegotiate", %{
      "sessionDescription" => %{"type" => "answer", "sdp" => answer_sdp}
    })
  end

  @doc """
  Stops tracks without negotiation: `PUT /sessions/{session_id}/tracks/close` with
  `force: true`. `entries` are `%{"mid" => mid}` maps.
  """
  def close_tracks(session_id, entries) do
    request(:put, "/sessions/#{session_id}/tracks/close", %{
      "tracks" => entries,
      "force" => true
    })
  end

  def request(method, path, body) do
    if configured?() do
      [method: method, url: path, json: body]
      |> Keyword.merge(Keyword.get(config(), :req_options, []))
      |> Req.new(
        base_url: base_url(),
        headers: authorization_header(),
        retry: false,
        connect_options: [timeout: 10_000],
        receive_timeout: 10_000
      )
      |> Req.request()
      |> case do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          {:ok, response.body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:status, status, body}}

        {:error, exception} ->
          {:error, {:transport, exception}}
      end
    else
      {:error, :unconfigured}
    end
  end

  defp base_url, do: @base_url <> "/" <> app_id()
  defp authorization_header, do: [{"authorization", "Bearer " <> app_secret()}]

  defp app_id, do: config()[:app_id]
  defp app_secret, do: config()[:app_secret]
  defp turn_key_id, do: config()[:turn_key_id]
  defp turn_key_token, do: config()[:turn_key_token]

  defp config do
    Application.get_env(:tavern, __MODULE__, [])
  end
end
