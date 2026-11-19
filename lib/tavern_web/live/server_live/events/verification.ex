defmodule TavernWeb.ServerLive.Events.Verification do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Accounts
  alias TavernWeb.ServerLive.State

  def handle_event("resend_verification", _params, socket) do
    user = socket.assigns.current_user

    socket =
      case Accounts.resend_user_confirmation(user) do
        :ok ->
          put_flash(socket, :info, "We sent a new link to #{user.email}.")

        {:error, :not_needed} ->
          put_flash(socket, :info, "Your email is already confirmed.")

        {:error, {:rate_limited, seconds}} ->
          put_flash(socket, :error, "You can ask for another link in #{seconds} seconds.")

        {:error, _reason} ->
          put_flash(socket, :error, "The mail could not be sent. Try again later.")
      end

    {:noreply, socket}
  end

  # A member confirmed an email, possibly in another tab. In the member's own views the
  # Unverified role may be gone: reload the user (the banner and notices read it) and the open
  # channel (its permissions, composer and message actions). Other views reload the member list,
  # whose unverified badge may change.
  def handle_info({:email_confirmed, user_id}, socket) do
    socket =
      if user_id == socket.assigns.current_user.id do
        reload_own_view(socket)
      else
        State.refresh_member_presence(socket)
      end

    {:noreply, socket}
  end

  defp reload_own_view(socket) do
    socket =
      case Accounts.get_member(socket.assigns.current_scope, socket.assigns.current_user.id) do
        nil -> socket
        user -> assign(socket, :current_user, user)
      end

    case socket.assigns.active_channel do
      nil -> State.refresh_channels(socket)
      channel -> State.load_channel(socket, channel)
    end
  end
end
