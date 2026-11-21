defmodule TavernWeb.ServerComponents.Messages do
  @moduledoc false

  use TavernWeb, :html

  alias Tavern.Chat

  import TavernWeb.ServerComponents.Helpers

  attr :server, :map, required: true

  def active_channel_view(assigns) do
    ~H"""
    <.channel_header server={@server} />
    <%= cond do %>
      <% @server.forum -> %>
        <TavernWeb.ServerComponents.Forums.forum_view server={@server} />
      <% true -> %>
        <.message_stream server={@server} />
    <% end %>
    <%!-- An open thread holds the one composer on screen; a forum takes no top-level messages. --%>
    <%= unless Chat.Channel.forum?(@server.active_channel) or @server.active_thread do %>
      <.typing_indicator users={@server.channel_pane.typing_users} id="channel-typing-indicator" />
      <TavernWeb.ServerComponents.Composer.channel_composer server={@server} />
    <% end %>
    """
  end

  attr :server, :map, required: true

  def channel_header(assigns) do
    ~H"""
    <header class="flex items-center justify-between border-b border-base-300 bg-base-200/95 px-4 py-3 shadow-sm backdrop-blur">
      <div class="flex min-w-0 items-center gap-3">
        <button
          type="button"
          phx-click="toggle_mobile_sidebar"
          id="open-mobile-sidebar"
          class="inline-flex shrink-0 items-center justify-center rounded-md px-2 py-1 text-sm font-semibold text-base-content/70 transition hover:bg-base-100 hover:text-base-content xl:hidden"
        >
          ☰
        </button>
        <div class="flex items-center gap-2">
          <span class="text-lg font-bold text-base-content/50">#</span>
          <div class="min-w-0">
            <h1 class="truncate text-[15px] font-semibold text-base-content">
              {@server.active_channel.name}
            </h1>
            <TavernWeb.ServerComponents.ChannelEditor.channel_topic server={@server} />
          </div>
        </div>
      </div>

      <div class="ml-4 flex items-center gap-2 text-xs text-base-content/65">
        <button
          :if={Tavern.Chat.Channel.thread_host?(@server.active_channel)}
          type="button"
          phx-click="open_thread_browser"
          phx-value-channel-id={@server.active_channel.id}
          id="open-thread-browser"
          class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-100 hover:text-base-content"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4" />
          <span class="hidden sm:inline">Threads</span>
        </button>
        <button
          type="button"
          phx-click="toggle_mobile_members"
          id="open-mobile-members"
          class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-100 hover:text-base-content xl:hidden"
        >
          <span aria-hidden="true">👥</span>
          <span>{length(@server.member_presence)}</span>
        </button>
        <button
          type="button"
          phx-click="toggle_members_collapsed"
          id="toggle-members-sidebar"
          aria-pressed={to_string(!@server.members_collapsed?)}
          title="Toggle member list"
          class={[
            "hidden items-center gap-1 rounded-md px-2 py-1 text-[11px] font-semibold transition hover:bg-base-100 hover:text-base-content xl:inline-flex",
            if(@server.members_collapsed?, do: "text-base-content/50", else: "text-base-content/90")
          ]}
        >
          <span aria-hidden="true">👥</span>
          <span>{length(@server.member_presence)}</span>
        </button>
        <span
          :if={!Chat.Channel.forum?(@server.active_channel)}
          id="channel-message-count"
          class="hidden rounded-md bg-base-100 px-2 py-1 font-medium sm:inline-flex"
        >
          {@server.channel_pane.message_count} messages
        </span>
        <span class="hidden items-center gap-1 rounded-md bg-emerald-500/10 px-2 py-1 text-emerald-300 sm:inline-flex">
          <span class="size-2 rounded-full bg-emerald-400" /> online
        </span>
      </div>
    </header>
    """
  end

  attr :server, :map, required: true

  def message_stream(assigns) do
    ~H"""
    <div
      id="message-scroll-region"
      class={["flex-1 overflow-y-auto", scrollbar_classes()]}
      phx-hook="MessageListHook"
    >
      <div
        :if={@server.channel_pane.empty?}
        class="mx-4 my-6 rounded-lg border border-dashed border-base-300 bg-base-100 p-6 text-left"
      >
        <p class="text-[11px] font-bold uppercase tracking-[0.22em] text-base-content/50">
          Start of #{@server.active_channel.slug}
        </p>
        <p class="mt-2 text-sm leading-6 text-base-content/80">
          This is the beginning of the
          <span class="font-semibold text-base-content">#{@server.active_channel.name}</span>
          channel. Drop a message to get the conversation moving.
        </p>
      </div>

      <div id="message-list" phx-update="stream" class="px-0 py-3">
        <.message_item
          :for={{dom_id, message} <- @server.streams.messages}
          dom_id={dom_id}
          message={message}
          server={@server}
        />
      </div>
    </div>
    """
  end

  attr :dom_id, :any, required: true
  attr :message, :map, required: true
  attr :server, :map, required: true

  @doc """
  One message row, in a channel or in the open thread. The row takes the rights of the
  conversation that holds the message (`message_rights/2`). A thread row has no thread of its
  own: a forum post's first message is the post's starter, and would otherwise host the thread
  inside itself. A channel row whose thread is open renders the thread under itself, outside the
  row's hover group, so hovering a reply shows only that reply's actions.
  """
  def message_item(assigns) do
    rights = message_rights(assigns.server, assigns.message)

    thread =
      if rights.thread?,
        do: nil,
        else: thread_for_message(assigns.message, assigns.server.thread_summaries)

    assigns = assign(assigns, rights: rights, thread: thread)

    ~H"""
    <div id={@dom_id}>
      <div class="group anchor-scope relative px-4 py-0.5 hover:bg-base-100/80">
        <article class="relative flex gap-3 py-2">
          <div class="shrink-0 pt-0.5">
            <div class="flex size-10 items-center justify-center rounded-full bg-base-300 text-[13px] font-semibold text-base-content">
              {@message.author.display_name |> String.first()}
            </div>
          </div>

          <div class="min-w-0 flex-1" phx-click="toggle_message_controls" phx-value-id={@message.id}>
            <div :if={@message.reply_to} class="mt-1 text-xs text-base-content/65">
              <span class="truncate">
                Replying to
                <span class="font-semibold text-base-content/80">
                  {@message.reply_to.author.display_name}
                </span>
                ·
                <%= if deleted_message?(@message.reply_to) do %>
                  <span id={"reply-deleted-#{@message.id}"} class="italic">
                    Original message deleted
                  </span>
                <% else %>
                  {@message.reply_to.body}
                <% end %>
              </span>
            </div>

            <div class="flex items-baseline gap-2">
              <p class="truncate text-[15px] font-medium leading-5 text-base-content">
                {@message.author.display_name}
              </p>
              <time class="shrink-0 text-[11px] text-base-content/50">
                {message_timestamp(@message.inserted_at)}
              </time>
            </div>

            <%= if @server.editing_message_id == @message.id do %>
              <.form
                for={@server.editing_form}
                id={"edit-message-form-#{@message.id}"}
                phx-submit="save_edit"
                class="mt-2"
              >
                <input type="hidden" name="message[id]" value={@message.id} />
                <div class="rounded-md border border-primary/30 bg-base-100 p-2">
                  <.input
                    field={@server.editing_form[:body]}
                    type="textarea"
                    id={"edit-message-body-#{@message.id}"}
                    rows="3"
                    class="min-h-24 w-full resize-none rounded-md border border-base-300 bg-base-200 px-3 py-2 text-sm text-base-content outline-none transition focus:border-primary"
                  />
                  <div class="mt-2 flex items-center justify-end gap-2">
                    <button
                      type="button"
                      phx-click="cancel_edit"
                      class="rounded-md px-2.5 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
                    >
                      Cancel
                    </button>
                    <button
                      type="submit"
                      class="rounded-md bg-violet-500 px-2.5 py-1 text-[11px] font-semibold text-white transition hover:bg-violet-400"
                    >
                      Save
                    </button>
                  </div>
                </div>
              </.form>
            <% else %>
              <%= if poll_message?(@message) do %>
                <TavernWeb.ServerComponents.Polls.poll_card
                  message={@message}
                  server={@server}
                  rights={@rights}
                />
              <% else %>
                <div
                  class={["message-body", message_body_classes()]}
                  data-markdown-source={@message.body}
                >
                  {@message.body}
                </div>
              <% end %>
            <% end %>

            <TavernWeb.ServerComponents.Embeds.message_embeds
              message={@message}
              removable?={embeds_removable?(@message, @server)}
            />

            <div class="mt-1 flex items-center gap-2 text-[11px] text-base-content/50">
              <span :if={edited_message?(@message)}>(edited)</span>
            </div>

            <div class="mt-2 flex flex-wrap items-center gap-1.5">
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
                disabled={!@rights.react?}
                class={[
                  "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-semibold transition",
                  reaction.reacted? && "border-violet-400/60 bg-violet-500/20 text-violet-100",
                  !reaction.reacted? &&
                    "border-base-300 bg-base-100 text-base-content/70 hover:border-base-content/20 hover:text-base-content",
                  !@rights.react? &&
                    "cursor-not-allowed opacity-50 hover:border-base-300 hover:text-base-content/70"
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
            </div>

            <.reaction_picker
              :if={reaction_picker_open?(@message, @server.reaction_picker_message_id)}
              message={@message}
              server={@server}
            />

            <%!-- The pill toggles the thread: it opens it, and closes it again while it is open. --%>
            <.link
              :if={@thread}
              patch={
                if thread_open_for_message?(@message, @server.active_thread),
                  do: channel_path(@server.active_channel),
                  else: thread_path(@server.active_channel, @thread)
              }
              id={"thread-summary-#{@message.id}"}
              aria-expanded={
                if(thread_open_for_message?(@message, @server.active_thread),
                  do: "true",
                  else: "false"
                )
              }
              class="mt-3 inline-flex max-w-full items-center gap-2 rounded-full border border-base-300 bg-base-100 px-3 py-1 text-[11px] font-semibold text-base-content/75 transition hover:border-base-content/20 hover:text-base-content"
            >
              <.icon name="hero-chat-bubble-left-right" class="size-3.5 shrink-0" />
              <%!-- The title shows only once someone has named the thread; an unnamed thread is
                   known by its starter, which sits right above. --%>
              <span
                :if={@thread.name}
                id={"thread-summary-title-#{@message.id}"}
                class="max-w-[12rem] shrink-0 truncate text-base-content"
              >
                {@thread.name}
              </span>
              <span class={["shrink-0", @thread.name && "font-normal text-base-content/55"]}>
                {reply_count_label(thread_reply_count(@message, @server.thread_summaries))}
              </span>
              <% latest = thread_latest_reply(@message, @server.thread_summaries) %>
              <span
                :if={latest}
                id={"thread-latest-reply-#{@message.id}"}
                class="min-w-0 truncate font-normal text-base-content/55"
              >
                <span class="font-semibold text-base-content/75">{latest.author.display_name}</span>
                {body_preview(latest.body)}
              </span>
              <span :if={!latest and !@thread.name} class="truncate text-base-content/45">
                {thread_title(@thread)}
              </span>
            </.link>

            <p :if={!@rights.react?} class="mt-2 text-[11px] text-base-content/50">
              Reactions are disabled for your permissions in this channel.
            </p>
          </div>

          <.message_actions server={@server} message={@message} thread={@thread} rights={@rights} />
        </article>
      </div>

      <div
        :if={@thread && thread_open_for_message?(@message, @server.active_thread)}
        class="pb-3 pl-4 pr-4 sm:pl-[4.25rem]"
      >
        <TavernWeb.ServerComponents.Threads.thread_panel
          server={@server}
          message={@message}
          thread={@thread}
        />
      </div>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :message, :map, required: true

  def reaction_picker(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="close_reaction_picker"
      id={"reaction-picker-overlay-#{@message.id}"}
      class="fixed inset-0 z-10 bg-black/50 md:hidden"
      aria-label="Close reaction picker"
    />

    <div
      id={"reaction-picker-#{@message.id}"}
      phx-hook="ReactionPickerHook"
      data-custom-emojis={@server.custom_emojis_json}
      class="anchored-picker fixed inset-x-0 bottom-0 z-20 rounded-t-[1.4rem] border border-base-300 bg-base-100 p-3 shadow-2xl md:w-[22rem] md:rounded-2xl"
    >
      <div class="mb-2 flex items-center justify-between gap-3">
        <div>
          <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            Reactions
          </p>
          <p class="mt-1 text-xs text-base-content/65">
            Pick a default or custom emoji.
          </p>
        </div>
        <button
          type="button"
          phx-click="close_reaction_picker"
          id={"close-reaction-picker-#{@message.id}"}
          class="rounded-md px-2 py-1 text-[10px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          Close
        </button>
      </div>

      <div class="space-y-3">
        <div>
          <label
            for={"reaction-picker-search-#{@message.id}"}
            class="mb-2 block text-[10px] font-bold uppercase tracking-[0.16em] text-base-content/50"
          >
            Search
          </label>
          <input
            id={"reaction-picker-search-#{@message.id}"}
            type="search"
            placeholder="Search emojis"
            data-reaction-picker-search
            class="w-full rounded-xl border border-base-300 bg-base-200 px-3 py-2 text-sm text-base-content outline-none transition placeholder:text-base-content/45 focus:border-primary/60"
          />
        </div>

        <div>
          <p class="mb-2 text-[10px] font-bold uppercase tracking-[0.16em] text-base-content/50">
            Default
          </p>

          <div class="grid min-h-0 grid-cols-[2.75rem_minmax(0,1fr)] gap-3">
            <div
              data-reaction-picker-categories
              class={[
                "flex max-h-[40vh] flex-col gap-2 overflow-y-auto pr-1 md:max-h-72",
                scrollbar_classes()
              ]}
            />

            <div
              data-reaction-picker-defaults
              data-message-id={@message.id}
              class={[
                "grid max-h-[40vh] grid-cols-8 gap-1 overflow-y-auto pr-1 md:max-h-72 md:grid-cols-8",
                scrollbar_classes()
              ]}
            >
              <button
                :for={emoji <- Chat.default_reaction_emojis()}
                type="button"
                phx-click="toggle_reaction"
                phx-value-id={@message.id}
                phx-value-emoji={emoji}
                id={"reaction-picker-default-#{@message.id}-#{Base.url_encode64(emoji, padding: false)}"}
                class="flex aspect-square size-10 items-center justify-center rounded-xl text-xl transition hover:bg-base-200 md:size-9 md:text-lg"
              >
                <span>{emoji}</span>
              </button>
            </div>
          </div>
        </div>

        <div>
          <p class="mb-2 text-[10px] font-bold uppercase tracking-[0.16em] text-base-content/50">
            Custom
          </p>
          <div
            :if={@server.custom_emojis != []}
            class="grid grid-cols-6 gap-1.5 md:grid-cols-6"
            data-reaction-picker-custom
          >
            <button
              :for={emoji <- @server.custom_emojis}
              type="button"
              phx-click="toggle_custom_reaction"
              phx-value-id={@message.id}
              phx-value-emoji_id={emoji.id}
              id={"reaction-picker-custom-#{@message.id}-#{emoji.id}"}
              data-custom-emoji-id={emoji.id}
              data-custom-emoji-name={emoji.name}
              data-custom-emoji-shortcode={emoji.shortcode}
              class="group flex aspect-square size-11 items-center justify-center rounded-xl text-[10px] font-medium text-base-content/80 transition hover:bg-base-200 hover:text-base-content md:size-10"
            >
              <img
                src={emoji.url}
                alt={emoji.name}
                class="size-7 rounded-md object-cover transition group-hover:scale-105"
              />
              <span class="sr-only">{emoji.name}</span>
            </button>
          </div>
          <p
            :if={@server.custom_emojis == []}
            class="rounded-xl border border-dashed border-base-300 bg-base-200 px-3 py-3 text-xs text-base-content/50"
          >
            No custom emoji uploaded yet.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :message, :map, required: true
  attr :thread, :map, default: nil
  attr :rights, :map, required: true

  def message_actions(assigns) do
    ~H"""
    <div class={[
      "anchor-toolbar absolute right-4 top-0 z-10 flex items-center gap-1 rounded-full border border-base-300 bg-base-100/95 p-1 shadow-lg transition",
      message_controls_visible?(
        @message.id,
        @server.active_message_controls_id,
        @server.message_action_menu_id
      ) &&
        "opacity-100 translate-none pointer-events-auto",
      !message_controls_visible?(
        @message.id,
        @server.active_message_controls_id,
        @server.message_action_menu_id
      ) &&
        "pointer-events-none -translate-y-1 opacity-0 group-hover:pointer-events-auto group-hover:translate-none group-hover:opacity-100 group-focus-within:pointer-events-auto group-focus-within:translate-y-0 group-focus-within:opacity-100"
    ]}>
      <button
        :if={can_open_message_controls?(@server, @message)}
        type="button"
        phx-click="reply_message"
        phx-value-id={@message.id}
        id={"quick-reply-message-#{@message.id}"}
        disabled={!@rights.send?}
        class="inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-50"
        aria-label="Reply"
        title="Reply"
      >
        <.icon name="hero-arrow-uturn-left" class="size-4" />
      </button>

      <button
        :if={@thread}
        type="button"
        phx-click="open_thread"
        phx-value-id={@thread.id}
        id={"open-thread-#{@message.id}"}
        class="inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content"
        aria-label="Open thread"
        title="Open thread"
      >
        <.icon name="hero-chat-bubble-left-right" class="size-4" />
      </button>

      <button
        :if={
          not @rights.thread? and is_nil(@thread) and
            @server.channel_pane.abilities.create_public_threads
        }
        type="button"
        phx-click="create_thread"
        phx-value-id={@message.id}
        id={"create-thread-#{@message.id}"}
        class="inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content"
        aria-label="Start thread"
        title="Start thread"
      >
        <.icon name="hero-chat-bubble-bottom-center-text" class="size-4" />
      </button>

      <button
        type="button"
        phx-click="toggle_reaction_picker"
        phx-value-id={@message.id}
        id={"open-reaction-picker-#{@message.id}"}
        disabled={!@rights.react?}
        class="inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-50"
        aria-label="Add reaction"
        title="Add reaction"
      >
        <.icon name="hero-face-smile" class="size-4" />
      </button>

      <button
        :if={own_message?(@message, @server.current_user) or @rights.manage?}
        type="button"
        phx-click="toggle_message_action_menu"
        phx-value-id={@message.id}
        id={"open-message-actions-#{@message.id}"}
        class="anchor-menu-trigger inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content"
        aria-label="More actions"
        title="More actions"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </button>

      <div
        :if={message_action_menu_open?(@message.id, @server.message_action_menu_id)}
        id={"message-actions-menu-#{@message.id}"}
        class="anchored-menu z-20 min-w-40 rounded-xl border border-base-300 bg-base-100 p-1.5 shadow-xl"
      >
        <%= if @thread do %>
          <button
            type="button"
            phx-click="open_thread"
            phx-value-id={@thread.id}
            id={"open-thread-menu-#{@message.id}"}
            class="flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
          >
            <span>Open thread</span>
            <span class="text-base-content/50">#</span>
          </button>
        <% else %>
          <button
            :if={not @rights.thread? and @server.channel_pane.abilities.create_public_threads}
            type="button"
            phx-click="create_thread"
            phx-value-id={@message.id}
            id={"create-thread-menu-#{@message.id}"}
            class="flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
          >
            <span>Start thread</span>
            <span class="text-base-content/50">#</span>
          </button>
        <% end %>

        <button
          :if={own_message?(@message, @server.current_user) and not poll_message?(@message)}
          type="button"
          phx-click="edit_message"
          phx-value-id={@message.id}
          id={"edit-message-#{@message.id}"}
          class="flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
        >
          <span>Edit</span>
          <span class="text-base-content/50">✎</span>
        </button>

        <%= if own_message?(@message, @server.current_user) or @rights.manage? do %>
          <%= if delete_confirmation_open?(@message.id, @server.delete_confirmation_message_id) do %>
            <div
              id={"confirm-delete-message-#{@message.id}"}
              class="mt-1 rounded-lg border border-rose-500/20 bg-rose-500/8 p-3"
            >
              <p class="text-[11px] font-semibold text-rose-100">
                Delete this message?
              </p>
              <div class="mt-2 flex items-center gap-2">
                <button
                  type="button"
                  phx-click="delete_message"
                  phx-value-id={@message.id}
                  id={"delete-message-#{@message.id}"}
                  class="rounded-md bg-rose-500 px-2.5 py-1 text-[11px] font-semibold text-white transition hover:bg-rose-400"
                >
                  Delete
                </button>
                <button
                  type="button"
                  phx-click="cancel_delete_message"
                  id={"cancel-delete-message-#{@message.id}"}
                  class="rounded-md px-2.5 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
                >
                  Cancel
                </button>
              </div>
            </div>
          <% else %>
            <button
              type="button"
              phx-click="confirm_delete_message"
              phx-value-id={@message.id}
              id={"prompt-delete-message-#{@message.id}"}
              class="flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-[11px] font-semibold text-rose-200 transition hover:bg-rose-500/10 hover:text-rose-100"
            >
              <span>Delete</span>
              <span class="text-rose-300">🗑</span>
            </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :users, :list, required: true
  attr :id, :string, required: true

  def typing_indicator(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "px-4 pt-2 text-xs text-base-content/60 transition min-h-5",
        @users == [] && "invisible"
      ]}
    >
      <%= if @users != [] do %>
        {typing_label(@users)}
      <% end %>
    </div>
    """
  end

  defp typing_label([user]), do: "#{user.display_name} is typing..."

  defp typing_label([first, second]),
    do: "#{first.display_name} and #{second.display_name} are typing..."

  defp typing_label([first, second | _rest]),
    do: "#{first.display_name}, #{second.display_name}, and others are typing..."
end
