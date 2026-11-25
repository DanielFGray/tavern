defmodule TavernWeb.ServerLive.Events.Notifications do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3]

  alias Tavern.Chat
  alias TavernWeb.ServerLive.State

  @events ~w(
    enable_desktop_mentions
    disable_desktop_mentions
    tab_visibility
  )

  def events, do: @events

  @doc """
  Shows an alert `Tavern.Chat.Alerts` decided for this member, unless this tab shows its
  conversation. The browser shows it only while the tab is hidden.
  """
  def handle_info({:alert, alert}, socket) do
    shown_ids = [socket.assigns.active_channel, socket.assigns.active_thread]

    if Enum.any?(shown_ids, &match?(%{id: id} when id == alert.channel_id, &1)) do
      {:noreply, socket}
    else
      {:noreply,
       push_event(socket, "notify:alert", Map.take(alert, [:title, :body, :tag, :path]))}
    end
  end

  def handle_event("tab_visibility", params, socket),
    do: {:noreply, State.set_tab_visible(socket, params["visible"] == true)}

  def handle_event("enable_desktop_mentions", _params, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_scope, %{
           desktop_enabled: true,
           notify_on_mentions: true
         }) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:notification_setting, setting)
         |> push_event("notifications:request-permission", %{})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not enable mention alerts.")}
    end
  end

  def handle_event("disable_desktop_mentions", _params, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_scope, %{
           desktop_enabled: false
         }) do
      {:ok, setting} ->
        {:noreply, assign(socket, :notification_setting, setting)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not disable mention alerts.")}
    end
  end
end
