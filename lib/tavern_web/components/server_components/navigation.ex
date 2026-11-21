defmodule TavernWeb.ServerComponents.Navigation do
  @moduledoc false

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  attr :section, :map, required: true
  attr :server, :map, required: true
  attr :show_label, :boolean, default: true

  def channel_nav_section(assigns) do
    ~H"""
    <section id={section_dom_id(@section.category)}>
      <div :if={@show_label} class="mb-1 flex items-center gap-2 px-2">
        <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
          {section_label(@section.category)}
        </p>
        <span class="rounded bg-base-300 px-1.5 py-0.5 text-[10px] font-semibold text-base-content/60">
          {length(@section.channels)}
        </span>
      </div>

      <div class="space-y-0.5">
        <div :for={channel <- @section.channels}>
          <.link
            id={"channel-link-#{channel.slug}"}
            patch={channel_path(channel)}
            class={[
              "group flex items-center gap-2 rounded-md px-2 py-1.5 text-sm font-medium transition",
              channel_active?(@server.active_channel, channel) &&
                "bg-base-100 text-base-content shadow-[inset_3px_0_0_color-mix(in_oklab,var(--color-primary)_32%,transparent)]",
              !channel_active?(@server.active_channel, channel) &&
                "text-base-content/70 hover:bg-base-100 hover:text-base-content"
            ]}
          >
            <span class="text-base font-semibold text-base-content/50 transition group-hover:text-base-content/80">
              #
            </span>
            <span class="min-w-0 flex-1 truncate">{channel.name}</span>
            <span
              :if={unread_count_for(channel, @server.unread_counts) > 0}
              id={"channel-unread-#{channel.slug}"}
              class="rounded-full bg-violet-500/90 px-1.5 py-0.5 text-[10px] font-bold text-white"
            >
              {unread_count_for(channel, @server.unread_counts)}
            </span>
            <span
              :if={unread_mentions_for(channel, @server.unread_mentions) > 0}
              id={"channel-mention-#{channel.slug}"}
              class="flex size-5 items-center justify-center rounded-full bg-rose-500 text-[10px] font-black text-white shadow-[0_0_0_2px_var(--color-base-200)]"
              title="Unread mentions"
            >
              @
            </span>
          </.link>
          <.followed_threads channel={channel} server={@server} />
        </div>
      </div>
    </section>
    """
  end

  @sidebar_thread_limit 5

  attr :channel, :map, required: true
  attr :server, :map, required: true

  # The followed threads under one channel: newest activity first, at most @sidebar_thread_limit,
  # with the rest behind a button that opens the thread browser.
  defp followed_threads(assigns) do
    threads =
      Enum.filter(
        assigns.server.followed_threads,
        &(&1.thread.parent_channel_id == assigns.channel.id)
      )

    {shown, hidden} = Enum.split(threads, @sidebar_thread_limit)
    assigns = assign(assigns, shown: shown, hidden_count: length(hidden))

    ~H"""
    <ul
      :if={@shown != []}
      id={"sidebar-threads-#{@channel.slug}"}
      class="ml-4 mt-0.5 space-y-0.5 border-l border-base-300 pl-2"
    >
      <li :for={entry <- @shown}>
        <.link
          id={"sidebar-thread-#{entry.thread.id}"}
          patch={thread_path(@channel, entry.thread)}
          class={[
            "group flex items-center gap-2 rounded-md px-2 py-1 text-[13px] transition",
            thread_active?(@server.active_thread, entry.thread) &&
              "bg-base-100 font-semibold text-base-content",
            !thread_active?(@server.active_thread, entry.thread) && entry.unread_count > 0 &&
              "font-semibold text-base-content hover:bg-base-100",
            !thread_active?(@server.active_thread, entry.thread) && entry.unread_count == 0 &&
              "text-base-content/60 hover:bg-base-100 hover:text-base-content"
          ]}
        >
          <.icon
            name="hero-chat-bubble-left-right"
            class="size-3.5 shrink-0 text-base-content/40 transition group-hover:text-base-content/70"
          />
          <span class="min-w-0 flex-1 truncate">{thread_title(entry.thread)}</span>
          <span
            :if={entry.unread_count > 0}
            id={"sidebar-thread-unread-#{entry.thread.id}"}
            class="rounded-full bg-violet-500/90 px-1.5 py-0.5 text-[10px] font-bold text-white"
          >
            {entry.unread_count}
          </span>
        </.link>
      </li>
      <li :if={@hidden_count > 0}>
        <button
          type="button"
          id={"sidebar-threads-more-#{@channel.slug}"}
          phx-click="open_thread_browser"
          phx-value-channel-id={@channel.id}
          class="w-full rounded-md px-2 py-1 text-left text-[11px] font-semibold text-base-content/55 transition hover:bg-base-100 hover:text-base-content"
        >
          {@hidden_count} more
        </button>
      </li>
    </ul>
    """
  end

  defp thread_active?(%{id: id}, %{id: id}), do: true
  defp thread_active?(_active, _thread), do: false

  attr :entry, :map, required: true

  def member_presence_item(assigns) do
    ~H"""
    <div
      id={"member-presence-#{@entry.user.id}"}
      class="rounded-md px-2 py-2 transition hover:bg-base-100"
    >
      <div class="flex items-start gap-3">
        <div class="relative mt-0.5 shrink-0">
          <div class="flex size-8 items-center justify-center rounded-full bg-base-300 text-xs font-semibold text-base-content">
            {@entry.user.display_name |> String.first()}
          </div>
          <span class={[
            "absolute -bottom-0.5 -right-0.5 size-2.5 rounded-full border-2 border-base-200",
            member_status_class(@entry.status)
          ]} />
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <p class="truncate text-[13px] font-medium text-base-content">
              {@entry.user.display_name}
            </p>
            <span
              :if={@entry.user.membership.is_owner}
              class="rounded bg-emerald-500/15 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em] text-emerald-200"
            >
              owner
            </span>
            <span
              :if={@entry.unverified?}
              id={"member-unverified-#{@entry.user.id}"}
              title="This member has not confirmed their email"
              class="rounded bg-amber-500/15 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em] text-amber-600 dark:text-amber-300"
            >
              unverified
            </span>
          </div>

          <p class="mt-0.5 truncate text-[11px] text-base-content/50">@{@entry.user.username}</p>
          <p class="mt-1 text-[11px] text-base-content/65">
            {member_status_label(@entry.status)} · {Calendar.strftime(
              @entry.last_active_at,
              "%b %-d · %H:%M"
            )}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
