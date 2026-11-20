defmodule TavernWeb.PasswordResetLive do
  @moduledoc """
  Sets a new password from a reset link. The token is the authority, so the page works signed in
  or not. A link that is used, expired or not valid shows an error with a way to ask for a new
  one. A saved password sends the member to the login page: the reset ends every session.
  """
  use TavernWeb, :live_view

  alias Tavern.Accounts
  alias Tavern.Chat
  alias Tavern.Chat.User

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    server_settings = Chat.get_server_settings()

    {:ok,
     socket
     |> assign(:page_title, "Choose a new password")
     |> assign(:server_settings, server_settings)
     |> assign(:current_server, server_settings)
     |> assign(:token, token)
     |> assign(:valid?, Accounts.get_user_by_password_reset_token(token) != nil)
     |> assign(:form, to_form(Accounts.change_password_user(%User{}), as: :user))}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    # A keystroke must not hash the password (about a quarter second of bcrypt), so validation
    # skips the hash like the registration form does.
    changeset =
      %User{}
      |> Accounts.change_password_user(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.reset_user_password(socket.assigns.token, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Your password is changed. Log in with the new password.")
         |> redirect(to: ~p"/login")}

      {:error, :invalid} ->
        {:noreply, assign(socket, :valid?, false)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
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
            <h1 class="text-2xl font-semibold text-base-content">Choose a new password</h1>

            <%= if @valid? do %>
              <.form
                for={@form}
                id="password-reset-form"
                phx-change="validate"
                phx-submit="save"
                class="mt-5 space-y-5"
              >
                <p class="text-sm text-base-content/70">
                  Saving it signs this account out everywhere.
                </p>
                <.input
                  field={@form[:password]}
                  type="password"
                  label="New password"
                  autocomplete="new-password"
                  required
                  class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                />
                <button
                  id="password-reset-submit"
                  type="submit"
                  phx-disable-with="Saving…"
                  class="inline-flex w-full items-center justify-center rounded-2xl bg-violet-500 px-4 py-3 text-sm font-semibold text-white transition hover:bg-violet-400"
                >
                  Change password
                </button>
              </.form>
            <% else %>
              <div
                id="password-reset-invalid"
                class="mt-5 rounded-2xl border border-rose-500/30 bg-rose-500/10 px-4 py-3 text-sm text-base-content"
              >
                <p class="font-semibold">This reset link does not work</p>
                <p class="mt-1 text-base-content/70">
                  It is used, expired or not valid. Ask for a new one.
                </p>
              </div>
              <.link
                id="request-new-reset"
                href={~p"/users/reset-password"}
                class="mt-4 inline-flex text-sm font-semibold text-primary transition hover:text-primary/80"
              >
                Send a new reset link
              </.link>
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
