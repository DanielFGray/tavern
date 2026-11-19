defmodule TavernWeb.SettingsComponents.Managers do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.SettingsComponents.Helpers

  def emoji_manager(assigns) do
    ~H"""
    <div
      :if={@can_manage_emojis?}
      id="emoji-manager-overlay"
      class={[
        "fixed inset-0 z-40 bg-black/70 transition",
        @manage_emojis_open? && "opacity-100 pointer-events-auto",
        !@manage_emojis_open? && "pointer-events-none opacity-0"
      ]}
      phx-click="close_manage_emojis"
    />

    <aside
      :if={@can_manage_emojis?}
      id="emoji-manager-panel"
      aria-hidden={if(@manage_emojis_open?, do: "false", else: "true")}
      class={[
        "fixed inset-y-0 right-0 z-50 flex w-full max-w-lg flex-col border-l border-base-300 bg-base-100 transition-transform duration-200 ease-out",
        if(@manage_emojis_open?,
          do: "shadow-2xl lg:shadow-[-16px_0_48px_rgba(0,0,0,0.45)]",
          else: "shadow-none"
        ),
        @manage_emojis_open? && "pointer-events-auto",
        !@manage_emojis_open? && "pointer-events-none",
        @manage_emojis_open? && "translate-x-0",
        !@manage_emojis_open? && "translate-x-full"
      ]}
    >
      <div class="flex items-center justify-between border-b border-base-300 px-5 py-4">
        <div>
          <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-base-content/50">
            Server assets
          </p>
          <h2 class="mt-1 text-lg font-semibold text-base-content">Custom emoji</h2>
        </div>

        <button
          type="button"
          phx-click="close_manage_emojis"
          id="close-emoji-manager"
          class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          Close
        </button>
      </div>

      <div class="grid min-h-0 flex-1 gap-0 lg:grid-cols-[1.05fr_0.95fr]">
        <div class={[
          "min-h-0 overflow-y-auto border-b border-base-300 px-4 py-4 lg:border-b-0 lg:border-r",
          scrollbar_classes()
        ]}>
          <div class="flex items-center justify-between gap-3">
            <div>
              <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
                Library
              </p>
              <p class="mt-1 text-xs text-base-content/70">
                Upload small reaction-ready emoji assets.
              </p>
            </div>
            <span class="rounded bg-base-300 px-2 py-1 text-[10px] font-semibold text-base-content/70">
              {length(@custom_emojis)} total
            </span>
          </div>

          <div class="mt-4 grid gap-3 sm:grid-cols-2">
            <div
              :for={emoji <- @custom_emojis}
              id={"manage-emoji-#{emoji.id}"}
              class="rounded-xl border border-base-300 bg-base-200 p-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="flex min-w-0 items-center gap-3">
                  <img
                    src={emoji.url}
                    alt={emoji.name}
                    class="size-10 rounded-lg bg-base-300 object-cover"
                  />
                  <div class="min-w-0">
                    <p class="truncate text-sm font-semibold text-base-content">{emoji.name}</p>
                    <p class="truncate text-[11px] text-base-content/70">{emoji.shortcode}</p>
                  </div>
                </div>

                <button
                  type="button"
                  phx-click="delete_emoji"
                  phx-value-id={emoji.id}
                  id={"delete-emoji-#{emoji.id}"}
                  class="rounded px-2 py-1 text-[11px] font-semibold text-rose-300 transition hover:bg-rose-500/10 hover:text-rose-100"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        </div>

        <div class={["min-h-0 overflow-y-auto px-4 py-4", scrollbar_classes()]}>
          <div class="rounded-xl border border-base-300 bg-base-200 p-4">
            <div>
              <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
                Upload
              </p>
              <h3 class="mt-1 text-base font-semibold text-base-content">Add custom emoji</h3>
            </div>

            <.form
              for={@emoji_form}
              id="emoji-form"
              phx-change="change_emoji"
              phx-submit="save_emoji"
              class="mt-4 space-y-4"
            >
              <.input field={@emoji_form[:name]} type="text" label="Name" />
              <.input field={@emoji_form[:shortcode]} type="text" label="Shortcode" />

              <div>
                <label class="mb-2 block text-sm font-medium text-base-content/85">Image</label>
                <div class="rounded-xl border border-dashed border-base-300 bg-base-100 p-4">
                  <.live_file_input
                    upload={@uploads.emoji_image}
                    class="block w-full text-sm text-base-content/85"
                  />
                  <p class="mt-2 text-[11px] text-base-content/50">
                    png, jpg, gif, or webp. keep it tiny.
                  </p>
                </div>
                <p
                  :for={err <- upload_errors(@uploads.emoji_image)}
                  class="mt-2 text-[11px] text-rose-300"
                >
                  {emoji_upload_error(err)}
                </p>
              </div>

              <div class="flex items-center justify-end gap-2 pt-2">
                <button
                  type="button"
                  phx-click="close_manage_emojis"
                  class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
                >
                  Close
                </button>
                <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-violet-400">
                  Save emoji
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </aside>
    """
  end
end
