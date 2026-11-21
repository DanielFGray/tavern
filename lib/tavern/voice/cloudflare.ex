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

  @doc "Whether the deploy holds a Realtime app id and secret. Without both, voice is off."
  def configured? do
    not is_nil(app_id()) and not is_nil(app_secret())
  end

  def turn_servers do
    config = config()

    case {config[:turn_urls], config[:turn_username], config[:turn_credential]} do
      {urls, username, credential} when urls != nil and username != nil and credential != nil ->
        [%{urls: urls, username: username, credential: credential}]

      _ ->
        # STUN alone: Cloudflare's public server helps most networks; TURN covers the rest.
        [%{urls: "stun:stun.cloudflare.com:3478"}]
    end
  end

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

  defp config do
    Application.get_env(:tavern, __MODULE__, [])
  end
end
