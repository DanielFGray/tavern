defmodule TavernWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets the browser's Content-Security-Policy for HTML pages, with a fresh script nonce per
  request in `conn.assigns.csp_nonce`.

  Scripts run only from this origin (the `app.js` bundle) or from a `<script>` tag that carries
  the nonce: the root layout's theme script, which must run inline before the first paint, and
  LiveDashboard's scripts in development. Frames come from this origin (the dev live-reload
  frame) and from YouTube's no-cookie player, which a video embed loads after a click.

  Images come only from this origin and `data:` URLs (the icon masks in the stylesheet). Every
  image a member supplies is stored and served from `/uploads`: avatars, custom emoji, server
  icons and link embed images, YouTube thumbnails included. So an image from another host, such
  as one an injected or hand-written `<img>` points at, is blocked, and reading a message tells
  no other site the reader's address.

  Run it after `put_secure_browser_headers/2`, whose default policy this one replaces.
  """

  import Plug.Conn

  @nonce_bytes 18

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = @nonce_bytes |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    "base-uri 'self'; frame-ancestors 'self'; " <>
      "frame-src 'self' https://www.youtube-nocookie.com; " <>
      "img-src 'self' data:; " <>
      "script-src 'self' 'nonce-#{nonce}';"
  end
end
