# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tavern,
  env: config_env(),
  ecto_repos: [Tavern.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Abuse limits for invite requests and the invite mail they lead to; every number lives here.
# Intake limits count requests per client IP and new pending requests server-wide: over one,
# the form still answers "Request received" and stores nothing. Send limits count invite mail
# per address and server-wide: over one, the approval stands and the queue offers Resend later.
config :tavern, Tavern.Chat.InviteRequests,
  invite_expiry_days: 7,
  limits: [
    requests_per_ip_hour: 3,
    requests_per_ip_day: 10,
    pending_requests_per_day: 50,
    mails_per_address_day: 1,
    mails_per_day: 100
  ]

# A bot streaming a reply edits one message many times. Edits to one message beyond this many in
# a second answer 429 with Retry-After.
config :tavern, Tavern.Bots, message_edits_per_second: 2

# Messages one member (a person or a bot) may send across every channel and thread, as
# {messages, seconds} windows. A fast typist stays under both; a script meets the first within
# seconds and the second within minutes. docs/design/rate-limits.md
config :tavern, Tavern.Chat.SendLimit, windows: [{10, 10}, {120, 300}]

# Configure the endpoint
config :tavern, TavernWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TavernWeb.ErrorHTML, json: TavernWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tavern.PubSub,
  live_view: [signing_salt: "f78x3xGk"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tavern: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  tavern: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# OpenTelemetry (`Tavern.Observability`). Nothing is exported unless config/runtime.exs turns
# the exporter on in a deploy. Every trace is sampled.
config :opentelemetry,
  traces_exporter: :none,
  resource: %{service: %{name: "tavern"}}

# Voice over Cloudflare Realtime SFU (docs/design/voice.md). runtime.exs fills the app id and
# secret, and the TURN credentials when a TURN app exists. Without the secret pair voice is
# off: the UI shows "voice not configured" and nothing calls the SFU.
config :tavern, Tavern.Voice.Cloudflare,
  app_id: nil,
  app_secret: nil,
  turn_urls: ["stun:stun.cloudflare.com:3478"],
  turn_username: nil,
  turn_credential: nil

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
