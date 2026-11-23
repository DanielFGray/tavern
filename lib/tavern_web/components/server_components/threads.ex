defmodule TavernWeb.ServerComponents.Threads do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  alias TavernWeb.ServerComponents.Messages

  attr :server, :map, required: true
  attr :message, :map, required: true
  attr :thread, :map, required: true

  @doc """
  The open thread, under its starter: a flat region marked by a left rule, with a header, all the
  thread's messages as channel message rows. The composer is not here: it stays pinned below the
  transcript (`Composer.composer_dock/1`). `message` is the starter.
  """
  def thread_panel(assigns) do
    assigns =
      assign(assigns,
        menu_id: "thread-actions-menu-#{assigns.message.id}",
        rename_form: to_form(%{"name" => rename_value(assigns.thread)}, as: :thread_rename),
        menu?:
          assigns.server.thread_pane.abilities.archive_thread or
            assigns.server.thread_pane.abilities.rename_thread or
            assigns.server.thread_pane.abilities.lock_thread or
            assigns.server.thread_pane.abilities.delete_thread
      )

    ~H"""
    <section
      id={"thread-panel-#{@message.id}"}
      aria-label={"Thread: #{thread_title(@thread)}"}
      class="border-l-2 border-base-300 pl-1 sm:pl-2"
    >
      <header class="flex min-w-0 items-center gap-2 py-1 pl-3 pr-1">
        <.icon name="hero-chat-bubble-left-right" class="size-4 shrink-0 text-base-content/45" />
        <h3
          id={"thread-title-#{@message.id}"}
          class={[
            "min-w-0 truncate text-sm font-semibold text-base-content",
            thread_title_class(@thread)
          ]}
        >
          {thread_title(@thread)}
        </h3>
        <%!-- Shown client-side by the Rename menu item; a submit or Escape hides it again. --%>
        <.form
          :if={@server.thread_pane.abilities.rename_thread}
          for={@rename_form}
          id={"thread-rename-form-#{@message.id}"}
          phx-submit={
            JS.push("rename_thread")
            |> JS.hide(to: "#thread-rename-form-#{@message.id}")
            |> JS.show(to: "#thread-title-#{@message.id}")
          }
          class="hidden min-w-0 flex-1"
        >
          <input
            type="text"
            id={"thread-rename-input-#{@message.id}"}
            name={@rename_form[:name].name}
            value={@rename_form[:name].value}
            phx-keydown={
              JS.hide(to: "#thread-rename-form-#{@message.id}")
              |> JS.show(to: "#thread-title-#{@message.id}")
            }
            phx-key="Escape"
            maxlength="40"
            required
            autocomplete="off"
            aria-label="Thread title"
            class="w-full min-w-0 rounded-md border border-base-300 bg-base-100 px-2 py-0.5 text-sm font-semibold text-base-content outline-none transition focus:border-primary"
          />
        </.form>
        <span
          id={"thread-reply-count-#{@message.id}"}
          class="shrink-0 text-xs text-base-content/55"
        >
          {reply_count_label(@server.thread_pane.message_count)}
        </span>
        <span
          :if={@thread.locked_at}
          id={"thread-locked-badge-#{@message.id}"}
          class="shrink-0 text-[10px] font-semibold uppercase tracking-wider text-warning"
        >
          Locked
        </span>
        <span
          :if={@thread.archived_at}
          id={"thread-archived-badge-#{@message.id}"}
          class="shrink-0 text-[10px] font-semibold uppercase tracking-wider text-base-content/50"
        >
          Archived
        </span>

        <div class="ml-auto flex shrink-0 items-center gap-0.5">
          <button
            type="button"
            phx-click={if @server.thread_following?, do: "unfollow_thread", else: "follow_thread"}
            phx-value-id={@thread.id}
            id={"toggle-follow-thread-#{@message.id}"}
            aria-pressed={to_string(@server.thread_following?)}
            aria-label={if @server.thread_following?, do: "Unfollow thread", else: "Follow thread"}
            title={if @server.thread_following?, do: "Unfollow thread", else: "Follow thread"}
            class={[
              thread_icon_button_classes(),
              @server.thread_following? && "text-primary hover:bg-primary/10",
              !@server.thread_following? && "text-base-content/60"
            ]}
          >
            <.icon
              name={if @server.thread_following?, do: "hero-bell-alert-solid", else: "hero-bell"}
              class="size-4"
            />
          </button>

          <div :if={@menu?} class="anchor-scope relative" phx-click-away={JS.hide(to: "##{@menu_id}")}>
            <button
              type="button"
              id={"thread-actions-#{@message.id}"}
              phx-click={JS.toggle(to: "##{@menu_id}")}
              aria-haspopup="menu"
              aria-controls={@menu_id}
              aria-label="Thread actions"
              title="Thread actions"
              class={["anchor-menu-trigger", thread_icon_button_classes(), "text-base-content/60"]}
            >
              <.icon name="hero-ellipsis-horizontal" class="size-4" />
            </button>
            <div
              id={@menu_id}
              role="menu"
              class="anchored-menu z-20 hidden min-w-36 rounded-xl border border-base-300 bg-base-100 p-1.5 shadow-xl"
            >
              <button
                :if={@server.thread_pane.abilities.archive_thread}
                type="button"
                role="menuitem"
                phx-click={
                  JS.hide(to: "##{@menu_id}")
                  |> JS.push(if @thread.archived_at, do: "unarchive_thread", else: "archive_thread")
                }
                id={"toggle-archive-thread-#{@message.id}"}
                class={thread_menu_item_classes()}
              >
                <.icon name="hero-archive-box" class="size-4 text-base-content/50" />
                {if @thread.archived_at, do: "Unarchive", else: "Archive"}
              </button>
              <button
                :if={@server.thread_pane.abilities.rename_thread}
                type="button"
                role="menuitem"
                phx-click={
                  JS.hide(to: "##{@menu_id}")
                  |> JS.hide(to: "#thread-title-#{@message.id}")
                  |> JS.show(to: "#thread-rename-form-#{@message.id}", display: "block")
                  |> JS.focus(to: "#thread-rename-input-#{@message.id}")
                }
                id={"rename-thread-#{@message.id}"}
                class={thread_menu_item_classes()}
              >
                <.icon name="hero-pencil-square" class="size-4 text-base-content/50" /> Rename
              </button>
              <button
                :if={@server.thread_pane.abilities.lock_thread}
                type="button"
                role="menuitem"
                phx-click={
                  JS.hide(to: "##{@menu_id}")
                  |> JS.push(if @thread.locked_at, do: "unlock_thread", else: "lock_thread")
                }
                id={"toggle-lock-thread-#{@message.id}"}
                class={thread_menu_item_classes()}
              >
                <.icon
                  name={if @thread.locked_at, do: "hero-lock-open", else: "hero-lock-closed"}
                  class="size-4 text-base-content/50"
                />
                {if @thread.locked_at, do: "Unlock", else: "Lock"}
              </button>
              <%!-- The confirm step is client-side: the prompt button swaps for the confirm row. --%>
              <div :if={@server.thread_pane.abilities.delete_thread}>
                <button
                  type="button"
                  role="menuitem"
                  phx-click={
                    JS.hide(to: "#prompt-delete-thread-#{@message.id}")
                    |> JS.show(to: "#confirm-delete-thread-#{@message.id}")
                  }
                  id={"prompt-delete-thread-#{@message.id}"}
                  class={[thread_menu_item_classes(), "text-error hover:text-error"]}
                >
                  <.icon name="hero-trash" class="size-4" /> Delete thread
                </button>
                <div
                  id={"confirm-delete-thread-#{@message.id}"}
                  class="hidden px-3 py-2 text-xs"
                >
                  <p class="mb-2 font-semibold text-base-content/80">
                    Delete this thread and its replies?
                  </p>
                  <div class="flex gap-1.5">
                    <button
                      type="button"
                      phx-click={JS.hide(to: "##{@menu_id}") |> JS.push("delete_thread")}
                      id={"delete-thread-#{@message.id}"}
                      class="rounded-lg bg-error px-2.5 py-1 font-semibold text-error-content transition hover:opacity-90"
                    >
                      Delete
                    </button>
                    <button
                      type="button"
                      phx-click={
                        JS.hide(to: "#confirm-delete-thread-#{@message.id}")
                        |> JS.show(to: "#prompt-delete-thread-#{@message.id}", display: "flex")
                      }
                      id={"cancel-delete-thread-#{@message.id}"}
                      class="rounded-lg px-2.5 py-1 font-semibold text-base-content/70 transition hover:bg-base-200"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <button
            type="button"
            phx-click="close_thread"
            id={"close-thread-#{@message.id}"}
            aria-label="Close thread"
            title="Close thread"
            class={[thread_icon_button_classes(), "text-base-content/60"]}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </header>

      <%!-- No scroll box of its own: a row's reaction picker and action menu are popovers that
           a clipping box would cut. MessageListHook renders the rows' markdown; a forum post has
           no channel list around it to do so. --%>
      <div
        id={"thread-messages-#{@message.id}"}
        data-enable-notifications="false"
        data-custom-emojis={@server.custom_emojis_json}
        phx-hook="MessageListHook"
      >
        <p :if={@server.thread_pane.empty?} class="px-3 py-2 text-sm text-base-content/55">
          No replies yet.
        </p>

        <div id={"thread-message-list-#{@message.id}"} phx-update="stream">
          <Messages.message_item
            :for={{thread_dom_id, thread_message} <- @server.streams.thread_messages}
            dom_id={thread_dom_id}
            message={thread_message}
            server={@server}
          />
        </div>
      </div>
    </section>
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
              <span class={[
                "block truncate text-sm font-semibold text-base-content",
                thread_title_class(entry.thread)
              ]}>
                {thread_title(entry.thread)}
              </span>
              <span class="mt-0.5 block truncate text-[11px] text-base-content/55">
                {reply_count_label(entry.reply_count)} · last activity {message_timestamp(
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

  # The Rename field starts from the title, unless the title is the placeholder for a deleted
  # starter: that is not a name anyone chose, so renaming must not save it.
  defp rename_value(thread) do
    if Tavern.Chat.Channel.deleted_starter_title?(thread), do: "", else: thread_title(thread)
  end

  defp thread_browser_empty_text(%{query: query}) when query not in [nil, ""],
    do: "No threads match that title."

  defp thread_browser_empty_text(%{tab: :archived}), do: "No archived threads."
  defp thread_browser_empty_text(_browser), do: "No active threads."

  defp thread_icon_button_classes,
    do:
      "inline-flex size-8 items-center justify-center rounded-md transition hover:bg-base-200 hover:text-base-content"

  defp thread_menu_item_classes,
    do:
      "flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-xs font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
end
