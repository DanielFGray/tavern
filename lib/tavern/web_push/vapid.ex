defmodule Tavern.WebPush.Vapid do
  @moduledoc """
  The `Authorization` header that proves a push comes from this server (RFC 8292): a JWT signed
  with the server's P-256 key, and that key's public half.
  """

  # Push services refuse a token that lives longer than 24 hours.
  @token_lifetime_seconds 12 * 3600

  @doc """
  The header value for a push to `endpoint`, signed with `keys` (`%{public_key, private_key}`,
  raw bytes). `subject` is the server's own URL, the contact RFC 8292 asks for.
  """
  def authorization(endpoint, %{public_key: public_key, private_key: private_key}, subject, now) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)
    audience = URI.to_string(%URI{scheme: scheme, host: host, port: port})

    header = encode(Jason.encode!(%{typ: "JWT", alg: "ES256"}))

    claims =
      encode(Jason.encode!(%{aud: audience, exp: now + @token_lifetime_seconds, sub: subject}))

    signing_input = header <> "." <> claims
    signature = sign(signing_input, private_key)

    "vapid t=#{signing_input}.#{encode(signature)}, k=#{encode(public_key)}"
  end

  # ES256 wants the raw 64-byte r || s; `:crypto.sign/5` returns it DER-encoded.
  defp sign(input, private_key) do
    der = :crypto.sign(:ecdsa, :sha256, input, [private_key, :prime256v1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::unsigned-big-256, s::unsigned-big-256>>
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
