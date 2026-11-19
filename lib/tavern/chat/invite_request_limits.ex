defmodule Tavern.Chat.InviteRequestLimits do
  @moduledoc """
  The abuse limits on invite requests and on the invite mail they lead to, counted in Valkey
  through `Tavern.Ephemeral`. The numbers live in `config :tavern, Tavern.Chat.InviteRequests,
  limits: [...]`.

  Every check fails closed: when Valkey cannot be reached, a request is not stored and an
  email is not sent. A stranger's form post must never become mail by riding an outage.
  """

  alias Tavern.Ephemeral

  @hour 3_600
  @day 86_400
  @prefix "rate_limit:invite_request:"

  @doc """
  Counts one request from `ip_address` against the per-IP hourly and daily limits. Returns
  `:ok` or `:over_limit`.
  """
  def admit_ip(ip_address) do
    hits([
      {"ip_hour:" <> ip_address, limit(:requests_per_ip_hour), @hour},
      {"ip_day:" <> ip_address, limit(:requests_per_ip_day), @day}
    ])
  end

  @doc "Counts one new pending request against the server-wide daily cap."
  def admit_pending do
    hits([{"pending_day", limit(:pending_requests_per_day), @day}])
  end

  @doc """
  Reserves one invite email to `email` against the per-address and server-wide daily caps.
  Returns `:ok`, or `{:error, reason}` with the reason the queue shows. A reservation that
  ends in a failed send is handed back with `release_mail/1`.
  """
  def reserve_mail(email) do
    case hits(mail_buckets(email)) do
      :ok -> :ok
      :over_limit -> {:error, "not sent: daily limit"}
      :unavailable -> {:error, "not sent: the limit counter is unavailable"}
    end
  end

  @doc "Hands back a reservation from `reserve_mail/1` whose email was not sent."
  def release_mail(email) do
    Enum.each(mail_buckets(email), fn {key, _limit, window} -> release(key, window) end)
  end

  @doc "Clears every counter. Tests only."
  def reset!, do: Ephemeral.clear_rate_limit_namespace(@prefix)

  defp mail_buckets(email) do
    address = email |> String.trim() |> String.downcase()

    [
      {"mail_address:" <> Integer.to_string(:erlang.phash2(address)),
       limit(:mails_per_address_day), @day},
      {"mail_day", limit(:mails_per_day), @day}
    ]
  end

  # Counts each bucket in order and stops at the first one over its limit. The buckets already
  # counted are handed back, so a refused hit leaves no trace in a bucket that admitted it.
  defp hits(buckets), do: hits(buckets, [])

  defp hits([], _counted), do: :ok

  defp hits([{key, limit, window} = bucket | rest], counted) do
    case Ephemeral.increment_rate_limit(@prefix <> key, window) do
      {:ok, count, _reset_at} when count <= limit ->
        hits(rest, [bucket | counted])

      {:ok, _count, _reset_at} ->
        Enum.each([bucket | counted], fn {key, _limit, window} -> release(key, window) end)
        :over_limit

      {:error, :unavailable} ->
        Enum.each(counted, fn {key, _limit, window} -> release(key, window) end)
        :unavailable
    end
  end

  defp release(key, window), do: Ephemeral.release_rate_limit(@prefix <> key, window)

  defp limit(name) do
    :tavern
    |> Application.fetch_env!(Tavern.Chat.InviteRequests)
    |> Keyword.fetch!(:limits)
    |> Keyword.fetch!(name)
  end
end
