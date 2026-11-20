defmodule TavernWeb.PasswordResetRequestLive do
  @moduledoc """
  Asks for a password reset link. Every email gets the same reply, so the page does not tell a
  visitor which emails have accounts (docs/design/accounts.md). With no mail provider the page
  says reset is unavailable.
  """
  use TavernWeb, :live_view

  alias Tavern.Accounts
  alias Tavern.Chat
  alias TavernWeb.Plugs.ClientIp

  @impl true
  def mount(_params, _session, socket) do
    server_settings = Chat.get_server_settings()

    {:ok,
     socket
     |> assign(:page_title, "Reset your password")
     |> assign(:server_settings, server_settings)
     |> assign(:current_server, server_settings)
     |> assign(:available?, Accounts.password_reset_available?())
     |> assign(:sent?, false)
     |> assign(:client_ip, client_ip_string(socket))
     |> assign(:form, to_form(%{"email" => ""}, as: :reset))}
  end

  @impl true
  def handle_event("request", %{"reset" => %{"email" => email}}, socket) do
    case Accounts.request_password_reset(email, socket.assigns.client_ip) do
      :ok ->
        {:noreply, assign(socket, :sent?, true)}

      {:error, {:rate_limited, seconds}} ->
        {:noreply,
         put_flash(socket, :error, "Too many attempts. Try again in #{seconds} seconds.")}
    end
  end

  defp client_ip_string(socket) do
    case ClientIp.socket_client_ip(socket) do
      nil -> "unknown"
      ip_address -> ip_address |> :inet.ntoa() |> to_string()
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-base-300 px-4 py-10 text-base-content sm:px-6 lg:px-8 transition-colors duration-200">
        <div class="mx-auto max-w-md">
          <section class="rounded-[2rem] border border-base-content/10 bg-base-100 p-6 shadow-xl lg:p-8">
            <Layouts.server_identity server={@server_settings} class="mb-6" />
            <h1 class="text-2xl font-semibold text-base-content">Reset your password</h1>

            <%= cond do %>
              <% not @available? -> %>
                <div
                  id="password-reset-unavailable"
                  class="mt-5 rounded-2xl border border-amber-500/30 bg-amber-500/10 px-4 py-3 text-sm text-base-content"
                >
                  <p class="font-semibold">Password reset is unavailable</p>
                  <p class="mt-1 text-base-content/70">
                    This server cannot send mail. Ask a server admin to set your password.
                  </p>
                </div>
              <% @sent? -> %>
                <div
                  id="password-reset-sent"
                  class="mt-5 rounded-2xl border border-emerald-500/30 bg-emerald-500/10 px-4 py-3 text-sm text-base-content"
                >
                  <p class="font-semibold">Check your email</p>
                  <p class="mt-1 text-base-content/70">
                    If that email belongs to an account, a reset link is on its way. It works once, for 1 hour.
                  </p>
                </div>
              <% true -> %>
                <.form
                  for={@form}
                  id="password-reset-request-form"
                  phx-submit="request"
                  class="mt-5 space-y-5"
                >
                  <p class="text-sm text-base-content/70">
                    Enter your account email. We mail you a link that sets a new password.
                  </p>
                  <.input
                    field={@form[:email]}
                    type="email"
                    label="Email"
                    required
                    class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                  />
                  <button
                    id="password-reset-request-submit"
                    type="submit"
                    phx-disable-with="Sending…"
                    class="inline-flex w-full items-center justify-center rounded-2xl bg-violet-500 px-4 py-3 text-sm font-semibold text-white transition hover:bg-violet-400"
                  >
                    Send reset link
                  </button>
                </.form>
            <% end %>

            <p class="mt-6 text-sm text-base-content/70">
              <.link
                id="back-to-login"
                href={~p"/login"}
                class="font-semibold text-primary transition hover:text-primary/80"
              >
                Back to log in
              </.link>
            </p>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
