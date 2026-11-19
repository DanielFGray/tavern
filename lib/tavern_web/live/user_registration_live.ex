defmodule TavernWeb.UserRegistrationLive do
  use TavernWeb, :live_view

  alias Ecto.Changeset
  alias Tavern.Accounts
  alias Tavern.Chat
  alias Tavern.Chat.User

  @impl true
  def mount(%{"code" => code}, _session, socket) when is_binary(code) do
    mount_from_params(code, socket)
  end

  def mount(_params, _session, socket) do
    mount_from_params("", socket)
  end

  defp mount_from_params(invite_code, socket) do
    form = %User{} |> Accounts.change_registration_user() |> to_form()

    server_settings = Chat.get_server_settings()

    {:ok,
     socket
     |> assign(:page_title, "Register")
     |> assign(:server_settings, server_settings)
     |> assign(:current_server, server_settings)
     |> assign(:form, form)
     |> assign(:invite_required?, server_settings.registration_mode == :invite_only)
     |> assign(:invite_code, String.trim(invite_code))
     |> assign(:trigger_submit, false)}
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      %User{}
      |> Accounts.change_registration_user(user_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:invite_code, invite_code_param(user_params))}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    invite_code = invite_code_param(user_params)

    opts = if invite_code == "", do: [], else: [invite_code: invite_code]

    # `invite_required?` only decides whether the form shows the code field; the registration
    # mode is decided in `Accounts.register_user/2`, from the database.
    case Accounts.register_user(user_params, opts) do
      {:ok, user} ->
        signed_in(socket, user, user_params)

      {:error, :invite_required} ->
        {:noreply,
         socket
         |> assign(:invite_required?, true)
         |> put_flash(:error, "An invite code is required to register.")}

      {:error, :invalid_invite} ->
        {:noreply, put_flash(socket, :error, "That invite code is not valid.")}

      {:error, %Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp signed_in(socket, user, user_params) do
    {:noreply,
     socket
     |> assign(:trigger_submit, true)
     |> assign(
       :form,
       to_form(
         %{
           "email" => user.email,
           "password" => Map.get(user_params, "password", ""),
           "remember_me" => "true"
         },
         as: :user
       )
     )}
  end

  defp invite_code_param(user_params),
    do: user_params["invite_code"] |> to_string() |> String.trim()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-base-300 px-4 py-10 text-base-content sm:px-6 lg:px-8 transition-colors duration-200">
        <div class="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.05fr,0.95fr] lg:items-center">
          <section class="rounded-[2rem] border border-base-content/10 bg-base-100/90 p-8 shadow-xl lg:p-12">
            <Layouts.server_identity server={@server_settings} class="mb-6" />
            <h1 class="mt-5 text-4xl font-semibold tracking-tight text-base-content lg:text-5xl">
              Create your {@server_settings.name} identity.
            </h1>
            <p class="mt-5 max-w-xl text-base leading-7 text-base-content/70">
              Register once for this self-hosted server instance, then chat under your own profile.
            </p>
          </section>

          <section class="rounded-[2rem] border border-base-content/10 bg-base-100 p-6 shadow-xl lg:p-8">
            <.form
              for={@form}
              id="registration-form"
              action={~p"/login?_action=registered"}
              method="post"
              phx-change="validate"
              phx-submit="save"
              phx-trigger-action={@trigger_submit}
            >
              <div class="space-y-5">
                <div>
                  <p class="text-2xl font-semibold text-base-content">Create account</p>
                </div>

                <.input
                  field={@form[:email]}
                  type="email"
                  label="Email"
                  required
                  class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                />
                <.input
                  field={@form[:username]}
                  type="text"
                  label="Username"
                  required
                  class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                />
                <.input
                  field={@form[:display_name]}
                  type="text"
                  label="Display name"
                  required
                  class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                />
                <.input
                  field={@form[:password]}
                  type="password"
                  label="Password"
                  required
                  class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                />
                <.input
                  :if={@invite_required?}
                  name="user[invite_code]"
                  value={@invite_code}
                  type="text"
                  label="Invite code"
                  required
                  class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                />

                <button
                  id="registration-submit"
                  type="submit"
                  class="inline-flex w-full items-center justify-center rounded-2xl bg-emerald-500 px-4 py-3 text-sm font-semibold text-zinc-950 transition hover:bg-emerald-400"
                >
                  Create account
                </button>

                <p class="text-sm text-base-content/70">
                  Already have an account?
                  <.link
                    navigate={~p"/login"}
                    class="font-semibold text-primary transition hover:text-primary/80"
                  >
                    Log in
                  </.link>
                </p>
              </div>
            </.form>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
