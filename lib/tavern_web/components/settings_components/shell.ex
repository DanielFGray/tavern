defmodule TavernWeb.SettingsComponents.Shell do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.SettingsComponents.Helpers

  def page(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-300 text-base-content transition-colors duration-200">
      <div class="mx-auto flex w-full max-w-7xl flex-col gap-4 px-4 py-4 sm:gap-5 sm:py-5 lg:flex-row lg:gap-6 lg:px-6 lg:py-6">
        <.sidebar {assigns} />

        <section class="min-w-0 flex-1 rounded-2xl border border-base-300 bg-base-100 p-4 shadow-lg sm:p-5 lg:p-6">
          <%= if @active_tab == "profile" do %>
            <TavernWeb.SettingsComponents.Tabs.profile_tab {assigns} />
          <% end %>

          <%= if @active_tab == "notifications" do %>
            <TavernWeb.SettingsComponents.Tabs.notifications_tab {assigns} />
          <% end %>

          <%= if @active_tab == "channel_notifications" do %>
            <TavernWeb.SettingsComponents.Tabs.channel_notifications_tab {assigns} />
          <% end %>

          <%= if @active_tab == "theme" do %>
            <TavernWeb.SettingsComponents.Tabs.theme_tab {assigns} />
          <% end %>

          <%= if @active_tab == "privacy" do %>
            <TavernWeb.SettingsComponents.Privacy.privacy_tab {assigns} />
          <% end %>

          <%= if @active_tab == "server" and @can_manage_server? do %>
            <TavernWeb.SettingsComponents.Server.server_tab {assigns} />
          <% end %>

          <%= if @active_tab == "emoji" and @can_manage_emojis? do %>
            <TavernWeb.SettingsComponents.Emoji.emoji_tab {assigns} />
          <% end %>

          <%= if @active_tab == "members" and members_tab?(assigns) do %>
            <TavernWeb.SettingsComponents.Server.members_tab {assigns} />
          <% end %>

          <%= if @active_tab == "invites" do %>
            <TavernWeb.SettingsComponents.Server.invites_tab {assigns} />
          <% end %>

          <%= if @active_tab == "bots" and @can_manage_bots? do %>
            <TavernWeb.SettingsComponents.Server.bots_tab {assigns} />
          <% end %>

          <%= if @active_tab == "roles" and @role_controls.manage_roles? do %>
            <TavernWeb.SettingsComponents.Roles.roles_tab {assigns} />
          <% end %>

          <%= if @active_tab == "audit" and @can_view_audit_log? do %>
            <TavernWeb.SettingsComponents.Audit.audit_tab {assigns} />
          <% end %>

          <%= if @active_tab == "direct_messages" and @owner_reader? do %>
            <TavernWeb.SettingsComponents.OwnerDirectMessages.direct_messages_tab {assigns} />
          <% end %>
        </section>
      </div>
    </div>
    """
  end

  def sidebar(assigns) do
    ~H"""
    <aside class="w-full shrink-0 rounded-2xl border border-base-300 bg-base-100 p-3 shadow-lg lg:sticky lg:top-6 lg:w-64">
      <div class="mb-3 border-b border-base-300 px-2 pb-3">
        <p class="text-[10px] font-bold uppercase tracking-[0.22em] text-base-content/50 sm:text-[11px]">
          Settings
        </p>
        <h1
          id="settings-panel-title"
          class="mt-1 text-base font-semibold text-base-content sm:text-lg"
        >
          Consolidated panel
        </h1>
      </div>

      <nav
        class={[
          "-mx-1 flex gap-2 overflow-x-auto px-1 pb-1",
          scrollbar_classes(),
          "lg:mx-0 lg:block lg:space-y-4 lg:overflow-visible lg:px-0 lg:pb-0"
        ]}
        aria-label="Settings tabs"
      >
        <.tab_group label="You" id="settings-group-you">
          <.tab_button
            active_tab={@active_tab}
            tab="profile"
            id="settings-tab-profile"
            label="Profile"
          />
          <.tab_button
            active_tab={@active_tab}
            tab="notifications"
            id="settings-tab-notifications"
            label="Notifications"
          />
          <.tab_button
            active_tab={@active_tab}
            tab="channel_notifications"
            id="settings-tab-channel-notifications"
            label="Channel notifications"
          />
          <.tab_button active_tab={@active_tab} tab="theme" id="settings-tab-theme" label="Theme" />
          <.tab_button
            active_tab={@active_tab}
            tab="privacy"
            id="settings-tab-privacy"
            label="Privacy"
          />
        </.tab_group>

        <.tab_group label="Server" id="settings-group-server">
          <.tab_button
            :if={@can_manage_server?}
            active_tab={@active_tab}
            tab="server"
            id="settings-tab-server"
            label="Server"
          />
          <.tab_button
            :if={@can_manage_emojis?}
            active_tab={@active_tab}
            tab="emoji"
            id="settings-tab-emoji"
            label="Emoji"
          />
          <.tab_button
            :if={members_tab?(assigns)}
            active_tab={@active_tab}
            tab="members"
            id="settings-tab-members"
            label="Members & moderation"
          />
          <.tab_button
            active_tab={@active_tab}
            tab="invites"
            id="settings-tab-invites"
            label="Invites"
          />
          <.tab_button
            :if={@can_manage_bots?}
            active_tab={@active_tab}
            tab="bots"
            id="settings-tab-bots"
            label="Bots"
          />
          <.tab_button
            :if={@role_controls.manage_roles?}
            active_tab={@active_tab}
            tab="roles"
            id="settings-tab-roles"
            label="Roles"
          />
          <.tab_button
            :if={@can_view_audit_log?}
            active_tab={@active_tab}
            tab="audit"
            id="settings-tab-audit"
            label="Audit log"
          />
          <.tab_button
            :if={@owner_reader?}
            active_tab={@active_tab}
            tab="direct_messages"
            id="settings-tab-direct-messages"
            label="Direct messages"
          />
        </.tab_group>
      </nav>

      <.link
        navigate={~p"/"}
        id="back-to-chat-link"
        class="mt-4 inline-flex min-h-11 items-center justify-center rounded-xl border border-base-300 px-3.5 py-2.5 text-sm font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content lg:flex"
      >
        Back to chat
      </.link>
    </aside>
    """
  end

  # The Members & moderation tab shows to a member who moderates or manages roles.
  defp members_tab?(assigns),
    do: assigns.can_moderate_members? or assigns.role_controls.manage_roles?

  attr :label, :string, required: true
  attr :id, :string, required: true
  slot :inner_block, required: true

  # A heading over a run of tabs. On a phone the groups sit in one scrolling row, so the heading
  # is hidden there and the tabs keep their order.
  def tab_group(assigns) do
    ~H"""
    <div id={@id} class="flex gap-2 lg:block lg:space-y-1">
      <p class="hidden px-3.5 pb-1 text-[10px] font-bold uppercase tracking-[0.22em] text-base-content/45 lg:block">
        {@label}
      </p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :active_tab, :string, required: true
  attr :tab, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true

  def tab_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        "min-h-11 shrink-0 rounded-xl px-3.5 py-2.5 text-left text-sm font-medium whitespace-nowrap transition lg:w-full",
        tab_active?(@active_tab, @tab) && "bg-primary/15 text-primary",
        !tab_active?(@active_tab, @tab) &&
          "text-base-content/75 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      {@label}
    </button>
    """
  end
end
