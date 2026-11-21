defmodule TavernWeb.SettingsComponents.Emoji do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.SettingsComponents.Helpers

  alias TavernWeb.SettingsComponents.Server

  @doc "The Emoji tab: the custom emoji library and the form that adds one."
  def emoji_tab(assigns) do
    ~H"""
    <div id="settings-view-emoji">
      <Server.tab_heading eyebrow="Server" title="Custom emoji" />

      <div class="mt-5 grid gap-5 lg:grid-cols-[1.05fr_0.95fr]">
        <div id="emoji-library" class="rounded-xl border border-base-300 bg-base-200 p-4">
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
              class="rounded-xl border border-base-300 bg-base-100 p-3"
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

        <div class="h-fit rounded-xl border border-base-300 bg-base-200 p-4">
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
              <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-violet-400">
                Save emoji
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
