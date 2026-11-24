defmodule TavernWeb.ServerComponents.Search do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Drawer
  import TavernWeb.ServerComponents.Helpers

  attr :server, :map, required: true

  @doc """
  The message search drawer: a search field over the messages the member may read, newest first.
  Each row shows the author, the channel or thread, the time and the start of the text, and opens
  that conversation.
  """
  def message_search(assigns) do
    assigns = assign(assigns, :search, assigns.server.message_search)

    ~H"""
    <.drawer id="message-search" close="close_message_search" label="Close message search">
      <:title>Search messages</:title>

      <div class="border-b border-base-300 px-4 py-3 sm:px-5">
        <.form
          for={@search.form}
          id="message-search-form"
          phx-change="message_search"
          phx-submit="message_search"
        >
          <.input
            field={@search.form[:query]}
            type="search"
            placeholder="Words to find"
            autocomplete="off"
            phx-debounce="300"
            phx-mounted={JS.focus()}
          />
        </.form>
      </div>

      <div class={["flex-1 overflow-y-auto px-2 py-2 sm:px-3", scrollbar_classes()]}>
        <p
          :if={@search.results == []}
          id="message-search-empty"
          class="px-3 py-8 text-center text-sm text-base-content/55"
        >
          {if String.trim(@search.query) == "",
            do: "Type a word to search every channel you can read.",
            else: "No messages match."}
        </p>

        <ul id="message-search-results" class="space-y-1">
          <li :for={message <- @search.results} id={"message-search-row-#{message.id}"}>
            <button
              type="button"
              phx-click="open_search_result"
              phx-value-id={message.id}
              id={"message-search-open-#{message.id}"}
              class="flex w-full gap-3 rounded-lg px-3 py-2.5 text-left transition hover:bg-base-200"
            >
              <.avatar user={message.author} class="mt-0.5 size-8 text-[11px]" />
              <span class="min-w-0 flex-1">
                <span class="flex items-baseline gap-2 text-[11px] text-base-content/55">
                  <span class="truncate text-sm font-semibold text-base-content">
                    {message.author.display_name}
                  </span>
                  <span class="truncate">{conversation_label(message.channel)}</span>
                  <span class="ml-auto shrink-0">{message_timestamp(message.inserted_at)}</span>
                </span>
                <span class="mt-0.5 line-clamp-2 text-sm break-words text-base-content/80">
                  {message.body}
                </span>
              </span>
            </button>
          </li>
        </ul>

        <div :if={@search.next} class="px-3 py-3">
          <button
            type="button"
            id="message-search-more"
            phx-click="message_search_more"
            phx-disable-with="Loading..."
            class="w-full rounded-md border border-base-300 px-3 py-2 text-xs font-semibold text-base-content/75 transition hover:bg-base-200 hover:text-base-content"
          >
            Load more
          </button>
        </div>
      </div>
    </.drawer>
    """
  end
end
