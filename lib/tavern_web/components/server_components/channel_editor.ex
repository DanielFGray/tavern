defmodule TavernWeb.ServerComponents.ChannelEditor do
  @moduledoc """
  The sidebar's channel edit mode, the ⚙ settings popover and the channel header's topic
  (`TavernWeb.ServerLive.ChannelEditor` holds their state and events).

  Three colocated hooks: `.ChannelDrag` moves rows with pointer events (mouse and touch) and sends
  one `place_channel` per drop; `.InlineEdit` saves a name or topic on Enter or blur and reverts on
  Esc; `.AnchoredPopover` places the popover beside its row, or along the bottom on a phone.
  """

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  alias TavernWeb.ServerComponents.ChannelPermissions
  alias TavernWeb.ServerLive.ChannelEditor

  attr :server, :map, required: true

  def edit_toggle(assigns) do
    ~H"""
    <button
      :if={@server.can_manage_channels?}
      type="button"
      id="toggle-channel-edit"
      phx-click="toggle_channel_edit"
      aria-pressed={to_string(@server.channel_edit_mode?)}
      title={if(@server.channel_edit_mode?, do: "Done editing", else: "Edit channels")}
      class={[
        "inline-flex items-center gap-1 rounded-md px-1.5 py-1 text-[11px] font-semibold transition",
        if(@server.channel_edit_mode?,
          do: "bg-violet-500 text-white hover:bg-violet-400",
          else: "text-base-content/55 hover:bg-base-100 hover:text-base-content"
        )
      ]}
    >
      <%= if @server.channel_edit_mode? do %>
        Done
      <% else %>
        <.icon name="hero-pencil-square" class="size-4" />
        <span class="sr-only">Edit channels</span>
      <% end %>
    </button>
    """
  end

  attr :server, :map, required: true

  @doc """
  The channel list in edit mode: every category (empty ones too) and the top level, each a drop
  target, then "+ add category" and the recently deleted channels.
  """
  def edit_nav(assigns) do
    sections = assigns.server.channel_sections

    assigns =
      assign(assigns,
        category_sections: Enum.filter(sections, & &1.category),
        top_channels:
          Enum.find_value(sections, [], fn section ->
            is_nil(section.category) && section.channels
          end)
      )

    ~H"""
    <div
      id="channel-edit-list"
      phx-hook=".ChannelDrag"
      class="space-y-3"
      aria-label="Edit channels"
    >
      <div data-drop-list="categories" class="space-y-3">
        <section
          :for={section <- @category_sections}
          id={"edit-section-#{section.category.id}"}
          data-drag-item
          data-id={section.category.id}
          data-kind="category"
        >
          <.edit_row channel={section.category} server={@server} />
          <div
            data-drop-list="channels"
            data-parent-id={section.category.id}
            class="min-h-7 space-y-0.5 pl-3"
          >
            <.edit_row :for={channel <- section.channels} channel={channel} server={@server} />
          </div>
          <.add_channel parent={section.category.id} server={@server} />
        </section>
      </div>

      <section id="edit-section-top">
        <p class="px-2 pb-1 text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
          No category
        </p>
        <div data-drop-list="channels" data-parent-id="" class="min-h-7 space-y-0.5">
          <.edit_row :for={channel <- @top_channels} channel={channel} server={@server} />
        </div>
        <.add_channel parent="" server={@server} />
      </section>

      <%= if @server.new_category_form do %>
        <.form
          for={@server.new_category_form}
          id="new-category-form"
          phx-submit="create_category"
          class="space-y-2 rounded-lg bg-base-100 p-2"
        >
          <.input
            field={@server.new_category_form[:name]}
            type="text"
            placeholder="Category name"
            phx-mounted={JS.focus()}
            phx-keydown="cancel_add_category"
            phx-key="Escape"
          />
          <div class="flex justify-end gap-1">
            <button
              type="button"
              phx-click="cancel_add_category"
              class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
            >
              Cancel
            </button>
            <button
              type="submit"
              id="create-category"
              class="rounded-md bg-violet-500 px-2.5 py-1 text-[11px] font-semibold text-white transition hover:bg-violet-400 active:scale-[0.98]"
            >
              Add
            </button>
          </div>
        </.form>
      <% else %>
        <button
          type="button"
          id="add-category"
          phx-click="open_add_category"
          class="flex w-full items-center gap-1.5 rounded-md px-2 py-1.5 text-[12px] font-semibold text-base-content/55 transition hover:bg-base-100 hover:text-base-content"
        >
          <.icon name="hero-plus" class="size-3.5" /> add category
        </button>
      <% end %>

      <section
        :if={@server.deleted_channels != []}
        id="deleted-channels"
        class="border-t border-base-300 pt-3"
      >
        <p class="px-2 pb-1 text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
          Recently deleted
        </p>
        <div
          :for={channel <- @server.deleted_channels}
          id={"deleted-channel-#{channel.id}"}
          class="flex items-center gap-2 rounded-md px-2 py-1 text-sm text-base-content/50"
        >
          <span class="text-base-content/35">
            {if(channel.kind == :category, do: "▾", else: "#")}
          </span>
          <span class="min-w-0 flex-1 truncate line-through decoration-base-content/30">
            {channel.name}
          </span>
          <button
            type="button"
            id={"restore-channel-#{channel.id}"}
            phx-click="restore_channel"
            phx-value-id={channel.id}
            class="rounded-md px-2 py-0.5 text-[11px] font-semibold text-violet-500 transition hover:bg-violet-500/10 hover:text-violet-400"
          >
            Restore
          </button>
        </div>
      </section>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChannelDrag">
      // Drags a row by its handle. Pointer capture keeps the move events on the handle for mouse
      // and touch alike; `touch-none` on the handle stops the drawer scrolling under a finger. The
      // DOM is never reordered here: a drop sends one place_channel, and the server renders the
      // new order.
      export default {
        mounted() {
          this.onDown = (e) => this.start(e)
          this.el.addEventListener("pointerdown", this.onDown)
        },
        updated() {
          if (this.drag && !this.el.contains(this.drag.item)) this.stop()
        },
        destroyed() {
          this.el.removeEventListener("pointerdown", this.onDown)
          this.stop()
        },
        start(e) {
          const handle = e.target.closest("[data-drag-handle]")
          if (!handle || !this.el.contains(handle) || e.button > 0) return
          e.preventDefault()
          const item = handle.closest("[data-drag-item]")
          const marker = document.createElement("div")
          marker.className = "pointer-events-none fixed z-[60] h-0.5 rounded-full bg-violet-500"
          marker.hidden = true
          document.body.appendChild(marker)
          item.classList.add("opacity-40")
          handle.setPointerCapture(e.pointerId)
          this.drag = {handle, item, marker, target: null}
          this.onMove = (ev) => this.move(ev)
          this.onUp = () => this.drop()
          this.onCancel = () => this.stop()
          handle.addEventListener("pointermove", this.onMove)
          handle.addEventListener("pointerup", this.onUp)
          handle.addEventListener("pointercancel", this.onCancel)
        },
        move(e) {
          const {item, marker} = this.drag
          this.autoscroll(e.clientY)
          const kind = item.dataset.kind === "category" ? "categories" : "channels"
          const list = [...this.el.querySelectorAll(`[data-drop-list="${kind}"]`)].find((l) => {
            const r = l.getBoundingClientRect()
            return e.clientY >= r.top - 8 && e.clientY <= r.bottom + 8 &&
              e.clientX >= r.left - 48 && e.clientX <= r.right + 48
          })
          if (!list) {
            marker.hidden = true
            this.drag.target = null
            return
          }
          const rows = [...list.children].filter((c) => c.matches("[data-drag-item]") && c !== item)
          const before = rows.find((c) => {
            const r = c.getBoundingClientRect()
            return e.clientY < r.top + r.height / 2
          })
          const box = list.getBoundingClientRect()
          const y = before ? before.getBoundingClientRect().top - 1
            : rows.length ? rows[rows.length - 1].getBoundingClientRect().bottom + 1
            : box.top + box.height / 2
          Object.assign(marker.style, {left: `${box.left}px`, width: `${box.width}px`, top: `${y}px`})
          marker.hidden = false
          this.drag.target = {parent_id: list.dataset.parentId || "", before_id: before ? before.dataset.id : ""}
        },
        drop() {
          const {item, target} = this.drag
          if (target && !this.unchanged(item, target)) {
            this.pushEvent("place_channel", {id: item.dataset.id, ...target})
          }
          this.stop()
        },
        // A drop back where the row already is sends nothing.
        unchanged(item, target) {
          const list = item.parentElement
          if ((list.dataset.parentId || "") !== target.parent_id) return false
          let next = item.nextElementSibling
          while (next && !next.matches("[data-drag-item]")) next = next.nextElementSibling
          return (next ? next.dataset.id : "") === target.before_id
        },
        autoscroll(y) {
          const pane = this.el.closest(".overflow-y-auto")
          if (!pane) return
          const r = pane.getBoundingClientRect()
          if (y < r.top + 32) pane.scrollTop -= 8
          else if (y > r.bottom - 32) pane.scrollTop += 8
        },
        stop() {
          if (!this.drag) return
          const {handle, item, marker} = this.drag
          handle.removeEventListener("pointermove", this.onMove)
          handle.removeEventListener("pointerup", this.onUp)
          handle.removeEventListener("pointercancel", this.onCancel)
          item.classList.remove("opacity-40")
          marker.remove()
          this.drag = null
        }
      }
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".InlineEdit">
      // Enter or blur saves a changed value, Esc puts the stored value back. A refused save also
      // puts it back, since the server's render then has nothing new to patch in.
      export default {
        mounted() {
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Enter") {
              e.preventDefault()
              this.el.blur()
            } else if (e.key === "Escape") {
              e.preventDefault()
              this.el.value = this.el.dataset.original || ""
              this.el.blur()
            }
          })
          this.el.addEventListener("blur", () => {
            const original = this.el.dataset.original || ""
            if (this.el.value.trim() === original) return
            this.pushEvent(this.el.dataset.event, {id: this.el.dataset.id, value: this.el.value}, (reply) => {
              if (!reply.saved) this.el.value = this.el.dataset.original || ""
            })
          })
        }
      }
    </script>
    """
  end

  attr :channel, :map, required: true
  attr :server, :map, required: true

  defp edit_row(assigns) do
    assigns = assign(assigns, :category?, assigns.channel.kind == :category)

    ~H"""
    <div
      id={"edit-channel-#{@channel.id}"}
      data-drag-item={!@category?}
      data-id={@channel.id}
      data-kind={if(@category?, do: "category", else: "channel")}
      class={[
        "group flex items-center gap-1 rounded-md px-1 py-0.5 transition",
        @server.channel_settings_id == @channel.id && "bg-base-100 ring-1 ring-violet-400/50",
        @server.channel_settings_id != @channel.id && "hover:bg-base-100"
      ]}
    >
      <button
        type="button"
        id={"drag-channel-#{@channel.id}"}
        data-drag-handle
        aria-label={"Move #{@channel.name}"}
        class="flex size-6 shrink-0 cursor-grab touch-none items-center justify-center rounded text-base-content/35 transition hover:text-base-content/80 active:cursor-grabbing"
      >
        <.icon name="hero-bars-2" class="size-4" />
      </button>
      <span :if={!@category?} class="text-sm font-semibold text-base-content/40">#</span>
      <input
        type="text"
        id={"rename-channel-#{@channel.id}"}
        value={@channel.name}
        data-original={@channel.name}
        data-event="rename_channel"
        data-id={@channel.id}
        phx-hook=".InlineEdit"
        maxlength="40"
        aria-label={if(@category?, do: "Category name", else: "Channel name")}
        class={[
          "min-w-0 flex-1 rounded border border-transparent bg-transparent px-1 py-1 text-sm text-base-content outline-none transition",
          "hover:border-base-300 focus:border-violet-400 focus:bg-base-100",
          @category? && "text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/60"
        ]}
      />
      <button
        type="button"
        id={"channel-settings-#{@channel.id}"}
        phx-click="open_channel_settings"
        phx-value-id={@channel.id}
        aria-label={"Settings for #{@channel.name}"}
        class="flex size-7 shrink-0 items-center justify-center rounded text-base-content/45 transition hover:bg-base-300 hover:text-base-content"
      >
        <.icon name="hero-cog-6-tooth" class="size-4" />
      </button>
      <button
        type="button"
        id={"delete-channel-#{@channel.id}"}
        phx-click="delete_channel"
        phx-value-id={@channel.id}
        aria-label={"Delete #{@channel.name}"}
        class="flex size-7 shrink-0 items-center justify-center rounded text-base-content/45 transition hover:bg-rose-500/10 hover:text-rose-500"
      >
        <.icon name="hero-trash" class="size-4" />
      </button>
    </div>
    """
  end

  attr :parent, :string, required: true
  attr :server, :map, required: true

  # "+ add channel" under one section; it opens a name field and a kind picker in place.
  defp add_channel(assigns) do
    assigns = assign(assigns, :dom_key, if(assigns.parent == "", do: "top", else: assigns.parent))

    ~H"""
    <%= if @server.new_channel_parent == @parent do %>
      <.form
        for={@server.new_channel_form}
        id="new-channel-form"
        phx-submit="create_channel"
        class="mt-1 space-y-2 rounded-lg bg-base-100 p-2"
      >
        <.input
          field={@server.new_channel_form[:name]}
          type="text"
          placeholder="Channel name"
          phx-mounted={JS.focus()}
          phx-keydown="cancel_add_channel"
          phx-key="Escape"
        />
        <.input
          field={@server.new_channel_form[:kind]}
          type="select"
          options={ChannelEditor.new_channel_kinds()}
          aria-label="Channel kind"
        />
        <div class="flex justify-end gap-1">
          <button
            type="button"
            phx-click="cancel_add_channel"
            class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
          >
            Cancel
          </button>
          <button
            type="submit"
            id="create-channel"
            class="rounded-md bg-violet-500 px-2.5 py-1 text-[11px] font-semibold text-white transition hover:bg-violet-400 active:scale-[0.98]"
          >
            Add
          </button>
        </div>
      </.form>
    <% else %>
      <button
        type="button"
        id={"add-channel-#{@dom_key}"}
        phx-click="open_add_channel"
        phx-value-parent={@parent}
        class="mt-0.5 flex w-full items-center gap-1.5 rounded-md px-2 py-1 text-[12px] text-base-content/45 transition hover:bg-base-100 hover:text-base-content"
      >
        <.icon name="hero-plus" class="size-3.5" /> add channel
      </button>
    <% end %>
    """
  end

  attr :server, :map, required: true

  @doc "The ⚙ popover for one channel or category, beside its edit-mode row."
  def settings_popover(assigns) do
    channel =
      Enum.find_value(assigns.server.channel_sections, fn section ->
        if section.category && section.category.id == assigns.server.channel_settings_id,
          do: section.category,
          else: Enum.find(section.channels, &(&1.id == assigns.server.channel_settings_id))
      end)

    assigns = assign(assigns, channel: channel, form: assigns.server.channel_settings_form)

    ~H"""
    <div
      :if={@channel && @form}
      id="channel-settings-popover"
      phx-hook=".AnchoredPopover"
      data-anchor={"edit-channel-#{@channel.id}"}
      phx-click-away="close_channel_settings"
      phx-window-keydown="close_channel_settings"
      phx-key="Escape"
      role="dialog"
      aria-labelledby="channel-settings-title"
      class={[
        "fixed z-50 max-h-[80dvh] w-auto overflow-y-auto rounded-xl border border-base-300 bg-base-100 p-4 shadow-2xl sm:w-[22rem]",
        scrollbar_classes()
      ]}
    >
      <div class="flex items-center justify-between gap-2">
        <h2 id="channel-settings-title" class="truncate text-sm font-semibold text-base-content">
          {if(@channel.kind == :category, do: @channel.name, else: "##{@channel.name}")}
        </h2>
        <button
          type="button"
          id="close-channel-settings"
          phx-click="close_channel_settings"
          aria-label="Close"
          class="rounded-md p-1 text-base-content/55 transition hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <.form
        for={@form}
        id="channel-settings-form"
        phx-submit="save_channel_settings"
        class="mt-3 space-y-3"
      >
        <.input field={@form[:name]} type="text" label="Name" />
        <%= if @channel.kind != :category do %>
          <.input field={@form[:topic]} type="textarea" label="Topic" />
          <.input field={@form[:nsfw]} type="checkbox" label="Age-gated (18+)" />
        <% end %>
        <div class="flex items-center justify-between gap-2">
          <button
            type="button"
            id="channel-settings-delete"
            phx-click="delete_channel"
            phx-value-id={@channel.id}
            class="rounded-md px-2 py-1 text-[11px] font-semibold text-rose-500 transition hover:bg-rose-500/10"
          >
            Delete
          </button>
          <button
            type="submit"
            id="channel-settings-save"
            phx-disable-with="Saving…"
            class="rounded-md bg-violet-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-violet-400 active:scale-[0.98]"
          >
            Save
          </button>
        </div>
      </.form>

      <ChannelPermissions.section
        :if={@server.channel_permissions}
        permissions={@server.channel_permissions}
        open_key={@server.open_overwrite_key}
        roles={@server.roles}
        members={@server.member_presence}
        role_form={@server.overwrite_role_form}
        member_form={@server.overwrite_member_form}
      />
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".AnchoredPopover">
      // Beside the anchor row from the sm breakpoint up (640px, as in the class list); a bottom
      // sheet below it. Re-placed after every patch, which resets the inline style.
      export default {
        mounted() {
          this.onResize = () => this.place()
          window.addEventListener("resize", this.onResize)
          this.place()
        },
        updated() { this.place() },
        destroyed() { window.removeEventListener("resize", this.onResize) },
        place() {
          const el = this.el
          const anchor = document.getElementById(el.dataset.anchor)
          if (window.innerWidth < 640 || !anchor) {
            Object.assign(el.style, {left: "1rem", right: "1rem", top: "auto", bottom: "1rem"})
            return
          }
          const r = anchor.getBoundingClientRect()
          const top = Math.max(8, Math.min(r.top, window.innerHeight - el.offsetHeight - 8))
          Object.assign(el.style, {left: `${r.right + 8}px`, right: "auto", top: `${top}px`, bottom: "auto"})
        }
      }
    </script>
    """
  end

  attr :server, :map, required: true

  @doc "The channel header's topic: an inline field for a member with `manage_channels`."
  def channel_topic(assigns) do
    ~H"""
    <%= if @server.can_manage_channels? do %>
      <input
        type="text"
        id="channel-topic-input"
        value={@server.active_channel.topic}
        data-original={@server.active_channel.topic || ""}
        data-event="save_topic"
        data-id={@server.active_channel.id}
        phx-hook=".InlineEdit"
        maxlength="160"
        placeholder="Add a topic"
        aria-label="Channel topic"
        class="mt-0.5 w-full min-w-0 truncate rounded border border-transparent bg-transparent px-1 -mx-1 text-xs text-base-content/65 outline-none transition placeholder:text-base-content/40 hover:border-base-300 focus:border-violet-400 focus:bg-base-100 focus:text-base-content"
      />
    <% else %>
      <p id="channel-topic" class="mt-0.5 truncate text-xs text-base-content/65">
        {@server.active_channel.topic || "No topic set for this channel yet."}
      </p>
    <% end %>
    """
  end
end
