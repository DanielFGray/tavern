defmodule TavernWeb.ServerComponents.ProfileCard do
  @moduledoc """
  The one profile card of the page. The container stays in the page so its hook keeps the
  listeners; the card inside it exists while the server holds a card. A trigger anywhere on the
  page opens it by carrying `data-profile-user-id` or `data-profile-username`, and the hook
  anchors the card to that trigger.
  """

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers,
    only: [member_status_class: 1, member_status_label: 1]

  attr :card, :map, default: nil

  def profile_card(assigns) do
    ~H"""
    <div id="profile-card-root" phx-hook="ProfileCardHook">
      <section
        :if={@card}
        id="profile-card"
        aria-label={"Profile of #{@card.user.display_name}"}
        class="profile-card z-50 w-80 max-w-[calc(100vw-1rem)] overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-2xl"
      >
        <div class="flex items-start gap-4 p-4">
          <div class="relative shrink-0">
            <.avatar user={@card.user} id="profile-card-avatar" class="size-20 text-3xl" />
            <span
              id="profile-card-status"
              title={member_status_label(@card.status)}
              class={[
                "absolute bottom-0 right-0 size-4 rounded-full border-2 border-base-100",
                member_status_class(@card.status)
              ]}
            />
          </div>

          <div class="min-w-0 flex-1 pt-1">
            <p
              id="profile-card-name"
              class="break-words text-lg font-semibold leading-6 text-base-content"
            >
              {@card.user.display_name}
            </p>
            <p id="profile-card-username" class="truncate text-sm text-base-content/60">
              @{@card.user.username}
            </p>
            <div class="mt-2 flex flex-wrap gap-1.5">
              <span
                :if={@card.user.membership.is_owner}
                id="profile-card-owner"
                class="rounded bg-emerald-500/15 px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-[0.16em] text-emerald-600 dark:text-emerald-200"
              >
                owner
              </span>
              <span
                :if={@card.user.bot}
                id="profile-card-bot"
                class="rounded bg-violet-500/15 px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-[0.16em] text-violet-600 dark:text-violet-200"
              >
                bot
              </span>
            </div>
          </div>
        </div>

        <div
          :if={@card.user.bio not in [nil, ""]}
          id="profile-card-bio"
          data-markdown-source={@card.user.bio}
          class="border-t border-base-300 px-4 py-3 text-sm leading-5 text-base-content/85 break-words [&>p]:m-0 [&>p+p]:mt-2 [&>ul]:m-0 [&>ul]:pl-5 [&>ol]:m-0 [&>ol]:pl-5"
        >
          {@card.user.bio}
        </div>

        <div
          :if={@card.roles != []}
          id="profile-card-roles"
          class="border-t border-base-300 px-4 py-3"
        >
          <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            Roles
          </p>
          <ul class="mt-2 flex flex-wrap gap-1.5">
            <li
              :for={role <- @card.roles}
              id={"profile-card-role-#{role.id}"}
              class="inline-flex items-center gap-1.5 rounded-full border border-base-300 px-2 py-0.5 text-xs text-base-content/85"
            >
              <span class="size-2.5 rounded-full" style={role_dot_style(role)} />
              {role.name}
            </li>
          </ul>
        </div>

        <p class="border-t border-base-300 px-4 py-2.5 text-[11px] text-base-content/55">
          Member since {Calendar.strftime(@card.user.membership.joined_at, "%b %-d, %Y")}
        </p>
      </section>
    </div>
    """
  end

  # A role without a colour keeps the neutral dot.
  defp role_dot_style(%{color: color}) when is_integer(color) and color > 0,
    do: "background-color: #" <> String.pad_leading(Integer.to_string(color, 16), 6, "0")

  defp role_dot_style(_role),
    do: "background-color: color-mix(in oklab, currentColor 40%, transparent)"
end
