defmodule Tavern.WebPush do
  @moduledoc """
  Sends Web Push notifications to members' devices (docs/design/push-notifications.md).

  Each push is encrypted to its device (`Tavern.WebPush.Encryption`) and signed with the
  server's VAPID key (`Tavern.WebPush.Vapid`). The key pair is made on first use and stored in
  `push_keys` with the server URL it was made for. A server running at another URL, such as a
  restored copy of the database, sends no push, so a copy cannot reach real members' phones.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Tavern.Chat.PushSubscription
  alias Tavern.Chat.PushSubscriptions
  alias Tavern.Embeds.SafeHTTP
  alias Tavern.Repo
  alias Tavern.WebPush.Encryption
  alias Tavern.WebPush.Key
  alias Tavern.WebPush.Vapid

  @task_supervisor Tavern.WebPush.TaskSupervisor
  @max_concurrency 16
  @send_timeout_ms 10_000
  # How long a push service keeps a push for a device that is offline.
  @ttl_seconds 24 * 3600

  @doc "The public VAPID key a browser subscribes with, or `{:error, :other_origin}`."
  def public_key do
    with {:ok, key} <- key(), do: {:ok, key.public_key}
  end

  @doc """
  Sends each `{user_id, payload}` to every device of that member, in a background task, so the
  writer never waits on a push service. `payload` is a map the service worker reads. When too
  many sends are running, the pushes are dropped and logged.
  """
  def deliver([]), do: :ok

  def deliver(pushes) when is_list(pushes) do
    case Task.Supervisor.start_child(@task_supervisor, fn -> send_all(pushes) end) do
      {:ok, _pid} ->
        :ok

      {:error, :max_children} ->
        Logger.warning("Web Push dropped: too many sends running")
    end
  end

  @doc """
  Sends each `{user_id, payload}` now, at most #{@max_concurrency} requests at once, and deletes
  each subscription its push service says is gone (404 or 410). Other failures are logged; a
  push is not retried.
  """
  def send_all(pushes) do
    case key() do
      {:ok, key} ->
        payloads = Map.new(pushes)
        now = System.system_time(:second)

        from(subscription in PushSubscriptions.live(),
          where: subscription.user_id in ^Map.keys(payloads)
        )
        |> Repo.all()
        |> Task.async_stream(
          &{&1, send_one(&1, Map.fetch!(payloads, &1.user_id), key, now)},
          max_concurrency: @max_concurrency,
          timeout: @send_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.each(&record/1)

      {:error, :other_origin} ->
        Logger.warning("Web Push off: the push key was made for another server URL")
    end
  end

  defp send_one(%PushSubscription{} = subscription, payload, key, now) do
    body = Encryption.encrypt(Jason.encode!(payload), subscription.p256dh, subscription.auth)

    headers = [
      {"content-encoding", "aes128gcm"},
      {"content-type", "application/octet-stream"},
      {"ttl", Integer.to_string(@ttl_seconds)},
      {"urgency", "high"},
      {"authorization", Vapid.authorization(subscription.endpoint, key, origin(), now)}
    ]

    case SafeHTTP.post(subscription.endpoint, body, headers: headers, user_agent: "Tavern") do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} when status in [404, 410] -> :gone
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record({:ok, {_subscription, :ok}}), do: :ok

  defp record({:ok, {subscription, :gone}}) do
    Repo.delete_all(
      from(row in PushSubscription,
        where: row.id == ^subscription.id and row.endpoint == ^subscription.endpoint
      )
    )

    :ok
  end

  # The endpoint is a secret address, so the log names only its host.
  defp record({:ok, {subscription, {:error, reason}}}) do
    host = URI.parse(subscription.endpoint).host
    Logger.warning("Web Push to #{host} failed: #{inspect(reason)}")
  end

  defp record({:exit, :timeout}), do: Logger.warning("Web Push timed out")

  defp key do
    origin = origin()

    case Repo.get(Key, 1) || create_key(origin) do
      %Key{origin: ^origin} = key -> {:ok, key}
      %Key{} -> {:error, :other_origin}
    end
  end

  # Two servers starting at once may both get here; the row's fixed id keeps the first pair.
  defp create_key(origin) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    Repo.insert!(
      %Key{id: 1, origin: origin, public_key: public_key, private_key: private_key},
      on_conflict: :nothing,
      conflict_target: :id
    )

    Repo.get!(Key, 1)
  end

  defp origin, do: TavernWeb.Endpoint.url()
end
