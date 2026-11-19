defmodule TavernWeb.ServerComponents.Embeds do
  @moduledoc """
  The link embed cards under a message: a page card (site name, linked title, two lines of
  description, image) and a YouTube card that loads its player only when clicked. Every image
  comes from `/uploads`, so showing a card contacts no other site.
  """

  use TavernWeb, :html

  alias Tavern.Chat
  alias Tavern.Embeds.Links

  attr :message, :map, required: true
  attr :removable?, :boolean, default: false

  def message_embeds(assigns) do
    ~H"""
    <div
      :if={@message.embeds != []}
      id={"message-embeds-#{@message.id}"}
      class="mt-2 flex flex-col gap-2"
    >
      <.embed_card
        :for={embed <- @message.embeds}
        embed={embed}
        message={@message}
        removable?={@removable?}
      />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".YouTubePlayer">
      // The player is a youtube-nocookie iframe made on the first click, so nothing loads from
      // YouTube before the viewer asks for it. The server checked the id; it is checked again
      // here because it is put into a URL.
      export default {
        mounted() {
          this.el.addEventListener("click", event => {
            event.stopPropagation()
            const id = this.el.dataset.videoId || ""
            if (!/^[A-Za-z0-9_-]{11}$/.test(id) || this.el.querySelector("iframe")) return

            const frame = document.createElement("iframe")
            frame.src = `https://www.youtube-nocookie.com/embed/${id}?autoplay=1`
            frame.title = this.el.dataset.title || "YouTube video"
            frame.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen"
            frame.allowFullscreen = true
            frame.referrerPolicy = "strict-origin-when-cross-origin"
            frame.className = "absolute inset-0 size-full border-0"
            this.el.replaceChildren(frame)
          })
        }
      }
    </script>
    """
  end

  attr :embed, :map, required: true
  attr :message, :map, required: true
  attr :removable?, :boolean, required: true

  defp embed_card(assigns) do
    ~H"""
    <div
      id={"embed-#{@embed.id}"}
      data-kind={@embed.kind}
      class={[
        "group/embed relative grid w-full max-w-[28rem] gap-1 overflow-hidden rounded-md border-l-4",
        "bg-base-100 py-3 pl-3 pr-9 shadow-sm ring-1 ring-base-300/60 transition hover:ring-base-300",
        if(@embed.kind == :video, do: "border-red-500", else: "border-violet-500")
      ]}
    >
      <button
        :if={@removable?}
        type="button"
        id={"remove-embed-#{@embed.id}"}
        phx-click="suppress_embeds"
        phx-value-id={@message.id}
        aria-label="Remove embeds"
        title="Remove embeds"
        class="absolute right-1.5 top-1.5 rounded-md p-1 text-base-content/40 transition hover:bg-base-200 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary sm:opacity-0 sm:group-hover/embed:opacity-100 sm:focus-visible:opacity-100"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>

      <p
        :if={@embed.site_name}
        class="truncate text-[11px] font-semibold uppercase tracking-wide text-base-content/55"
      >
        {@embed.site_name}
      </p>

      <a
        :if={@embed.title}
        href={@embed.url}
        target="_blank"
        rel="noopener noreferrer nofollow ugc"
        id={"embed-title-#{@embed.id}"}
        class="line-clamp-2 break-words text-[15px] font-semibold leading-5 text-sky-500 hover:underline"
      >
        {@embed.title}
      </a>

      <p
        :if={@embed.description}
        class="line-clamp-2 break-words text-[13px] leading-5 text-base-content/75"
      >
        {@embed.description}
      </p>

      <%= if @embed.kind == :video and Links.valid_video_id?(@embed.video_id) do %>
        <div
          id={"embed-player-#{@embed.id}"}
          phx-hook=".YouTubePlayer"
          phx-update="ignore"
          data-video-id={@embed.video_id}
          data-title={@embed.title}
          class="relative mt-2 aspect-video w-full overflow-hidden rounded bg-black"
        >
          <button
            type="button"
            id={"embed-play-#{@embed.id}"}
            aria-label={"Play #{@embed.title}"}
            class="group/play absolute inset-0 size-full cursor-pointer"
          >
            <img
              :if={@embed.image_asset}
              src={Chat.asset_url(@embed.image_asset)}
              alt=""
              loading="lazy"
              class="size-full object-cover opacity-90 transition group-hover/play:opacity-100"
            />
            <span class="absolute inset-0 flex items-center justify-center">
              <span class="flex size-14 items-center justify-center rounded-full bg-black/70 text-white shadow-lg transition group-hover/play:scale-110 group-hover/play:bg-red-600">
                <.icon name="hero-play-solid" class="size-7 translate-x-0.5" />
              </span>
            </span>
          </button>
        </div>
      <% else %>
        <img
          :if={@embed.image_asset}
          src={Chat.asset_url(@embed.image_asset)}
          alt=""
          loading="lazy"
          id={"embed-image-#{@embed.id}"}
          class="mt-2 max-h-72 w-full rounded object-cover"
        />
      <% end %>
    </div>
    """
  end
end
