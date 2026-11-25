defmodule Tavern.Chat.PushSubscriptions do
  @moduledoc """
  A member's Web Push subscriptions, one per device (docs/design/push-notifications.md). Each
  function that takes a scope reads or writes only the rows of `scope.user_id`.

  A subscription belongs to the browser session that made it, and only a subscription whose
  session is live (`live/0`) gets pushes. Signing out, a revoked session and an expired one all
  stop push on that browser; signing in again there and opening Tavern sends the subscription
  again under the new session.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.PushSubscription
  alias Tavern.Chat.UserSession
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  # A member's devices. A new subscription past this drops the one least recently renewed.
  @per_member 10

  @doc """
  Stores the subscription a browser made for the scope in its browser session `session_id`, from
  `PushSubscription.toJSON()`: `%{"endpoint" => url, "keys" => %{"p256dh" => key, "auth" =>
  secret}}`, keys in unpadded base64url. An endpoint already stored moves to this member and
  session with its new keys, because a browser keeps one subscription across sign-ins.
  """
  def subscribe(%Scope{} = scope, session_id, params) do
    with %{} <- Visibility.member(scope) || {:error, :forbidden},
         true <- live_session?(scope, session_id) || {:error, :forbidden},
         {:ok, attrs} <- decode(params) do
      Repo.transact(fn ->
        with {:ok, subscription} <-
               %PushSubscription{user_id: scope.user_id, session_id: session_id}
               |> PushSubscription.changeset(attrs)
               |> Repo.insert(
                 on_conflict: {:replace, [:user_id, :session_id, :p256dh, :auth, :updated_at]},
                 conflict_target: :endpoint,
                 returning: true
               ) do
          :ok = prune(scope.user_id)
          {:ok, subscription}
        end
      end)
    end
  end

  @doc "Deletes the scope's subscription at `endpoint`, if it has one."
  def unsubscribe(%Scope{user_id: user_id}, endpoint) when is_binary(endpoint) do
    Repo.delete_all(
      from(subscription in PushSubscription,
        where: subscription.user_id == ^user_id and subscription.endpoint == ^endpoint
      )
    )

    :ok
  end

  @doc "The subscriptions whose browser session is live: the ones a push goes to."
  def live do
    now = DateTime.utc_now()

    from(subscription in PushSubscription,
      join: session in assoc(subscription, :session),
      where: is_nil(session.revoked_at) and session.expires_at > ^now
    )
  end

  defp live_session?(_scope, nil), do: false

  defp live_session?(%Scope{user_id: user_id}, session_id) do
    now = DateTime.utc_now()

    Repo.exists?(
      from(session in UserSession,
        where:
          session.id == ^session_id and session.user_id == ^user_id and
            session.context == "session" and is_nil(session.revoked_at) and
            session.expires_at > ^now
      )
    )
  end

  defp decode(%{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}})
       when is_binary(endpoint) and is_binary(p256dh) and is_binary(auth) do
    with {:ok, p256dh} <- Base.url_decode64(p256dh, padding: false),
         {:ok, auth} <- Base.url_decode64(auth, padding: false) do
      {:ok, %{endpoint: endpoint, p256dh: p256dh, auth: auth}}
    else
      :error -> {:error, :invalid}
    end
  end

  defp decode(_params), do: {:error, :invalid}

  defp prune(user_id) do
    kept =
      from(subscription in PushSubscription,
        where: subscription.user_id == ^user_id,
        order_by: [desc: subscription.updated_at, desc: subscription.id],
        limit: @per_member,
        select: subscription.id
      )

    Repo.delete_all(
      from(subscription in PushSubscription,
        where: subscription.user_id == ^user_id and subscription.id not in subquery(kept)
      )
    )

    :ok
  end
end
