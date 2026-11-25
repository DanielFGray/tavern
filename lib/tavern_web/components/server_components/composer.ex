defmodule TavernWeb.ServerComponents.Composer do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  alias TavernWeb.ServerComponents.MessageAttachments
  alias TavernWeb.ServerComponents.Messages
  alias TavernWeb.ServerLive.Attachments
  alias TavernWeb.ServerLive.Pane

  attr :server, :map, required: true

  @doc """
  The composer pinned under the transcript. It writes to the open thread when one is open, else to
  the channel, and a thread shows a strip naming that target. The thread keeps no composer of its
  own, so the editor never moves.
  """
  def composer_dock(assigns) do
    thread = assigns.server.active_thread
    assigns = assign(assigns, thread: thread, pane: assigns.server.thread_pane)

    ~H"""
    <%= if @thread do %>
      <Messages.typing_indicator
        users={@pane.typing_users}
        id={"thread-typing-indicator-#{@thread.starter_message_id}"}
      />
      <div class="border-t border-base-300 bg-base-200 px-4 pt-3 pb-[calc(1rem+env(safe-area-inset-bottom))]">
        <%= if Pane.can_send?(@pane) do %>
          <div
            id="thread-target-indicator"
            class="mb-2 flex items-center justify-between gap-2 text-xs text-base-content/70"
          >
            <span class="min-w-0 truncate">
              <.icon name="hero-chat-bubble-left-right" class="mr-1 size-3.5 align-text-bottom" />
              Replying in thread
              <span class={["font-semibold text-base-content", thread_title_class(@thread)]}>
                {thread_title(@thread)}
              </span>
            </span>
            <button
              type="button"
              id="thread-target-close"
              phx-click="close_thread"
              class="shrink-0 rounded px-1.5 py-0.5 font-semibold transition hover:bg-base-300"
            >
              Close thread
            </button>
          </div>
          <.composer server={@server} target={:thread} />
        <% else %>
          <p id="thread-reply-notice" class="py-2 text-sm text-base-content/55">
            {cond do
              @thread.locked_at -> "This thread is locked."
              Tavern.Accounts.unverified?(@server.current_user) -> "Verify your email to reply."
              true -> "You can view this thread, but you do not have permission to reply in it."
            end}
          </p>
        <% end %>
      </div>
    <% else %>
      <Messages.typing_indicator
        users={@server.channel_pane.typing_users}
        id="channel-typing-indicator"
      />
      <.channel_composer server={@server} />
    <% end %>
    """
  end

  attr :server, :map, required: true

  @doc "The composer bar under a channel's messages, or the notice that replaces it."
  def channel_composer(assigns) do
    ~H"""
    <div class="border-t border-base-300 bg-base-200 px-4 pt-4 pb-[calc(1rem+env(safe-area-inset-bottom))]">
      <%= cond do %>
        <% Pane.can_send?(@server.channel_pane) -> %>
          <.composer server={@server} target={:channel} />
        <% true -> %>
          <TavernWeb.ServerComponents.Verification.send_notice
            id="composer-locked-notice"
            user={@server.current_user}
          />
      <% end %>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :target, :atom, values: [:channel, :thread], required: true

  @doc """
  The rich composer form. `target` names the pane it writes to (`TavernWeb.ServerLive.Pane`): the
  open channel's or the open thread's. One shows at a time, and both share `:reply_to_message`
  for the reply banner and `:poll_form` for the poll form above it. The DOM ids differ per target
  because tests and the composer hook address each one.
  """
  def composer(assigns) do
    pane = Map.fetch!(assigns.server, Pane.assign_key(assigns.target))
    conversation = Map.fetch!(assigns.server, Pane.conversation_key(assigns.target))

    assigns =
      assigns
      |> assign(composer_config(assigns.target))
      |> assign_direct_placeholder(conversation)
      |> assign(
        pane: pane,
        form: pane.form,
        uploads: assigns.server.uploads.attachments,
        draft_key: draft_key(assigns.server.current_user, conversation)
      )

    ~H"""
    <TavernWeb.ServerComponents.Questions.poll_composer :if={@server.poll_form} server={@server} />
    <.form
      for={@form}
      id={@ids.form}
      phx-submit={@submit}
      phx-change="validate_attachments"
      phx-hook="RichComposerHook"
      data-composer-target={@target}
      data-draft-key={@draft_key}
      data-placeholder={@placeholder}
      data-mentions={@server.composer_mentions_json}
      data-commands={@server.composer_commands_json}
      data-custom-emojis={@server.custom_emojis_json}
    >
      <div
        class="rounded-lg border border-base-300 bg-base-100 shadow-sm transition phx-drop-target-active:border-violet-400 phx-drop-target-active:ring-2 phx-drop-target-active:ring-violet-400/30"
        phx-drop-target={@pane.abilities.attach_files && @uploads.ref}
      >
        <.live_file_input upload={@uploads} class="hidden" />
        <div
          :if={@server.reply_to_message}
          id={@ids.banner}
          class="flex items-center justify-between border-b border-base-300 bg-primary/10 px-3 py-2 text-xs text-primary"
        >
          <div class="min-w-0">
            Replying to
            <span class="font-semibold">{@server.reply_to_message.author.display_name}</span>
            <p class="truncate text-[11px] text-primary/70">
              {body_preview(@server.reply_to_message.body)}
            </p>
          </div>
          <button
            type="button"
            phx-click="cancel_reply"
            class="rounded px-1.5 py-0.5 text-[11px] font-semibold text-primary transition hover:bg-base-200"
          >
            Cancel
          </button>
        </div>

        <.pending_attachments uploads={@uploads} id={@ids.attachments} />

        <div class="flex items-end gap-2 px-3 py-2">
          <div class="relative shrink-0">
            <button
              type="button"
              id={@ids.plus}
              phx-click={JS.toggle(to: "##{@ids.menu}")}
              aria-label="Add to message"
              title="Add to message"
              aria-haspopup="menu"
              class="inline-flex size-7 items-center justify-center rounded-md border border-base-300 bg-base-200 text-base-content/70 transition hover:border-violet-400/50 hover:text-violet-300"
            >
              <.icon name="hero-plus" class="size-4" />
            </button>
            <div
              id={@ids.menu}
              role="menu"
              phx-click-away={JS.hide(to: "##{@ids.menu}")}
              class="absolute bottom-full left-0 z-20 mb-2 hidden w-44 rounded-lg border border-base-300 bg-base-100 p-1 shadow-lg"
            >
              <button
                type="button"
                id={@ids.poll}
                role="menuitem"
                phx-click={JS.push("open_poll") |> JS.hide(to: "##{@ids.menu}")}
                aria-expanded={to_string(not is_nil(@server.poll_form))}
                class="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-chart-bar" class="size-4" /> Create poll
              </button>
              <%= if @pane.abilities.attach_files do %>
                <label
                  for={@uploads.ref}
                  id={@ids.attach}
                  data-attach-control
                  role="menuitem"
                  phx-click={JS.hide(to: "##{@ids.menu}")}
                  class="flex w-full cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
                >
                  <.icon name="hero-paper-clip" class="size-4" /> Upload attachment
                </label>
              <% else %>
                <button
                  type="button"
                  id={@ids.attach}
                  role="menuitem"
                  disabled
                  title="You do not have permission to attach files here"
                  class="flex w-full cursor-not-allowed items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] text-base-content/40"
                >
                  <.icon name="hero-paper-clip" class="size-4" /> Upload attachment
                </button>
              <% end %>
            </div>
          </div>

          <div
            id={@ids.shell}
            data-rich-composer-shell
            phx-update="ignore"
            class={composer_shell_classes()}
          >
            <div class={composer_toolbar_region_classes()} data-expanded="false">
              <div
                id={@ids.toolbar}
                data-rich-composer-toolbar
                class="flex flex-wrap items-center gap-1.5"
              >
                <.composer_button action="bold" label="Bold">B</.composer_button>
                <.composer_button action="italic" label="Italic">
                  <span class="text-[13px] italic font-semibold leading-none">I</span>
                </.composer_button>
                <.composer_button action="inline-code" label="Inline code">
                  <span class="text-[11px] font-black leading-none">&lt;/&gt;</span>
                </.composer_button>
                <.composer_button action="code-block" label="Code block">
                  <span class="text-[11px] font-black leading-none">```</span>
                </.composer_button>
                <.composer_button action="mention" label="Insert mention">
                  <span class="text-[13px] font-black leading-none">@</span>
                </.composer_button>
                <.composer_button action="slash" label="Insert slash command">
                  <span class="text-[13px] font-black leading-none">/</span>
                </.composer_button>
              </div>

              <p
                :if={!@pane.abilities.mention_everyone}
                class="m-0 text-[11px] text-amber-200"
              >
                @everyone and locked roles need extra permission
              </p>
            </div>

            <div data-rich-composer-editor class="min-h-0" />

            <textarea data-rich-composer-body name={@form[:body].name} class="hidden">{@form[:body].value || ""}</textarea>
            <textarea data-rich-composer-metadata name={@form[:metadata].name} class="hidden"></textarea>
          </div>

          <div class="flex shrink-0 items-center">
            <.button
              aria-label={@send_label}
              title={@send_label}
              id={@ids.send}
              class="inline-flex size-7 items-center justify-center rounded-md bg-violet-500 p-0 text-white transition hover:bg-violet-400"
            >
              <.icon name="hero-paper-airplane" class="size-4" />
            </.button>
          </div>
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Names the browser-side draft (`assets/js/composer_drafts.js`) of `user`'s unsent text in
  `conversation`, a channel or a thread. The user is part of it because people can share a browser.
  """
  def draft_key(user, conversation), do: "#{user.id}:#{conversation.id}"

  attr :uploads, :map, required: true
  attr :id, :string, required: true

  # The files waiting to go with the next send, each with its upload progress, its errors and a
  # remove button. An image shows a preview drawn from the browser's own copy.
  defp pending_attachments(assigns) do
    ~H"""
    <div
      :if={@uploads.entries != [] or upload_errors(@uploads) != []}
      id={@id}
      class="flex flex-wrap gap-2 border-b border-base-300 px-3 py-2"
    >
      <div
        :for={entry <- @uploads.entries}
        id={"pending-attachment-#{entry.ref}"}
        data-pending-attachment
        class={[
          "group/attachment relative flex w-48 items-center gap-2 rounded-md border bg-base-200 p-1.5 pr-7",
          if(upload_errors(@uploads, entry) == [],
            do: "border-base-300",
            else: "border-error/60"
          )
        ]}
      >
        <%= if String.starts_with?(entry.client_type || "", "image/") do %>
          <.live_img_preview entry={entry} class="size-10 shrink-0 rounded object-cover" />
        <% else %>
          <span class="flex size-10 shrink-0 items-center justify-center rounded bg-base-300 text-base-content/60">
            <.icon name="hero-document" class="size-5" />
          </span>
        <% end %>
        <div class="min-w-0 flex-1">
          <p class="truncate text-xs font-medium text-base-content" title={entry.client_name}>
            {entry.client_name}
          </p>
          <p
            :for={error <- upload_errors(@uploads, entry)}
            class="truncate text-[11px] text-error"
          >
            {Attachments.error_text(error)}
          </p>
          <div
            :if={upload_errors(@uploads, entry) == [] and not entry.done?}
            class="mt-1 h-1 overflow-hidden rounded bg-base-300"
          >
            <div class="h-full bg-violet-500 transition-all" style={"width: #{entry.progress}%"} />
          </div>
          <p :if={entry.done?} class="text-[11px] text-base-content/50">
            {MessageAttachments.format_bytes(entry.client_size)}
          </p>
        </div>
        <button
          type="button"
          id={"cancel-attachment-#{entry.ref}"}
          phx-click="cancel_attachment"
          phx-value-ref={entry.ref}
          aria-label={"Remove #{entry.client_name}"}
          title="Remove"
          class="absolute right-1 top-1 rounded p-0.5 text-base-content/50 transition hover:bg-base-300 hover:text-base-content"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
      <p :for={error <- upload_errors(@uploads)} class="w-full text-[11px] text-error">
        {Attachments.error_text(error)}
      </p>
    </div>
    """
  end

  attr :action, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  def composer_button(assigns) do
    ~H"""
    <button
      type="button"
      data-editor-action={@action}
      class={composer_toolbar_button_classes()}
      data-active="false"
      aria-label={@label}
      title={@label}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp assign_direct_placeholder(assigns, %Tavern.Chat.Channel{kind: :direct} = dm),
    do: assign(assigns, :placeholder, "Message #{Tavern.Chat.Channel.title(dm)}")

  defp assign_direct_placeholder(assigns, _conversation), do: assigns

  defp composer_config(:channel) do
    %{
      submit: "send_message",
      placeholder: "Message channel",
      send_label: "Send message",
      ids: %{
        form: "message-form",
        banner: "replying-to-banner",
        shell: "rich-composer-shell",
        toolbar: "rich-composer-toolbar",
        send: "send-message-button",
        poll: "open-poll-button",
        plus: "composer-plus-button",
        menu: "composer-plus-menu",
        attach: "composer-attach-button",
        attachments: "composer-attachments"
      }
    }
  end

  defp composer_config(:thread) do
    %{
      submit: "send_thread_message",
      placeholder: "Reply in thread",
      send_label: "Send thread message",
      ids: %{
        form: "thread-message-form",
        banner: "thread-replying-to-banner",
        shell: "thread-rich-composer-shell",
        toolbar: "thread-rich-composer-toolbar",
        send: "send-thread-message-button",
        poll: "thread-open-poll-button",
        plus: "thread-composer-plus-button",
        menu: "thread-composer-plus-menu",
        attach: "thread-composer-attach-button",
        attachments: "thread-composer-attachments"
      }
    }
  end
end
