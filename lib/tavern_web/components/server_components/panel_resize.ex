defmodule TavernWeb.ServerComponents.PanelResize do
  @moduledoc """
  The drag handle on the inner edge of a docked side panel (docs/design/panel-widths.md).

  A panel's width is the CSS variable `--panel-<name>-w` on `<html>`, outside the LiveView
  patch root, so a re-render never resets it. The panel's own classes hold its default (the
  variable's fallback) and its bounds (`min-width`, `max-width`); the hook reads the bounds
  from the computed style, so they live in one place. The root layout applies saved widths
  from localStorage before first paint.
  """

  use TavernWeb, :html

  attr :name, :string,
    required: true,
    doc: "the panel's key: `--panel-<name>-w` and its storage key"

  attr :panel, :string, required: true, doc: "the DOM id of the panel the handle resizes"
  attr :edge, :string, values: ~w(left right), required: true, doc: "the panel edge it sits on"
  attr :label, :string, required: true
  attr :class, :any, default: nil, doc: "breakpoint classes: show it only where the panel docks"

  def resize_handle(assigns) do
    ~H"""
    <div
      id={"#{@panel}-resize"}
      phx-hook=".PanelResize"
      phx-update="ignore"
      data-panel-name={@name}
      data-edge={@edge}
      role="separator"
      aria-orientation="vertical"
      aria-controls={@panel}
      aria-label={@label}
      tabindex="0"
      title="Drag to resize. Double-click to reset."
      class={[
        "group absolute inset-y-0 z-10 w-2 cursor-col-resize touch-none select-none outline-none",
        if(@edge == "right", do: "-right-1", else: "-left-1"),
        @class
      ]}
    >
      <span class="pointer-events-none absolute inset-y-0 left-1/2 w-0.5 -translate-x-1/2 bg-primary/70 opacity-0 transition-opacity duration-150 group-hover:opacity-100 group-focus-visible:opacity-100 group-data-[dragging]:opacity-100" />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PanelResize">
      const STEP = 16
      const storageKey = (name) => `tavern:panel-width:${name}`

      export default {
        mounted() {
          this.panel = document.getElementById(this.el.getAttribute("aria-controls"))
          this.variable = `--panel-${this.el.dataset.panelName}-w`
          this.storageKey = storageKey(this.el.dataset.panelName)
          // A handle on the panel's right edge grows the panel as it moves right.
          this.direction = this.el.dataset.edge === "right" ? 1 : -1

          this.el.addEventListener("pointerdown", (e) => this.startDrag(e))
          this.el.addEventListener("dblclick", () => this.reset())
          this.el.addEventListener("keydown", (e) => this.onKey(e))
          this.el.addEventListener("focus", () => this.describe())
          this.describe()
        },

        startDrag(e) {
          if (e.button !== 0) return
          e.preventDefault()
          const startX = e.clientX
          const startWidth = this.panel.getBoundingClientRect().width
          this.el.setPointerCapture(e.pointerId)
          this.el.dataset.dragging = ""
          document.body.style.cursor = "col-resize"
          document.body.style.userSelect = "none"

          const move = (ev) => this.apply(startWidth + this.direction * (ev.clientX - startX))
          const end = () => {
            this.el.removeEventListener("pointermove", move)
            this.el.removeEventListener("pointerup", end)
            this.el.removeEventListener("pointercancel", end)
            delete this.el.dataset.dragging
            document.body.style.cursor = ""
            document.body.style.userSelect = ""
            this.save()
          }
          this.el.addEventListener("pointermove", move)
          this.el.addEventListener("pointerup", end)
          this.el.addEventListener("pointercancel", end)
        },

        // Arrow keys move the separator, as the WAI-ARIA window splitter pattern says.
        onKey(e) {
          const width = this.panel.getBoundingClientRect().width
          const {min, max} = this.bounds()
          const moves = {
            ArrowRight: width + this.direction * STEP,
            ArrowLeft: width - this.direction * STEP,
            Home: min,
            End: max,
          }
          if (!(e.key in moves)) return
          e.preventDefault()
          this.apply(moves[e.key])
          this.save()
        },

        // The panel's computed min-width and max-width are its bounds; a max-width that
        // depends on the viewport resolves to pixels here.
        bounds() {
          const style = getComputedStyle(this.panel)
          const min = parseFloat(style.minWidth) || 0
          const max = parseFloat(style.maxWidth)
          return {min, max: Number.isFinite(max) ? max : Infinity}
        },

        apply(width) {
          const {min, max} = this.bounds()
          const clamped = Math.round(Math.min(max, Math.max(min, width)))
          document.documentElement.style.setProperty(this.variable, `${clamped}px`)
          this.describe()
        },

        save() {
          const value = document.documentElement.style.getPropertyValue(this.variable)
          try {
            if (value) localStorage.setItem(this.storageKey, parseFloat(value))
          } catch (_) {}
        },

        reset() {
          document.documentElement.style.removeProperty(this.variable)
          try {
            localStorage.removeItem(this.storageKey)
          } catch (_) {}
          this.describe()
        },

        // aria-value* is written through LiveView's JS commands, which keep it across patches.
        describe() {
          const {min, max} = this.bounds()
          const width = Math.round(this.panel.getBoundingClientRect().width)
          const js = this.js()
          js.setAttribute(this.el, "aria-valuenow", String(width))
          js.setAttribute(this.el, "aria-valuemin", String(Math.round(min)))
          if (Number.isFinite(max)) js.setAttribute(this.el, "aria-valuemax", String(Math.round(max)))
        },
      }
    </script>
    """
  end
end
