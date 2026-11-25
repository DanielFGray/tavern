defmodule TavernWeb.SettingsComponents.Privacy do
  @moduledoc false

  use TavernWeb, :html

  def privacy_tab(assigns) do
    ~H"""
    <div id="settings-view-privacy">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Privacy
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Direct messages and blocks</h2>

      <div
        id="direct-message-privacy-setting"
        class="mt-5 flex items-start gap-3 rounded-xl border border-base-300 bg-base-200 p-4"
      >
        <.icon
          name={if(@direct_message_privacy == :private, do: "hero-lock-closed", else: "hero-eye")}
          class="mt-0.5 size-5 shrink-0 text-base-content/60"
        />
        <div>
          <p class="text-sm font-semibold text-base-content">Who can read direct messages</p>
          <p class="mt-1 text-sm text-base-content/70">
            <%= if @direct_message_privacy == :private do %>
              Only the two people in a direct message can read it. Server staff cannot.
            <% else %>
              The server owner can read direct messages on this server. Each time they open one,
              the audit log records it.
            <% end %>
          </p>
        </div>
      </div>

      <div class="mt-4 flex items-center justify-between gap-4 rounded-xl border border-base-300 bg-base-200 p-4">
        <div>
          <p class="text-sm font-semibold text-base-content">Messages from new contacts</p>
          <p class="mt-1 text-sm text-base-content/70">
            Let members you have no direct message with yet start one. Your existing direct
            messages stay open either way.
          </p>
        </div>
        <button
          type="button"
          id="toggle-direct-messages-from-new-contacts"
          role="switch"
          aria-checked={to_string(@current_user.direct_messages_from_new_contacts)}
          aria-label="Messages from new contacts"
          phx-click="toggle_direct_messages_from_new_contacts"
          class={[
            "relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors duration-200",
            if(@current_user.direct_messages_from_new_contacts,
              do: "bg-violet-500",
              else: "bg-base-300"
            )
          ]}
        >
          <span class={[
            "inline-block size-5 rounded-full bg-white shadow transition-transform duration-200",
            if(@current_user.direct_messages_from_new_contacts,
              do: "translate-x-5",
              else: "translate-x-0.5"
            )
          ]} />
        </button>
      </div>

      <div class="mt-6">
        <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
          Blocked accounts
        </p>
        <p class="mt-1 text-sm text-base-content/70">
          A blocked account's messages collapse for you, and neither of you can send direct
          messages to the other. Block someone from their profile card.
        </p>

        <p
          :if={@blocked_users == []}
          id="blocked-users-empty"
          class="mt-3 rounded-xl border border-dashed border-base-300 px-4 py-5 text-sm text-base-content/55"
        >
          You have not blocked anyone.
        </p>

        <ul :if={@blocked_users != []} id="blocked-users" class="mt-3 space-y-2">
          <li
            :for={user <- @blocked_users}
            id={"blocked-user-#{user.id}"}
            class="flex items-center gap-3 rounded-xl border border-base-300 bg-base-200 px-3 py-2.5"
          >
            <.avatar user={user} class="size-9 text-xs" />
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium text-base-content">{user.display_name}</p>
              <p class="truncate text-xs text-base-content/55">@{user.username}</p>
            </div>
            <button
              type="button"
              id={"unblock-user-#{user.id}"}
              phx-click="unblock_user"
              phx-value-id={user.id}
              class="rounded-md px-2.5 py-1 text-xs font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
            >
              Unblock
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
