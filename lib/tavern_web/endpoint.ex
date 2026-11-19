defmodule TavernWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :tavern

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_tavern_key",
    signing_salt: "w+9iBrcb",
    same_site: "Lax",
    secure: Application.compile_env(:tavern, :secure_cookies, false)
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]],
    longpoll: [connect_info: [:peer_data, :x_headers, session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # Only `phx.digest`, run for a production release, writes the `.gz` copies. Elsewhere a `.gz` left
  # by an old digest run would shadow the freshly built bundle, so gzip serving is prod-only.
  plug Plug.Static,
    at: "/",
    from: :tavern,
    gzip: Application.compile_env(:tavern, :serve_gzip_assets, false),
    only: TavernWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :tavern
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug TavernWeb.Plugs.ClientIp
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug TavernWeb.Router
end
