defmodule Tavern.Mailer.Smtp do
  @moduledoc """
  Sends through an SMTP server with gen_smtp, so a self-hosted Tavern can use a mail account its
  operator already has.

  It reads `:smtp_host`, `:smtp_port`, `:smtp_username`, `:smtp_password` and `:smtp_security`
  from the `Tavern.Mailer` config. `:smtp_security` is one of:

  - `:starttls` (the default; port 587): the session must upgrade to TLS before it logs in or
    sends, or the send fails. A server that does not offer STARTTLS gets no mail.
  - `:tls` (port 465): TLS from the first byte.
  - `:none` (port 25): no TLS, for a relay on the same host or a private network.

  Under TLS the server's certificate must chain to the operating system's trust store and name
  the host. Each mail opens one connection and is not retried, as with Cloudflare: a failed send
  is shown to the moderator, who can resend.
  """

  @default_ports %{starttls: 587, tls: 465, none: 25}

  def deliver(email, config) do
    message = encode(email)

    case :gen_smtp_client.send_blocking({email.from, [email.to], message}, options(config)) do
      receipt when is_binary(receipt) -> :ok
      {:error, _stage, failure} -> {:error, "SMTP " <> describe(failure)}
      {:error, reason} -> {:error, "SMTP settings refused: #{inspect(reason)}"}
    end
  end

  @doc "The port a security mode uses when `SMTP_PORT` is unset."
  def default_port(security), do: Map.fetch!(@default_ports, security)

  defp options(config) do
    host = config[:smtp_host]
    security = config[:smtp_security] || :starttls
    tls = tls_options(host)

    [
      relay: host,
      port: config[:smtp_port] || default_port(security),
      no_mx_lookups: true,
      retries: 0,
      ssl: security == :tls,
      tls: if(security == :starttls, do: :always, else: :never),
      tls_options: tls,
      # An implicit-TLS connection takes its TLS options from the socket options.
      sockopts: if(security == :tls, do: tls, else: [])
    ] ++ login(config)
  end

  defp login(config) do
    case {config[:smtp_username], config[:smtp_password]} do
      {user, password} when user not in [nil, ""] and password not in [nil, ""] ->
        [
          auth: :always,
          username: String.to_charlist(user),
          password: String.to_charlist(password)
        ]

      _anonymous ->
        [auth: :never]
    end
  end

  defp tls_options(host) do
    host = String.to_charlist(host)

    [
      verify: :verify_peer,
      # gen_smtp's own default is depth 0, which refuses any chain with an intermediate
      # certificate: nearly every public server's. 10 is OTP's default.
      depth: 10,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: host,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]
  end

  # mimemail adds Date, Message-ID and MIME-Version, and encodes a non-ASCII subject.
  defp encode(email) do
    :mimemail.encode(
      {"multipart", "alternative",
       [{"From", email.from}, {"To", email.to}, {"Subject", email.subject}], %{},
       [part("plain", email.text), part("html", email.html)]}
    )
  end

  defp part(subtype, body),
    do: {"text", subtype, [], %{content_type_params: [{"charset", "utf-8"}]}, body}

  # The reason is logged, so it keeps only the server's reply code: the reply text may name the
  # recipient, and the caller knows whom it mailed.
  defp describe({:permanent_failure, _host, :auth_failed}), do: "login failed"

  defp describe({:permanent_failure, _host, reply}) when is_binary(reply),
    do: "refused: #{code(reply)}"

  defp describe({:temporary_failure, _host, :tls_failed}), do: "TLS handshake failed"

  defp describe({:temporary_failure, _host, reply}) when is_binary(reply),
    do: "deferred: #{code(reply)}"

  defp describe({:missing_requirement, _host, :tls}), do: "server does not offer STARTTLS"
  defp describe({:missing_requirement, _host, :auth}), do: "server does not offer login"

  defp describe({:network_failure, _host, {:error, {:tls_alert, {alert, _detail}}}}),
    do: "TLS failed: #{alert}"

  defp describe({:network_failure, _host, {:error, reason}}),
    do: "unreachable: #{inspect(reason)}"

  defp describe(failure), do: "failed: #{inspect(failure)}"

  defp code(reply) do
    case Regex.run(~r/^\d{3}(?:[ -]\d\.\d{1,3}\.\d{1,3})?/, reply) do
      [code] -> code
      nil -> "unrecognised reply"
    end
  end
end
