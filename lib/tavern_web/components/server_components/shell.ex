defmodule TavernWeb.ServerComponents.Shell do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  attr :server, :map, required: true

  def mobile_overlays(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="close_mobile_sidebar"
      id="mobile-sidebar-overlay"
      class={[
        "fixed inset-0 z-30 bg-black/65 transition xl:hidden",
        mobile_sidebar_overlay_class(@server.mobile_sidebar_open?)
      ]}
      aria-label="Close channel list"
    />

    <button
      type="button"
      phx-click="close_mobile_members"
      id="mobile-members-overlay"
      class={[
        "fixed inset-0 z-30 bg-black/65 transition xl:hidden",
        mobile_sidebar_overlay_class(@server.mobile_members_open?)
      ]}
      aria-label="Close members list"
    />
    """
  end

  attr :server, :map, required: true

  def mobile_channel_drawer(assigns) do
    ~H"""
    <aside
      id="mobile-channel-drawer"
      class={[
        "fixed inset-y-0 left-0 z-40 flex w-[85vw] max-w-72 shrink-0 flex-col border-r border-base-300 bg-base-200 transition-transform duration-200 ease-out xl:static xl:z-auto xl:w-64 xl:max-w-none xl:border-b-0 xl:border-r-base-300",
        mobile_sidebar_class(@server.mobile_sidebar_open?)
      ]}
    >
      <div class="flex items-center justify-between border-b border-base-300 px-4 py-3 shadow-sm">
        <Layouts.server_identity server={@server.server_settings} />

        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="close_mobile_sidebar"
            id="close-mobile-sidebar"
            class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-100 hover:text-base-content xl:hidden"
          >
            Close
          </button>
        </div>
      </div>

      <div class={["flex-1 overflow-y-auto px-2 py-3", scrollbar_classes()]}>
        <div class="mb-2 flex items-center justify-between px-2">
          <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            Channels
          </p>
          <div class="flex items-center gap-1">
            <span class="rounded bg-base-300 px-1.5 py-0.5 text-[10px] font-semibold text-base-content/60">
              {length(@server.channels)}
            </span>
            <TavernWeb.ServerComponents.ChannelEditor.edit_toggle server={@server} />
          </div>
        </div>

        <%= cond do %>
          <% @server.navigation_ready? and @server.channel_edit_mode? -> %>
            <TavernWeb.ServerComponents.ChannelEditor.edit_nav server={@server} />
          <% @server.navigation_ready? -> %>
            <.channel_nav server={@server} />
          <% true -> %>
            <div class="space-y-2 px-2 py-1 text-xs text-base-content/55">
              <p class="font-semibold uppercase tracking-[0.16em]">Loading channels...</p>
              <div :for={_ <- 1..4} class="h-8 rounded-md bg-base-100/70 animate-pulse" />
            </div>
        <% end %>
      </div>

      <div class="border-t border-base-300 bg-base-100 px-3 py-2">
        <div class="relative" phx-click-away="close_user_menu">
          <div
            :if={@server.user_menu_open?}
            id="user-menu"
            role="menu"
            aria-label="User menu"
            class="absolute bottom-full left-0 right-0 z-20 mb-2 rounded-lg border border-base-300 bg-base-100 p-1 shadow-lg"
          >
            <.link
              navigate={~p"/settings"}
              id="user-menu-settings"
              role="menuitem"
              class="block rounded-md px-3 py-2 text-[13px] font-medium text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
            >
              Settings
            </.link>
            <.link
              href={~p"/logout"}
              method="delete"
              id="logout-link"
              role="menuitem"
              class="block rounded-md px-3 py-2 text-[13px] font-medium text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
            >
              Log out
            </.link>
          </div>

          <div class="flex items-center justify-between gap-3">
            <button
              type="button"
              id="user-menu-button"
              phx-click="toggle_user_menu"
              aria-haspopup="menu"
              aria-expanded={to_string(@server.user_menu_open?)}
              class="flex min-w-0 flex-1 items-center gap-2 rounded-md px-1 py-1 text-left transition hover:bg-base-200"
            >
              <div class="relative shrink-0">
                <.avatar user={@server.current_user} class="size-9 text-xs" />
                <span class="absolute -bottom-0.5 -right-0.5 size-3 rounded-full border-2 border-base-100 bg-emerald-400" />
              </div>
              <div class="min-w-0">
                <p class="truncate text-[13px] font-semibold leading-4 text-base-content">
                  {@server.current_user.display_name}
                </p>
                <p class="truncate text-[11px] text-base-content/65">
                  @{@server.current_user.username}
                </p>
              </div>
            </button>

            <Layouts.theme_toggle />
          </div>
        </div>
      </div>
    </aside>
    """
  end

  attr :server, :map, required: true

  def members_drawer(assigns) do
    ~H"""
    <aside
      id="mobile-members-drawer"
      class={[
        "fixed inset-y-0 right-0 z-40 flex h-dvh w-[82vw] max-w-72 shrink-0 flex-col border-l border-base-300 bg-base-200 transition-transform duration-200 ease-out xl:static xl:z-auto xl:h-auto xl:w-60 xl:max-w-none",
        mobile_members_class(@server.mobile_members_open?),
        @server.members_collapsed? && "xl:hidden"
      ]}
    >
      <div class="border-b border-base-300 px-4 py-3">
        <div class="flex items-center justify-between gap-3">
          <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            Members
          </p>
          <button
            type="button"
            phx-click="close_mobile_members"
            id="close-mobile-members"
            class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-100 hover:text-base-content xl:hidden"
          >
            Close
          </button>
        </div>
        <div class="mt-2 flex items-center justify-between text-xs text-base-content/65">
          <%= if @server.members_ready? do %>
            <span>{length(@server.member_presence)} visible</span>
            <span class="rounded bg-base-300 px-1.5 py-0.5 text-[10px] font-semibold text-base-content/80">
              {Enum.count(@server.member_presence, &(&1.status == :online))} online
            </span>
          <% else %>
            <span>Loading members...</span>
            <span class="rounded bg-base-300 px-1.5 py-0.5 text-[10px] font-semibold text-base-content/80">
              ...
            </span>
          <% end %>
        </div>
      </div>

      <div
        id="member-sidebar"
        class={["flex-1 space-y-0.5 overflow-y-auto px-2 py-3", scrollbar_classes()]}
      >
        <%= if @server.members_ready? do %>
          <TavernWeb.ServerComponents.Navigation.member_presence_item
            :for={entry <- @server.member_presence}
            entry={entry}
          />
        <% else %>
          <div class="space-y-2 px-1">
            <div :for={_ <- 1..5} class="h-12 rounded-md bg-base-100/70 animate-pulse" />
          </div>
        <% end %>
      </div>
    </aside>
    """
  end

  attr :server, :map, required: true

  defp channel_nav(assigns) do
    ~H"""
    <%= if @server.channel_sections == [] do %>
      <p id="no-visible-channels" class="px-2 py-3 text-xs text-base-content/55">
        No channels you can view yet.
      </p>
    <% else %>
      <nav class="space-y-3" aria-label="Server channels">
        <TavernWeb.ServerComponents.Navigation.channel_nav_section
          :for={section <- @server.channel_sections}
          section={section}
          server={@server}
          show_label={length(@server.channel_sections) > 1}
        />
      </nav>
    <% end %>
    """
  end
end
