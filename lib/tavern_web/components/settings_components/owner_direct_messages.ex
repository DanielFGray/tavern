defmodule TavernWeb.SettingsComponents.OwnerDirectMessages do
  @moduledoc false

  use TavernWeb, :html

  alias TavernWeb.ServerComponents.MessageAttachments

  def direct_messages_tab(assigns) do
    ~H"""
    <div id="settings-view-direct-messages">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Direct messages
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Read members' conversations</h2>

      <div
        id="owner-reader-notice"
        class="mt-5 flex items-start gap-3 rounded-xl border border-amber-400/40 bg-amber-400/10 p-4"
      >
        <.icon name="hero-eye" class="mt-0.5 size-5 shrink-0 text-amber-600" />
        <p class="text-sm text-base-content/80">
          This server lets its owner read direct messages, and members are told so. Each page you
          open writes an entry to the audit log that names both members.
        </p>
      </div>

      <%= if @owner_transcript do %>
        <.transcript transcript={@owner_transcript} />
      <% else %>
        <p
          :if={@owner_direct_messages == []}
          id="owner-direct-messages-empty"
          class="mt-4 rounded-xl border border-dashed border-base-300 px-4 py-5 text-sm text-base-content/55"
        >
          No direct messages yet.
        </p>

        <ul :if={@owner_direct_messages != []} id="owner-direct-messages" class="mt-4 space-y-2">
          <li
            :for={row <- @owner_direct_messages}
            id={"owner-dm-#{row.dm.id}"}
            class="flex items-center gap-3 rounded-xl border border-base-300 bg-base-200 px-3 py-2.5"
          >
            <div class="flex -space-x-2">
              <.avatar
                :for={user <- row.participants}
                user={user}
                class="size-8 text-xs ring-2 ring-base-200"
              />
            </div>
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium text-base-content">
                {Enum.map_join(row.participants, " and ", & &1.display_name)}
              </p>
              <p class="truncate text-xs text-base-content/55">
                Last activity {Calendar.strftime(row.last_activity_at, "%b %d, %Y %H:%M")}
              </p>
            </div>
            <button
              type="button"
              id={"owner-read-dm-#{row.dm.id}"}
              phx-click="read_direct_message"
              phx-value-id={row.dm.id}
              class="rounded-md px-2.5 py-1 text-xs font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
            >
              Read
            </button>
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  attr :transcript, :map, required: true

  # Read-only and plain text. Attachments show their name and size only: the attachment route
  # serves a viewer the DM is visible to, and the owner's read is not visibility.
  defp transcript(assigns) do
    ~H"""
    <div id="owner-transcript" class="mt-4 rounded-xl border border-base-300 bg-base-200">
      <div class="flex items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
        <p class="truncate text-sm font-semibold text-base-content">
          {Enum.map_join(@transcript.participants, " and ", & &1.display_name)}
        </p>
        <button
          type="button"
          id="owner-transcript-close"
          phx-click="close_direct_message"
          class="rounded-md px-2.5 py-1 text-xs font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
        >
          Back to list
        </button>
      </div>

      <div class="space-y-3 px-4 py-3">
        <button
          :if={@transcript.next_cursor}
          type="button"
          id="owner-transcript-older"
          phx-click="load_older_direct_messages"
          class="w-full rounded-md py-1.5 text-xs font-semibold text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
        >
          Load older messages
        </button>

        <p
          :if={@transcript.messages == []}
          id="owner-transcript-empty"
          class="py-4 text-center text-sm text-base-content/55"
        >
          No messages.
        </p>

        <article
          :for={message <- @transcript.messages}
          id={"owner-transcript-message-#{message.id}"}
          class="flex gap-3"
        >
          <.avatar user={message.author} class="size-8 shrink-0 text-xs" />
          <div class="min-w-0">
            <p class="text-xs text-base-content/55">
              <span class="font-semibold text-base-content">{message.author.display_name}</span>
              {Calendar.strftime(message.inserted_at, "%b %d, %Y %H:%M")}
            </p>
            <%!-- The body sits on the tag's line: pre-wrap would keep template indentation. --%>
            <p class="whitespace-pre-wrap break-words text-sm text-base-content/90">{message.body}</p>
            <p
              :for={attachment <- message.attachments}
              class="mt-1 inline-flex items-center gap-1 text-xs text-base-content/60"
            >
              <.icon name="hero-paper-clip" class="size-3.5" />
              {attachment.asset.original_filename} ({MessageAttachments.format_bytes(
                attachment.asset.byte_size
              )})
            </p>
          </div>
        </article>
      </div>
    </div>
    """
  end
end
