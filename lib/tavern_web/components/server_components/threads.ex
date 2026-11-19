defmodule TavernWeb.ServerComponents.Threads do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  attr :server, :map, required: true
  attr :message, :map, required: true
  attr :thread, :map, required: true

  def thread_panel(assigns) do
    ~H"""
    <div
      id={"thread-panel-#{@message.id}"}
      class={[
        "mt-4 overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm",
        @server.thread_focus? && "ring-1 ring-primary/25"
      ]}
    >
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-200/80 px-4 py-3">
        <div class="min-w-0">
          <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-base-content/45">
            Thread
          </p>
          <div class="mt-1 flex items-center gap-2">
            <h3 class="truncate text-sm font-semibold text-base-content">
              {thread_title(@thread)}
            </h3>
            <span
              id={"thread-reply-count-#{@message.id}"}
              class="rounded-full bg-base-300 px-2 py-0.5 text-[10px] font-bold uppercase tracking-[0.14em] text-base-content/60"
            >
              {@server.thread_message_count} {if @server.thread_message_count == 1,
                do: "reply",
                else: "replies"}
            </span>
          </div>
          <p class="mt-1 truncate text-xs text-base-content/55">
            Started by {@message.author.display_name}
          </p>
        </div>

        <div class="flex items-center gap-2">
          <span
            :if={@thread.locked_at}
            id={"thread-locked-badge-#{@message.id}"}
            class="rounded-full bg-warning/20 px-2 py-0.5 text-[10px] font-bold uppercase tracking-[0.14em] text-warning-content"
          >
            Locked
          </span>
          <span
            :if={@thread.archived_at}
            id={"thread-archived-badge-#{@message.id}"}
            class="rounded-full bg-base-300 px-2 py-0.5 text-[10px] font-bold uppercase tracking-[0.14em] text-base-content/60"
          >
            Archived
          </span>
          <button
            type="button"
            phx-click={if @server.thread_following?, do: "unfollow_thread", else: "follow_thread"}
            phx-value-id={@thread.id}
            id={"toggle-follow-thread-#{@message.id}"}
            aria-pressed={to_string(@server.thread_following?)}
            class={[
              "inline-flex items-center gap-1 rounded-md px-2.5 py-1.5 text-[11px] font-semibold transition",
              @server.thread_following? &&
                "bg-primary/10 text-primary hover:bg-primary/15",
              !@server.thread_following? &&
                "text-base-content/75 hover:bg-base-100 hover:text-base-content"
            ]}
          >
            <.icon
              name={if @server.thread_following?, do: "hero-bell-alert", else: "hero-bell"}
              class="size-3.5"
            />
            {if @server.thread_following?, do: "Following", else: "Follow"}
          </button>
          <button
            :if={@server.can_archive_thread?}
            type="button"
            phx-click={if @thread.archived_at, do: "unarchive_thread", else: "archive_thread"}
            id={"toggle-archive-thread-#{@message.id}"}
            class="rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-base-content/75 transition hover:bg-base-100 hover:text-base-content"
          >
            {if @thread.archived_at, do: "Unarchive", else: "Archive"}
          </button>
          <button
            :if={@server.can_lock_thread?}
            type="button"
            phx-click={if @thread.locked_at, do: "unlock_thread", else: "lock_thread"}
            id={"toggle-lock-thread-#{@message.id}"}
            class="rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-base-content/75 transition hover:bg-base-100 hover:text-base-content"
          >
            {if @thread.locked_at, do: "Unlock", else: "Lock"}
          </button>
          <.link
            patch={thread_path(@server.active_channel, @thread)}
            id={"thread-view-focus-#{@message.id}"}
            class="rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-base-content/75 transition hover:bg-base-100 hover:text-base-content"
          >
            {if @server.thread_focus?, do: "Focused", else: "Focus"}
          </.link>
          <.link
            :if={@server.thread_focus?}
            patch={channel_path(@server.active_channel)}
            id={"thread-back-to-channel-#{@message.id}"}
            class="rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-base-content/75 transition hover:bg-base-100 hover:text-base-content"
          >
            Back to channel
          </.link>
          <button
            type="button"
            phx-click="close_thread"
            id={"close-thread-#{@message.id}"}
            class="rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-base-content/75 transition hover:bg-base-100 hover:text-base-content"
          >
            Close
          </button>
        </div>
      </div>

      <div
        id={"thread-scroll-region-#{@message.id}"}
        data-enable-notifications="false"
        class={["max-h-[28rem] overflow-y-auto px-4 py-3", scrollbar_classes()]}
        phx-hook="MessageListHook"
      >
        <div
          :if={@server.thread_messages_empty?}
          class="rounded-xl border border-dashed border-base-300 bg-base-200/60 px-4 py-5 text-sm text-base-content/65"
        >
          No thread replies yet. Kick this conversation off.
        </div>

        <div id={"thread-message-list-#{@message.id}"} phx-update="stream" class="space-y-3">
          <.thread_message_item
            :for={{thread_dom_id, thread_message} <- @server.streams.thread_messages}
            dom_id={thread_dom_id}
            thread_message={thread_message}
            server={@server}
          />
        </div>
      </div>

      <div class="border-t border-base-300 bg-base-100 px-4 py-4">
        <%= if @server.can_send_thread_messages? do %>
          <TavernWeb.ServerComponents.Messages.typing_indicator
            users={@server.thread_typing_users}
            id={"thread-typing-indicator-#{@message.id}"}
          />
          <TavernWeb.ServerComponents.Composer.thread_composer server={@server} />
        <% else %>
          <div class="rounded-xl border border-warning/30 bg-warning/15 px-4 py-3 text-sm text-warning-content">
            {if @thread.locked_at,
              do: "This thread is locked.",
              else: "You can view this thread, but you do not have permission to reply in it."}
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :dom_id, :any, required: true
  attr :thread_message, :map, required: true
  attr :server, :map, required: true

  def thread_message_item(assigns) do
    ~H"""
    <div id={@dom_id} class="rounded-xl border border-base-300 bg-base-200/60 px-3 py-3">
      <div class="flex gap-3">
        <div class="flex size-8 shrink-0 items-center justify-center rounded-full bg-base-300 text-[11px] font-semibold text-base-content">
          {@thread_message.author.display_name |> String.first()}
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <p class="text-[13px] font-semibold text-base-content">
              {@thread_message.author.display_name}
            </p>
            <span class="text-[11px] text-base-content/45">@{@thread_message.author.username}</span>
            <time class="text-[11px] text-base-content/45">
              {message_timestamp(@thread_message.inserted_at)}
            </time>
          </div>

          <div
            :if={@thread_message.reply_to}
            class="mt-1 flex items-center gap-2 border-l-2 border-base-300 pl-3 text-xs text-base-content/60"
          >
            <span class="truncate">
              Replying to
              <span class="font-semibold text-base-content/80">
                {@thread_message.reply_to.author.display_name}
              </span>
              · {@thread_message.reply_to.body}
            </span>
          </div>

          <div
            class={["message-body mt-2 text-sm", message_body_classes()]}
            data-markdown-source={@thread_message.body}
          >
            {@thread_message.body}
          </div>

          <TavernWeb.ServerComponents.Embeds.message_embeds
            message={@thread_message}
            removable?={embeds_removable?(@thread_message, @server)}
          />

          <.thread_reactions message={@thread_message} server={@server} />

          <div class="mt-2 flex items-center gap-2 text-[11px] text-base-content/50">
            <span :if={edited_message?(@thread_message)}>(edited)</span>
            <span :if={deleted_message?(@thread_message)} class="text-amber-300">deleted</span>

            <button
              type="button"
              phx-click="reply_in_thread"
              phx-value-id={@thread_message.id}
              id={"reply-in-thread-#{@thread_message.id}"}
              disabled={!@server.can_send_thread_messages? or deleted_message?(@thread_message)}
              class="rounded-md px-1.5 py-0.5 font-semibold text-base-content/65 transition hover:bg-base-100 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-50"
            >
              Reply
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :server, :map, required: true

  # A thread message's reactions, and the default reactions a member who may react can add. The
  # channel message's emoji picker is tied to the channel's stream, so a thread offers the defaults.
  defp thread_reactions(assigns) do
    assigns =
      assign(
        assigns,
        :can_react?,
        assigns.server.can_react_in_thread? and
          !deleted_message?(assigns.message)
      )

    assigns =
      assign(
        assigns,
        :quick,
        Enum.reject(
          Tavern.Chat.default_reaction_emojis(),
          fn emoji ->
            Enum.any?(assigns.message.reactions, &(&1.emoji_unicode == emoji))
          end
        )
      )

    ~H"""
    <div
      :if={@can_react? or @message.reactions != []}
      class="mt-2 flex flex-wrap items-center gap-1.5"
    >
      <button
        :for={reaction <- reaction_summaries(@message, @server.current_user)}
        type="button"
        phx-click={
          if(reaction.kind == :unicode, do: "toggle_reaction", else: "toggle_custom_reaction")
        }
        phx-value-id={@message.id}
        phx-value-emoji={reaction.emoji_unicode}
        phx-value-emoji_id={reaction.emoji_id}
        id={reaction_dom_id(@message, reaction)}
        disabled={!@can_react?}
        class={[
          "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-semibold transition disabled:cursor-not-allowed disabled:opacity-50",
          reaction.reacted? && "border-violet-400/60 bg-violet-500/20 text-violet-100",
          !reaction.reacted? &&
            "border-base-300 bg-base-100 text-base-content/70 hover:border-base-content/20 hover:text-base-content"
        ]}
      >
        <span :if={reaction.kind == :unicode}>{reaction.emoji_unicode}</span>
        <img
          :if={reaction.kind == :custom}
          src={reaction.url}
          alt={reaction.label}
          class="size-4 rounded object-cover"
        />
        <span>{reaction.count}</span>
      </button>
      <button
        :for={emoji <- @quick}
        :if={@can_react?}
        type="button"
        phx-click="toggle_reaction"
        phx-value-id={@message.id}
        phx-value-emoji={emoji}
        id={"add-#{reaction_dom_id(@message, %{kind: :unicode, emoji_unicode: emoji})}"}
        aria-label={"React with #{emoji}"}
        class="inline-flex items-center rounded-full border border-dashed border-base-300 px-2 py-0.5 text-[11px] opacity-60 transition hover:opacity-100"
      >
        {emoji}
      </button>
    </div>
    """
  end

  attr :server, :map, required: true

  @doc """
  The thread browser: a drawer over the page listing one channel's threads in Active and Archived
  tabs, newest activity first, with a title search and a button that loads the next page.
  """
  def thread_browser(assigns) do
    assigns = assign(assigns, :browser, assigns.server.thread_browser)

    ~H"""
    <div
      id="thread-browser-backdrop"
      class="fixed inset-0 z-40 bg-black/60 transition"
      phx-click="close_thread_browser"
    />
    <aside
      id="thread-browser"
      role="dialog"
      aria-modal="true"
      aria-labelledby="thread-browser-title"
      phx-window-keydown="close_thread_browser"
      phx-key="Escape"
      class="fixed inset-y-0 right-0 z-50 flex w-full max-w-lg flex-col border-l border-base-300 bg-base-100 shadow-2xl"
    >
      <header class="flex items-start justify-between gap-3 border-b border-base-300 px-4 py-4 sm:px-5">
        <div class="min-w-0">
          <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-base-content/45">
            Threads
          </p>
          <h2
            id="thread-browser-title"
            class="mt-1 truncate text-base font-semibold text-base-content"
          >
            # {@browser.channel.name}
          </h2>
        </div>
        <button
          type="button"
          id="close-thread-browser"
          phx-click="close_thread_browser"
          aria-label="Close thread browser"
          class="rounded-md p-1.5 text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </header>

      <div class="space-y-3 border-b border-base-300 px-4 py-3 sm:px-5">
        <div role="tablist" class="inline-flex rounded-lg bg-base-200 p-1">
          <button
            :for={tab <- [:active, :archived]}
            type="button"
            role="tab"
            id={"thread-browser-tab-#{tab}"}
            aria-selected={to_string(@browser.tab == tab)}
            phx-click="thread_browser_tab"
            phx-value-tab={tab}
            class={[
              "rounded-md px-3 py-1 text-xs font-semibold transition",
              @browser.tab == tab && "bg-base-100 text-base-content shadow-sm",
              @browser.tab != tab && "text-base-content/60 hover:text-base-content"
            ]}
          >
            {if tab == :active, do: "Active", else: "Archived"}
          </button>
        </div>

        <.form
          for={@browser.form}
          id="thread-browser-search"
          phx-change="thread_browser_search"
          phx-submit="thread_browser_search"
        >
          <.input
            field={@browser.form[:query]}
            type="search"
            placeholder="Search thread titles"
            autocomplete="off"
            phx-debounce="250"
          />
        </.form>
      </div>

      <div class={["flex-1 overflow-y-auto px-2 py-2 sm:px-3", scrollbar_classes()]}>
        <p
          :if={@browser.entries == []}
          id="thread-browser-empty"
          class="px-3 py-8 text-center text-sm text-base-content/55"
        >
          {thread_browser_empty_text(@browser)}
        </p>

        <ul id="thread-browser-list" class="space-y-1">
          <li
            :for={entry <- @browser.entries}
            id={"thread-browser-row-#{entry.thread.id}"}
            class="group flex items-center gap-3 rounded-lg px-3 py-2.5 transition hover:bg-base-200"
          >
            <button
              type="button"
              phx-click="open_browsed_thread"
              phx-value-id={entry.thread.id}
              id={"thread-browser-open-#{entry.thread.id}"}
              class="min-w-0 flex-1 text-left"
            >
              <span class="block truncate text-sm font-semibold text-base-content">
                {thread_title(entry.thread)}
              </span>
              <span class="mt-0.5 block truncate text-[11px] text-base-content/55">
                {entry.reply_count} {if entry.reply_count == 1, do: "reply", else: "replies"} · last activity {message_timestamp(
                  entry.last_activity_at
                )}
              </span>
            </button>
            <button
              type="button"
              phx-click={if entry.following?, do: "unfollow_thread", else: "follow_thread"}
              phx-value-id={entry.thread.id}
              id={"thread-browser-follow-#{entry.thread.id}"}
              aria-pressed={to_string(entry.following?)}
              class={[
                "shrink-0 rounded-md px-2.5 py-1 text-[11px] font-semibold transition",
                entry.following? && "bg-primary/10 text-primary hover:bg-primary/15",
                !entry.following? &&
                  "text-base-content/60 hover:bg-base-300 hover:text-base-content"
              ]}
            >
              {if entry.following?, do: "Following", else: "Follow"}
            </button>
          </li>
        </ul>

        <div :if={@browser.next} class="px-3 py-3">
          <button
            type="button"
            id="thread-browser-more"
            phx-click="thread_browser_more"
            phx-disable-with="Loading..."
            class="w-full rounded-md border border-base-300 px-3 py-2 text-xs font-semibold text-base-content/75 transition hover:bg-base-200 hover:text-base-content"
          >
            Load more
          </button>
        </div>
      </div>
    </aside>
    """
  end

  defp thread_browser_empty_text(%{query: query}) when query not in [nil, ""],
    do: "No threads match that title."

  defp thread_browser_empty_text(%{tab: :archived}), do: "No archived threads."
  defp thread_browser_empty_text(_browser), do: "No active threads."
end
