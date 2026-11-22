import Config

# config/runtime.exs sets the database URL from TEST_DATABASE_URL.
#
# The e2e server (playwright.config.js, MIX_TEST_PARTITION=e2e) is a real server driven by a
# browser, so it uses the ordinary connection pool. The ownership sandbox would give each
# long-lived HTTP connection process a database connection for its whole life, and the pool
# kills an owner after the 120 s ownership timeout.
e2e_server? = System.get_env("MIX_TEST_PARTITION") == "e2e"

if not e2e_server?, do: config(:tavern, Tavern.Repo, pool: Ecto.Adapters.SQL.Sandbox)

config :tavern, Tavern.Repo,
  # Test modules run one at a time, so a small pool is enough; the dev login allows 32.
  pool_size: 8,
  # In shared sandbox mode every process uses one connection, and Ecto runs preloads in parallel
  # tasks that queue for it. Over the ~100 ms link to the test database each holder keeps the
  # connection at least one round trip, so the default queue limit (about 100 ms) drops requests
  # that only had to wait their turn.
  queue_target: 2_000,
  queue_interval: 10_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tavern, TavernWeb.Endpoint,
  url: [host: "127.0.0.1", port: 4001],
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  secret_key_base: "HHDOlzXeOcVQj1LibdiPwgSjX59e5Xvpm+Znp1E7VvaoenUUw0IxQFik/sVcwL/J",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Requests go to an in-memory bucket through Req's plug transport; signing still runs.
config :tavern, Tavern.ObjectStore,
  endpoint: "http://object-store.test",
  bucket: "tavern-test",
  region: "us-east-1",
  access_key_id: "test",
  secret_access_key: "test",
  req_options: [plug: Tavern.TestObjectStore, retry: false]

# Link previews reach no network: requests go to `Req.Test` stubs, and host names resolve
# from a fixed table.
config :tavern, Tavern.Embeds.SafeHTTP,
  resolver: Tavern.TestDNS,
  req_options: [plug: {Req.Test, Tavern.Embeds.SafeHTTP}]

# Mail goes to the capture provider: a test process that subscribes (the case templates do)
# receives `{:mail_captured, email}` for the mail it and the processes it drives send.
config :tavern, Tavern.Mailer, provider: :capture, from: "tavern@example.test"

# Tests close polls by calling `Tavern.Chat.Questions.close_due/1` with a chosen time; a background
# closer would query outside the test's sandbox.
config :tavern, :question_closer, false

# Tests delete due accounts by calling `Tavern.Accounts.delete_due_accounts/1` with a chosen
# time, for the same reason.
config :tavern, :deletion_sweeper, false

# Fixtures and the e2e seed commands send dozens of messages from one author within a second,
# as a script would. Tests of the send limit set their own windows.
config :tavern, Tavern.Chat.SendLimit, windows: [{10_000, 10}]
