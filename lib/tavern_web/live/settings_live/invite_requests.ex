defmodule TavernWeb.SettingsLive.InviteRequests do
  @moduledoc """
  The invite request queue in Settings > Server. `Chat` decides who may read and decide; a
  scope without `manage_applications` never sees the queue.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, stream: 4]

  alias Tavern.Chat
  alias Tavern.Chat.Visibility
  alias Tavern.Mailer

  @events ~w(approve_invite_request deny_invite_request deny_invite_requests_from_ip
             resend_invite_request)

  def events, do: @events

  def init(socket) do
    socket
    |> assign(
      :can_manage_applications?,
      Visibility.can?(socket.assigns.current_scope, :manage_applications, :server)
    )
    |> assign(:mail_missing_settings, Mailer.missing_settings())
    |> load()
  end

  @doc "Reads the queue again: every decision changes the rows and their per-IP counts."
  def load(socket) do
    requests =
      case Chat.list_invite_requests(socket.assigns.current_scope, :all) do
        {:ok, requests} -> requests
        {:error, :forbidden} -> []
      end

    stream(socket, :invite_requests, requests, reset: true)
  end

  def handle_event("approve_invite_request", %{"id" => id}, socket) do
    case Chat.approve_invite_request(socket.assigns.current_scope, id) do
      {:ok, %{delivery_error: nil}} -> reply(socket, :info, "Approved. The invite link was sent.")
      {:ok, %{delivery_error: error}} -> reply(socket, :error, "Approved, but #{error}.")
      {:error, reason} -> reply(socket, :error, refusal(reason))
    end
  end

  def handle_event("deny_invite_request", %{"id" => id}, socket) do
    case Chat.deny_invite_request(socket.assigns.current_scope, id) do
      {:ok, _request} -> reply(socket, :info, "Request denied.")
      {:error, reason} -> reply(socket, :error, refusal(reason))
    end
  end

  def handle_event("deny_invite_requests_from_ip", %{"ip" => ip_address}, socket) do
    case Chat.deny_invite_requests_from_ip(socket.assigns.current_scope, ip_address) do
      {:ok, count} -> reply(socket, :info, "Denied #{count} pending requests from that IP.")
      {:error, reason} -> reply(socket, :error, refusal(reason))
    end
  end

  def handle_event("resend_invite_request", %{"id" => id}, socket) do
    case Chat.resend_invite(socket.assigns.current_scope, id) do
      {:ok, %{delivery_error: nil}} -> reply(socket, :info, "The invite link was sent again.")
      {:ok, %{delivery_error: error}} -> reply(socket, :error, "Not resent: #{error}.")
      {:error, reason} -> reply(socket, :error, refusal(reason))
    end
  end

  defp reply(socket, kind, message), do: {:noreply, socket |> load() |> put_flash(kind, message)}

  defp refusal(:forbidden), do: "You cannot decide invite requests."
  defp refusal(:not_found), do: "That request no longer exists."
  defp refusal(:not_pending), do: "Someone already decided that request."
  defp refusal(:not_approved), do: "Only an approved request has an invite to resend."

  defp refusal(:invite_unusable),
    do: "Its invite was used, revoked or expired. Create a new invite instead."
end
