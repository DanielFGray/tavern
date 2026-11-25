defmodule TavernWeb.ManifestController do
  @moduledoc """
  The web app manifest (`GET /manifest.webmanifest`), which lets a browser install Tavern as an
  app. iOS and iPadOS give Web Push only to a web app added to the Home Screen
  (docs/design/push-notifications.md). The name is this server's own.
  """
  use TavernWeb, :controller

  alias Tavern.Chat

  @theme_color "#5b4be8"

  def theme_color, do: @theme_color

  def show(conn, _params) do
    settings = Chat.get_server_settings()
    name = (settings && settings.name) || Chat.default_server_name()

    conn
    |> put_resp_content_type("application/manifest+json")
    |> send_resp(
      200,
      Jason.encode!(%{
        name: name,
        short_name: String.slice(name, 0, 12),
        id: "/",
        start_url: "/",
        scope: "/",
        display: "standalone",
        background_color: @theme_color,
        theme_color: @theme_color,
        icons: [
          %{src: ~p"/images/app-icon-192.png", sizes: "192x192", type: "image/png"},
          %{src: ~p"/images/app-icon-512.png", sizes: "512x512", type: "image/png"},
          %{
            src: ~p"/images/app-icon-512.png",
            sizes: "512x512",
            type: "image/png",
            purpose: "maskable"
          }
        ]
      })
    )
  end
end
