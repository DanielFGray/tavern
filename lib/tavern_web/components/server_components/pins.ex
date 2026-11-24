defmodule TavernWeb.ServerComponents.Pins do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Drawer
  import TavernWeb.ServerComponents.Helpers

  attr :server, :map, required: true

  @doc """
  The pins drawer: the pinned messages of the open channel or thread, most recently pinned first.
  A member who may pin there sees an Unpin button on each.
  """
  def pins_drawer(assigns) do
    pins = assigns.server.pins

    assigns =
      assign(assigns,
        pins: pins,
        unpin?: message_rights(assigns.server, %{channel_id: pins.channel.id}).pin?
      )

    ~H"""
    <.drawer id="pins" close="close_pins" label="Close pinned messages">
      <:eyebrow>Pinned messages</:eyebrow>
      <:title>{conversation_label(@pins.channel)}</:title>

      <div class={["flex-1 overflow-y-auto px-2 py-2 sm:px-3", scrollbar_classes()]}>
        <p
          :if={@pins.messages == []}
          id="pins-empty"
          class="px-3 py-8 text-center text-sm text-base-content/55"
        >
          Nothing is pinned here yet.
        </p>

        <ul id="pins-list" class="space-y-1">
          <li
            :for={message <- @pins.messages}
            id={"pins-row-#{message.id}"}
            class="group flex gap-3 rounded-lg px-3 py-2.5 transition hover:bg-base-200"
          >
            <.avatar user={message.author} class="mt-0.5 size-8 text-[11px]" />
            <div class="min-w-0 flex-1">
              <p class="flex items-baseline gap-2 text-[11px] text-base-content/55">
                <span class="truncate text-sm font-semibold text-base-content">
                  {message.author.display_name}
                </span>
                <span class="ml-auto shrink-0">{message_timestamp(message.inserted_at)}</span>
              </p>
              <p class="mt-0.5 line-clamp-3 text-sm break-words text-base-content/80">
                {body_preview(message.body)}
              </p>
            </div>
            <button
              :if={@unpin?}
              type="button"
              phx-click="unpin_message"
              phx-value-id={message.id}
              id={"pins-unpin-#{message.id}"}
              aria-label="Unpin message"
              title="Unpin"
              class="self-start rounded-md p-1 text-base-content/45 opacity-0 transition group-hover:opacity-100 focus:opacity-100 hover:bg-base-300 hover:text-base-content max-sm:opacity-100"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </li>
        </ul>
      </div>
    </.drawer>
    """
  end
end
