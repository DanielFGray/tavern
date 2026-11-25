import Config

# A variable set to an empty string counts as unset. Docker Compose and env files pass a blank
# `NAME=` through as "", and every check below (a provider chosen, voice configured, a port
# given) means "has a value".
env = fn name ->
  case System.get_env(name) do
    nil -> nil
    value -> if String.trim(value) == "", do: nil, else: value
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tavern start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if env.("PHX_SERVER") do
  config :tavern, TavernWeb.Endpoint, server: true
end

config :tavern,
  server_name: env.("TAVERN_SERVER_NAME") || "Tavern",
  # Read once, when a new server is created: `private` or `owner_can_read`
  # (docs/design/direct-messages.md). Changing it later does nothing.
  direct_message_privacy: env.("TAVERN_DM_PRIVACY") || "private",
  valkey_url: env.("VALKEY_URL") || "redis://localhost:6379/0",
  # The platform gives each deploy its own prefix, colon included: `tavern:` live,
  # `tavern-staged:` in a staged copy. The Valkey login may touch only keys under it.
  valkey_key_prefix: env.("VALKEY_KEY_PREFIX") || "tavern:",
  trusted_proxy_header: env.("TRUSTED_PROXY_HEADER"),
  # The platform sets the short commit of each deploy; a checkout has none.
  git_commit: env.("GIT_COMMIT")

config :tavern, TavernWeb.Endpoint, http: [port: String.to_integer(env.("PORT") || "4000")]

# A checkout gets both URLs from `ops dev db up`, which writes them to .env. A deploy
# gets DATABASE_URL from the cartridge's PostgresCredentials secret.
database_url_env = if config_env() == :test, do: "TEST_DATABASE_URL", else: "DATABASE_URL"

config :tavern, Tavern.Repo,
  url:
    env.(database_url_env) ||
      raise("""
      environment variable #{database_url_env} is missing.
      In a checkout, run `ops dev db up`, then `set -a; source .env; set +a`.
      """)

if config_env() == :prod do
  maybe_ipv6 = if env.("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :tavern, Tavern.Repo,
    # ssl: true,
    pool_size: String.to_integer(env.("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    env.("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # A deploy gets the service's public URL, such as its tailnet route, from the cartridge.
  public_url =
    URI.parse(
      env.("PHX_URL") ||
        raise("environment variable PHX_URL is missing, for example https://chat.example.com")
    )

  # The cartridge's ObjectStoreCredentials secret sets these, in the server and in the
  # migrate step, because both load this file. A staged copy gets its own key on the live bucket.
  fetch_s3_env! = fn name ->
    env.(name) || raise("environment variable #{name} is missing")
  end

  config :tavern, Tavern.ObjectStore,
    endpoint: fetch_s3_env!.("S3_ENDPOINT"),
    bucket: fetch_s3_env!.("S3_BUCKET"),
    region: fetch_s3_env!.("S3_REGION"),
    access_key_id: fetch_s3_env!.("S3_ACCESS_KEY_ID"),
    secret_access_key: fetch_s3_env!.("S3_SECRET_ACCESS_KEY")

  # The api login holds no grants and does not inherit the visitor role, so each server
  # connection switches to it. The migrate step logs in as the migration login, which cannot
  # take that role; `Tavern.Release.migrate/0` starts the Repo without this callback.
  visitor_role = env.("DATABASE_VISITOR")

  if visitor_role do
    quoted_role = ~s("#{String.replace(visitor_role, ~s("), ~s(""))}")

    config :tavern, Tavern.Repo,
      after_connect: {Postgrex, :query!, ["SET ROLE #{quoted_role}", []]}
  end

  config :tavern, :dns_cluster_query, env.("DNS_CLUSTER_QUERY")

  # The platform sets the OpenObserve OTLP endpoint in every job; the exporters append
  # `/v1/traces` and `/v1/logs` to it. Without it a deploy exports nothing. Spans leave through
  # `Tavern.Observability.Redaction`, which wraps the OTLP exporter.
  if env.("OTEL_EXPORTER_OTLP_ENDPOINT") do
    config :opentelemetry, traces_exporter: {Tavern.Observability.Redaction, %{}}
  end

  # Mail: invites, verification and password resets. MAIL_PROVIDER is `cloudflare` or `smtp`.
  # With it unset no provider is configured, so Settings cannot turn on invite requests; there
  # is no fallback provider. SMTP_SECURITY is `starttls` (default), `tls` or `none`
  # (Tavern.Mailer.Smtp); SMTP_PORT defaults to the mode's usual port.
  mail_provider =
    case env.("MAIL_PROVIDER") do
      "cloudflare" -> :cloudflare
      "smtp" -> :smtp
      _unset -> nil
    end

  smtp_security =
    case env.("SMTP_SECURITY") || "starttls" do
      "starttls" -> :starttls
      "tls" -> :tls
      "none" -> :none
      other -> raise "SMTP_SECURITY must be starttls, tls or none, not #{inspect(other)}"
    end

  config :tavern, Tavern.Mailer,
    provider: mail_provider,
    from: env.("EMAIL_FROM"),
    account_id: env.("CLOUDFLARE_ACCOUNT_ID"),
    api_token: env.("CLOUDFLARE_EMAIL_API_TOKEN"),
    smtp_host: env.("SMTP_HOST"),
    smtp_port: env.("SMTP_PORT") && String.to_integer(env.("SMTP_PORT")),
    smtp_username: env.("SMTP_USERNAME"),
    smtp_password: env.("SMTP_PASSWORD"),
    smtp_security: smtp_security

  # Phoenix's default `check_origin: true` accepts a socket only from a page on this url's host.
  config :tavern, TavernWeb.Endpoint,
    url: [host: public_url.host, port: public_url.port, scheme: public_url.scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end

# Voice media (docs/design/voice.md). One Realtime app and secret pair serves local, staged
# and production. With CLOUDFLARE_REALTIME_APP_SECRET unset voice stays off. The TURN key is
# a server-side secret of its own — never the Realtime app secret; browsers receive only the
# short-lived credentials the backend mints from it. The test environment pins its own values
# (test.exs), so this block leaves test alone.
if config_env() != :test do
  config :tavern, Tavern.Voice.Cloudflare,
    app_id: env.("CLOUDFLARE_REALTIME_APP_ID"),
    app_secret: env.("CLOUDFLARE_REALTIME_APP_SECRET"),
    turn_key_id: env.("CLOUDFLARE_TURN_KEY_ID"),
    turn_key_token: env.("CLOUDFLARE_TURN_KEY_TOKEN")
end
