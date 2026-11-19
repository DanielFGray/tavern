defmodule TavernWeb.ServerComponents.Composer do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  attr :server, :map, required: true

  @doc "The composer bar under a channel's messages, or the notice that replaces it."
  def channel_composer(assigns) do
    ~H"""
    <div class="border-t border-base-300 bg-base-200 px-4 pt-4 pb-[calc(1rem+env(safe-area-inset-bottom))]">
      <%= cond do %>
        <% @server.can_send_messages? -> %>
          <.composer server={@server} target={:channel} />
        <% true -> %>
          <div class="rounded-lg border border-warning/30 bg-warning/15 px-4 py-3 text-sm text-warning-content">
            You can view this channel, but you do not have permission to send messages here.
          </div>
      <% end %>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :target, :atom, values: [:channel, :thread], required: true

  @doc """
  The rich composer form. `target` names the conversation it writes to: the open channel or the
  open thread. One shows at a time, and both share `:reply_to_message` for the reply banner and
  `:poll_form` for the poll form above it. The
  DOM ids differ per target because tests and the composer hook address each one.
  """
  def composer(assigns) do
    assigns = assign(assigns, composer_config(assigns.server, assigns.target))

    ~H"""
    <TavernWeb.ServerComponents.Polls.poll_composer :if={@server.poll_form} server={@server} />
    <.form
      for={@form}
      id={@ids.form}
      phx-submit={@submit}
      phx-hook="RichComposerHook"
      data-composer-target={@target}
      data-placeholder={@placeholder}
      data-mentions={@server.composer_mentions_json}
      data-commands={@server.composer_commands_json}
    >
      <div class="rounded-lg border border-base-300 bg-base-100 shadow-sm">
        <div
          :if={@server.reply_to_message}
          id={@ids.banner}
          class="flex items-center justify-between border-b border-base-300 bg-primary/10 px-3 py-2 text-xs text-primary"
        >
          <div class="min-w-0">
            Replying to
            <span class="font-semibold">{@server.reply_to_message.author.display_name}</span>
            <p class="truncate text-[11px] text-primary/70">
              {@server.reply_to_message.body}
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

        <div class="flex items-end gap-2 px-3 py-3">
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

              <p :if={!@server.can_mention_everyone?} class="m-0 text-[11px] text-amber-200">
                @everyone and locked roles need extra permission
              </p>
            </div>

            <div data-rich-composer-editor class="min-h-0" />

            <textarea data-rich-composer-body name={@form[:body].name} class="hidden">{@form[:body].value || ""}</textarea>
            <textarea data-rich-composer-metadata name={@form[:metadata].name} class="hidden"></textarea>
          </div>

          <div class="flex h-full shrink-0 flex-col items-center justify-end gap-2 pb-0.5">
            <button
              type="button"
              id={@ids.poll}
              phx-click="open_poll"
              aria-label="Create poll"
              title="Create poll"
              aria-expanded={to_string(not is_nil(@server.poll_form))}
              class="inline-flex size-8 items-center justify-center rounded-md border border-base-300 bg-base-200 text-base-content/70 transition hover:border-violet-400/50 hover:text-violet-300 aria-expanded:border-violet-400/60 aria-expanded:text-violet-300"
            >
              <.icon name="hero-chart-bar" class="size-4" />
            </button>

            <button
              type="button"
              aria-label="Upload attachments"
              title="Upload attachments"
              disabled
              class="inline-flex size-8 cursor-not-allowed items-center justify-center rounded-md border border-base-300 bg-base-200 text-base-content/50 opacity-70 pointer-events-none"
            >
              <.icon name="hero-paper-clip" class="size-4" />
            </button>

            <.button
              aria-label={@send_label}
              title={@send_label}
              id={@ids.send}
              class="inline-flex size-8 items-center justify-center rounded-md bg-violet-500 p-0 text-white transition hover:bg-violet-400"
            >
              <.icon name="hero-paper-airplane" class="size-4" />
            </.button>
          </div>
        </div>
      </div>
    </.form>
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

  defp composer_config(server, :channel) do
    %{
      form: server.message_form,
      submit: "send_message",
      placeholder: "Message channel",
      send_label: "Send message",
      ids: %{
        form: "message-form",
        banner: "replying-to-banner",
        shell: "rich-composer-shell",
        toolbar: "rich-composer-toolbar",
        send: "send-message-button",
        poll: "open-poll-button"
      }
    }
  end

  defp composer_config(server, :thread) do
    %{
      form: server.thread_message_form,
      submit: "send_thread_message",
      placeholder: "Reply in thread",
      send_label: "Send thread message",
      ids: %{
        form: "thread-message-form",
        banner: "thread-replying-to-banner",
        shell: "thread-rich-composer-shell",
        toolbar: "thread-rich-composer-toolbar",
        send: "send-thread-message-button",
        poll: "thread-open-poll-button"
      }
    }
  end
end
