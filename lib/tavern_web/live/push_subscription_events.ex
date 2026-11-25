defmodule TavernWeb.PushSubscriptionEvents do
  @moduledoc """
  The push subscription events a page's hook sends: the Settings push card, and the chat page,
  which sends this browser's subscription again on load so it follows the session signed in now
  (docs/design/push-notifications.md). The LiveView must assign `:session_id` at mount.
  """

  alias Tavern.Accounts
  alias Tavern.Chat.PushSubscriptions

  @events ~w(push_subscribe push_unsubscribe)

  def events, do: @events

  @doc "The live browser session of a LiveView's connect session, for the `:session_id` assign."
  def session_id(%{"user_token" => token}), do: Accounts.session_id(token)
  def session_id(_session), do: nil

  def handle_event("push_subscribe", params, socket) do
    %{current_scope: scope, session_id: session_id} = socket.assigns

    case PushSubscriptions.subscribe(scope, session_id, params) do
      {:ok, _subscription} -> {:reply, %{ok: true}, socket}
      {:error, _reason} -> {:reply, %{ok: false}, socket}
    end
  end

  def handle_event("push_unsubscribe", %{"endpoint" => endpoint}, socket)
      when is_binary(endpoint) do
    :ok = PushSubscriptions.unsubscribe(socket.assigns.current_scope, endpoint)
    {:noreply, socket}
  end
end
