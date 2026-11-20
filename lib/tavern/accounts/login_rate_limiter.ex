defmodule Tavern.Accounts.LoginRateLimiter do
  @moduledoc """
  The login limits, counted by `Tavern.RateLimit`. A login attempt counts against its client IP
  (20 in 5 minutes) and against its IP and email together (5 in 5 minutes). A mail that carries
  an email link counts against its account. Keys hold a hash of the IP and email, so Valkey never
  holds an address.

  The limits count locally through a Valkey outage: Valkey must not be able to stop logins.
  """

  alias Tavern.RateLimit

  @namespace "login:"
  @ip_window_seconds 300
  @ip_limit 20
  @credential_window_seconds 300
  @credential_limit 5
  @email_link_window_seconds 900
  @email_link_limit 3

  @doc "Counts one login attempt. Returns `:ok` or `{:error, retry_after_seconds}`."
  def check_attempt(ip_address, email) do
    ip_address = normalize_ip(ip_address)

    [
      {key({:ip, ip_address}), @ip_limit, @ip_window_seconds},
      {credential_key(ip_address, email), @credential_limit, @credential_window_seconds}
    ]
    |> RateLimit.hit(:count_locally)
    |> result()
  end

  @doc """
  Counts one mail that carries an email link (a confirmation or an email change) for the account
  `user_id`: at most #{@email_link_limit} in
  #{@email_link_window_seconds} seconds. Returns `:ok` or `{:error, retry_after_seconds}`.
  """
  def check_email_link(user_id) do
    [{key({:email_link, user_id}), @email_link_limit, @email_link_window_seconds}]
    |> RateLimit.hit(:count_locally)
    |> result()
  end

  @doc "Ends the IP-and-email window after a successful login. The per-IP count stays."
  def clear_attempts(ip_address, email) do
    RateLimit.clear(credential_key(normalize_ip(ip_address), email))
  end

  def reset!, do: RateLimit.reset!(@namespace)

  defp result(:ok), do: :ok
  defp result({:error, {:rate_limited, seconds}}), do: {:error, seconds}

  defp credential_key(ip_address, email),
    do: key({:credential, ip_address, normalize_email(email)})

  defp key(term), do: @namespace <> Integer.to_string(:erlang.phash2(term))

  defp normalize_ip(nil), do: "unknown"
  defp normalize_ip(ip_address) when is_binary(ip_address), do: ip_address
  defp normalize_ip(ip_address), do: ip_address |> :inet.ntoa() |> to_string()

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(_email), do: "unknown"
end
