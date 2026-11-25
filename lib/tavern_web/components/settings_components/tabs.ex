defmodule TavernWeb.SettingsComponents.Tabs do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.SettingsComponents.Helpers

  def profile_tab(assigns) do
    ~H"""
    <div id="settings-view-profile">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Profile basics
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Account profile</h2>

      <.form
        for={@profile_form}
        id="profile-form"
        phx-change="change_profile"
        phx-submit="save_profile"
        class="mt-5 space-y-4"
      >
        <.input field={@profile_form[:display_name]} type="text" label="Display name" />
        <.input field={@profile_form[:username]} type="text" label="Username" />
        <.input
          field={@profile_form[:bio]}
          type="textarea"
          label="Bio (Markdown, up to 300 characters)"
          maxlength="300"
          rows="4"
        />

        <div id="avatar-field" class="rounded-xl border border-dashed border-base-300 bg-base-200 p-4">
          <p class="text-[11px] font-semibold uppercase tracking-[0.16em] text-base-content/50">
            Avatar
          </p>
          <div class="mt-3 flex items-center gap-4">
            <%= if entry = List.first(@uploads.avatar.entries) do %>
              <.live_img_preview
                entry={entry}
                id="avatar-preview"
                class="size-16 rounded-full border border-base-300 object-cover"
              />
            <% else %>
              <.avatar user={@current_user} id="avatar-current" class="size-16 text-xl" />
            <% end %>

            <div class="min-w-0 flex-1">
              <.live_file_input
                upload={@uploads.avatar}
                class="block w-full text-sm text-base-content/85"
              />
              <p class="mt-2 text-[11px] text-base-content/50">
                png, jpg, gif, or webp, up to 2 MB. Shown as a square.
              </p>
            </div>
          </div>

          <p
            :for={err <- upload_errors(@uploads.avatar)}
            class="mt-2 text-[11px] text-rose-300"
          >
            {upload_error(err)}
          </p>

          <div class="mt-3 flex flex-wrap gap-2">
            <button
              :for={entry <- @uploads.avatar.entries}
              type="button"
              phx-click="cancel_avatar_upload"
              phx-value-ref={entry.ref}
              id="cancel-avatar-upload"
              class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
            >
              Cancel upload
            </button>
            <button
              :if={@current_user.avatar_asset && @uploads.avatar.entries == []}
              type="button"
              phx-click="remove_avatar"
              id="remove-avatar"
              class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
            >
              Remove avatar
            </button>
          </div>
        </div>

        <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
          Save profile
        </.button>
      </.form>

      <.form
        for={@email_form}
        id="email-form"
        phx-submit="save_email"
        class="mt-8 space-y-4 border-t border-base-300 pt-6"
      >
        <p class="text-[11px] font-semibold uppercase tracking-[0.16em] text-base-content/50">
          Sign-in email
        </p>
        <.input field={@email_form[:email]} type="email" label="New email" />
        <.input
          field={@email_form[:password]}
          type="password"
          label="Current password"
          autocomplete="current-password"
        />

        <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
          Change email
        </.button>
      </.form>
    </div>
    """
  end

  def notifications_tab(assigns) do
    ~H"""
    <div id="settings-view-notifications">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Notifications
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Global preferences</h2>

      <div class="mt-5 rounded-xl border border-base-300 bg-base-200 p-4">
        <div class="flex items-center justify-between gap-3">
          <div>
            <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/50">
              Mention alerts
            </p>
            <p class="mt-1 text-[11px] text-base-content/70">
              Notify when someone mentions you in another channel.
            </p>
          </div>

          <button
            :if={not mention_alerts_enabled?(@notification_setting)}
            type="button"
            phx-click="enable_desktop_mentions"
            id="enable-desktop-mentions"
            class="rounded-md bg-violet-500 px-2.5 py-1 text-[11px] font-semibold text-white transition hover:bg-violet-400"
          >
            Enable
          </button>

          <button
            :if={mention_alerts_enabled?(@notification_setting)}
            type="button"
            phx-click="disable_desktop_mentions"
            id="disable-desktop-mentions"
            class="rounded-md px-2.5 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
          >
            On
          </button>
        </div>
      </div>

      <.push_alerts_card public_key={@push_public_key} />

      <.form
        for={@notification_form}
        id="notification-form"
        phx-submit="save_notifications"
        class="mt-5 grid gap-4 md:grid-cols-2"
      >
        <.input field={@notification_form[:desktop_enabled]} type="checkbox" label="Desktop alerts" />
        <.input
          field={@notification_form[:notify_on_all_messages]}
          type="checkbox"
          label="Notify on all messages"
        />
        <.input
          field={@notification_form[:notify_on_mentions]}
          type="checkbox"
          label="Notify on mentions"
        />
        <.input
          field={@notification_form[:suppress_everyone]}
          type="checkbox"
          label="Suppress @everyone"
        />
        <.input
          field={@notification_form[:suppress_roles]}
          type="checkbox"
          label="Suppress role mentions"
        />

        <div class="md:col-span-2">
          <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
            Save notification preferences
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  attr :public_key, :string, default: nil

  # Push is per device, so the browser, not the server, knows whether this device is on: the
  # hook reads the subscription and shows the one line and button for its state.
  defp push_alerts_card(assigns) do
    ~H"""
    <div
      id="push-alerts"
      phx-hook=".PushAlerts"
      phx-update="ignore"
      data-public-key={@public_key}
      data-state="checking"
      class="group mt-3 rounded-xl border border-base-300 bg-base-200 p-4"
    >
      <div class="flex items-center justify-between gap-3">
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/50">
            Push alerts on this device
          </p>
          <p class="mt-1 text-[11px] text-base-content/70">
            Alerts reach this device even when Tavern is closed. Turn it on for each phone or
            browser you use.
          </p>
          <p class="mt-2 hidden text-[11px] text-warning group-data-[state=unsupported]:block">
            This browser cannot receive push alerts.
          </p>
          <p class="mt-2 hidden text-[11px] text-warning group-data-[state=install]:block">
            On iPhone and iPad, add Tavern to the Home Screen first (Share, then Add to Home
            Screen), and turn push on from there.
          </p>
          <p class="mt-2 hidden text-[11px] text-warning group-data-[state=denied]:block">
            This browser blocks notifications from Tavern. Allow them in the site settings.
          </p>
          <p class="mt-2 hidden text-[11px] text-warning group-data-[state=unavailable]:block">
            Push is off on this server.
          </p>
          <p class="mt-2 hidden text-[11px] text-error group-data-[state=failed]:block">
            Could not turn push on. Try again.
          </p>
        </div>

        <button
          type="button"
          id="enable-push"
          data-push-action="enable"
          class="hidden shrink-0 rounded-md bg-violet-500 px-2.5 py-1 text-[11px] font-semibold text-white transition hover:bg-violet-400 group-data-[state=failed]:block group-data-[state=off]:block"
        >
          Turn on
        </button>
        <button
          type="button"
          id="disable-push"
          data-push-action="disable"
          class="hidden shrink-0 rounded-md px-2.5 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content group-data-[state=on]:block"
        >
          On · turn off
        </button>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PushAlerts">
      // docs/design/push-notifications.md, "The browser side".
      const appleTouch = () =>
        /iP(hone|ad|od)/.test(navigator.userAgent) ||
        (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)

      const keyBytes = key => {
        const base64 = (key + "=".repeat((4 - key.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/")
        return Uint8Array.from(atob(base64), c => c.charCodeAt(0))
      }

      export default {
        mounted() {
          this.el.addEventListener("click", event => {
            const action = event.target.closest("[data-push-action]")?.dataset.pushAction
            if (action === "enable") this.enable()
            if (action === "disable") this.disable()
          })
          this.refresh()
        },

        setState(state) {
          this.el.dataset.state = state
        },

        supported() {
          return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
        },

        async subscription() {
          const registration = await navigator.serviceWorker.getRegistration("/")
          return registration ? registration.pushManager.getSubscription() : null
        },

        // A subscription this device already holds is sent again, so the server has it under the
        // member and session signed in now. One made with another server key gets no push that
        // this server signs, so it is dropped and the card offers to turn push on again.
        async refresh() {
          if (!this.supported()) return this.setState(appleTouch() ? "install" : "unsupported")
          if (!this.el.dataset.publicKey) return this.setState("unavailable")
          if (Notification.permission === "denied") return this.setState("denied")

          let subscription = await this.subscription()
          if (subscription && !this.sameKey(subscription.options.applicationServerKey)) {
            this.pushEvent("push_unsubscribe", {endpoint: subscription.endpoint})
            await subscription.unsubscribe()
            subscription = null
          }

          if (subscription) this.pushEvent("push_subscribe", subscription.toJSON())
          this.setState(subscription ? "on" : "off")
        },

        sameKey(buffer) {
          if (!buffer) return true
          const held = new Uint8Array(buffer)
          const current = keyBytes(this.el.dataset.publicKey)
          return held.length === current.length && held.every((byte, i) => byte === current[i])
        },

        // The permission request must run first, inside the click: Safari refuses it otherwise.
        async enable() {
          try {
            const permission = await Notification.requestPermission()
            if (permission !== "granted") return this.refresh()

            await navigator.serviceWorker.register("/sw.js", {scope: "/"})
            const registration = await navigator.serviceWorker.ready
            const subscription = await registration.pushManager.subscribe({
              userVisibleOnly: true,
              applicationServerKey: keyBytes(this.el.dataset.publicKey),
            })

            this.pushEvent("push_subscribe", subscription.toJSON(), reply => {
              this.setState(reply.ok ? "on" : "failed")
            })
          } catch (_error) {
            this.setState("failed")
          }
        },

        async disable() {
          const subscription = await this.subscription()
          if (subscription) {
            this.pushEvent("push_unsubscribe", {endpoint: subscription.endpoint})
            await subscription.unsubscribe()
          }
          this.setState("off")
        },
      }
    </script>
    """
  end

  def channel_notifications_tab(assigns) do
    ~H"""
    <div id="settings-view-channel-notifications">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Channel notifications
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Per-channel overrides</h2>

      <div class={["mt-5 space-y-3 overflow-y-auto max-h-[70vh] pr-1", scrollbar_classes()]}>
        <div
          :for={section <- @channel_sections}
          id={"channel-notification-section-#{section.category && section.category.slug || "uncategorized"}"}
          class="rounded-xl border border-base-300 bg-base-200 p-3"
        >
          <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            {section_label(section.category)}
          </p>

          <div class="mt-3 space-y-2">
            <div
              :for={channel <- section.channels}
              id={"channel-notification-#{channel.slug}"}
              class="rounded-lg border border-base-300 bg-base-100 p-3"
            >
              <div class="mb-2 flex items-center justify-between gap-2">
                <p class="text-sm font-semibold text-base-content">#{channel.name}</p>
                <span class="rounded bg-base-300 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em] text-base-content/50">
                  {channel_kind_badge(channel.kind)}
                </span>
              </div>

              <.form
                for={to_form(%{}, as: :channel_notification)}
                id={"channel-notification-form-#{channel.slug}"}
                phx-submit="save_channel_notification"
                class="grid gap-3 md:grid-cols-3"
              >
                <input type="hidden" name="channel_notification[channel_id]" value={channel.id} />

                <.input
                  field={to_form(%{}, as: :channel_notification)[:notification_level]}
                  name="channel_notification[notification_level]"
                  type="select"
                  label="Level"
                  options={[
                    {"Default", "default"},
                    {"All messages", "all_messages"},
                    {"Mentions", "mentions"},
                    {"Nothing", "nothing"}
                  ]}
                  value={notification_level_value(@channel_memberships[channel.id])}
                />

                <.input
                  field={to_form(%{}, as: :channel_notification)[:is_favorite]}
                  name="channel_notification[is_favorite]"
                  type="checkbox"
                  label="Favorite"
                  checked={
                    @channel_memberships[channel.id] && @channel_memberships[channel.id].is_favorite
                  }
                />

                <div class="flex items-end">
                  <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
                    Save
                  </.button>
                </div>
              </.form>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def theme_tab(assigns) do
    ~H"""
    <div id="settings-view-theme">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Theme
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Appearance preferences</h2>

      <div class="mt-5 rounded-xl border border-base-300 bg-base-200 p-4">
        <p class="text-sm text-base-content/80">Choose your app theme:</p>
        <div class="mt-3">
          <Layouts.theme_toggle />
        </div>
      </div>
    </div>
    """
  end
end
