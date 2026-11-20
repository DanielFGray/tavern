defmodule Tavern.Chat.InviteRequestLimits do
  @moduledoc """
  The abuse limits on invite requests and on the invite mail they lead to, counted by
  `Tavern.RateLimit`. The numbers live in `config :tavern, Tavern.Chat.InviteRequests,
  limits: [...]`.

  Every check fails closed: when Valkey cannot be reached, a request is not stored and an
  email is not sent. A stranger's form post must never become mail by riding an outage.
  """

  alias Tavern.RateLimit

  @hour 3_600
  @day 86_400
  @namespace "invite_request:"

  @doc """
  Counts one request from `ip_address` against the per-IP hourly and daily limits. Returns
  `:ok`, `:over_limit` or `:unavailable`.
  """
  def admit_ip(ip_address) do
    hit([
      {@namespace <> "ip_hour:" <> ip_address, limit(:requests_per_ip_hour), @hour},
      {@namespace <> "ip_day:" <> ip_address, limit(:requests_per_ip_day), @day}
    ])
  end

  @doc "Counts one new pending request against the server-wide daily cap."
  def admit_pending do
    hit([{@namespace <> "pending_day", limit(:pending_requests_per_day), @day}])
  end

  @doc """
  Reserves one invite email to `email` against the per-address and server-wide daily caps.
  Returns `:ok`, or `{:error, reason}` with the reason the queue shows. A reservation that
  ends in a failed send is handed back with `release_mail/1`.
  """
  def reserve_mail(email) do
    case hit(mail_buckets(email)) do
      :ok -> :ok
      :over_limit -> {:error, "not sent: daily limit"}
      :unavailable -> {:error, "not sent: the limit counter is unavailable"}
    end
  end

  @doc "Hands back a reservation from `reserve_mail/1` whose email was not sent."
  def release_mail(email), do: RateLimit.release(mail_buckets(email))

  @doc "Clears every counter. Tests only."
  def reset!, do: RateLimit.reset!(@namespace)

  defp mail_buckets(email) do
    address = email |> String.trim() |> String.downcase()

    [
      {@namespace <> "mail_address:" <> Integer.to_string(:erlang.phash2(address)),
       limit(:mails_per_address_day), @day},
      {@namespace <> "mail_day", limit(:mails_per_day), @day}
    ]
  end

  defp hit(buckets) do
    case RateLimit.hit(buckets, :refuse) do
      :ok -> :ok
      {:error, {:rate_limited, _seconds}} -> :over_limit
      {:error, :unavailable} -> :unavailable
    end
  end

  defp limit(name) do
    :tavern
    |> Application.fetch_env!(Tavern.Chat.InviteRequests)
    |> Keyword.fetch!(:limits)
    |> Keyword.fetch!(name)
  end
end
