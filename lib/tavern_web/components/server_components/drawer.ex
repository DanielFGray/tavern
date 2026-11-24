defmodule TavernWeb.ServerComponents.Drawer do
  @moduledoc false

  use TavernWeb, :html

  attr :id, :string,
    required: true,
    doc: "the drawer's DOM id; the backdrop, title and close button derive theirs"

  attr :close, :string,
    required: true,
    doc: "the event a backdrop click, Escape or the close button sends"

  attr :label, :string, required: true, doc: "the close button's accessible name"
  attr :class, :any, default: "max-w-lg"
  slot :title, required: true
  slot :eyebrow
  slot :inner_block, required: true

  @doc """
  A modal drawer on the right of the page, over a backdrop. A click on the backdrop, Escape and
  the close button all send `close`. The title slot is the dialog's accessible name.
  """
  def drawer(assigns) do
    ~H"""
    <div id={"#{@id}-backdrop"} class="fixed inset-0 z-40 bg-black/60 transition" phx-click={@close} />
    <aside
      id={@id}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@close}
      phx-key="Escape"
      class={[
        "fixed inset-y-0 right-0 z-50 flex w-full flex-col border-l border-base-300 bg-base-100 shadow-2xl",
        @class
      ]}
    >
      <header class="flex items-start justify-between gap-3 border-b border-base-300 px-4 py-4 sm:px-5">
        <div class="min-w-0">
          <p
            :if={@eyebrow != []}
            class="mb-1 text-[10px] font-bold uppercase tracking-[0.18em] text-base-content/45"
          >
            {render_slot(@eyebrow)}
          </p>
          <h2 id={"#{@id}-title"} class="truncate text-base font-semibold text-base-content">
            {render_slot(@title)}
          </h2>
        </div>
        <button
          type="button"
          id={"close-#{@id}"}
          phx-click={@close}
          aria-label={@label}
          class="rounded-md p-1.5 text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </header>

      {render_slot(@inner_block)}
    </aside>
    """
  end
end
