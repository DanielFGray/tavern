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
            phx-click={channel.kind == :voice && "voice_join"}
            phx-value-channel-id={channel.kind == :voice && channel.id}
            class={[
              "group flex items-center gap-2 rounded-md px-2 py-1.5 text-sm font-medium transition",
              channel_active?(@server.active_channel, channel) &&
                "bg-base-100 text-base-content shadow-[inset_3px_0_0_color-mix(in_oklab,var(--color-primary)_32%,transparent)]",
              !channel_active?(@server.active_channel, channel) &&
                "text-base-content/70 hover:bg-base-100 hover:text-base-content"
            ]}
          >
            <span class="text-base font-semibold text-base-content/50 transition group-hover:text-base-content/80">
              {channel_icon(channel)}
            </span>
            <span class="min-w-0 flex-1 truncate">{channel.name}</span>
            <span
              :if={channel.kind == :voice and occupants_for(@server, channel) != []}
              id={"channel-voice-count-#{channel.slug}"}
              class="rounded bg-base-300 px-1.5 py-0.5 text-[10px] font-semibold text-base-content/60"
            >
              {length(occupants_for(@server, channel))}
            </span>
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
          <.voice_occupants :if={channel.kind == :voice} channel={channel} server={@server} />
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
          <span class={["min-w-0 flex-1 truncate", thread_title_class(entry.thread)]}>
            {thread_title(entry.thread)}
          </span>
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

  defp channel_icon(%{kind: :voice}), do: ""
  defp channel_icon(_channel), do: "#"

  defp occupants_for(server, channel), do: Map.get(server.voice_occupants, channel.id, [])

  attr :channel, :map, required: true
  attr :server, :map, required: true

  # Who sits in a voice channel: one small row per participant under the channel row. Names come
  # from the member presence list; a participant missing from it shows as "Member".
  def voice_occupants(assigns) do
    participants = occupants_for(assigns.server, assigns.channel)
    assigns = assign(assigns, :participants, participants)

    ~H"""
    <ul
      :if={@participants != []}
      id={"voice-occupants-#{@channel.slug}"}
      class="ml-6 mt-0.5 space-y-0.5 border-l border-base-300 pl-2"
    >
      <li
        :for={participant <- @participants}
        id={"voice-occupant-#{participant.user_id}"}
        class="flex items-center gap-1.5 rounded px-1 py-0.5 text-[12px] text-base-content/70"
      >
        <.avatar user={member_user(@server, participant.user_id)} class="size-4 text-[8px]" />
        <span class="min-w-0 truncate">{participant_name(@server, participant.user_id)}</span>
        <.icon
          :if={participant.muted}
          name="hero-signal-slash"
          class="size-3 shrink-0 text-rose-400"
        />
      </li>
    </ul>
    """
  end

  defp member_user(server, user_id) do
    Enum.find_value(server.member_presence, fn entry ->
      entry.user.id == user_id && entry.user
    end) || %{display_name: "Member", username: "member", id: user_id}
  end

  defp participant_name(server, user_id) do
    case member_user(server, user_id) do
      %{display_name: name} -> name
      _ -> "Member"
    end
  end

  attr :entry, :map, required: true

  def member_presence_item(assigns) do
    ~H"""
    <div
      id={"member-presence-#{@entry.user.id}"}
      class="rounded-md px-2 py-2 transition hover:bg-base-100"
    >
      <div class="flex items-start gap-3">
        <div
          class="relative mt-0.5 shrink-0 cursor-pointer"
          data-profile-user-id={@entry.user.id}
          tabindex="0"
          role="button"
          aria-label={"Profile of #{@entry.user.display_name}"}
        >
          <.avatar user={@entry.user} class="size-8 text-xs" />
          <span class={[
            "absolute -bottom-0.5 -right-0.5 size-2.5 rounded-full border-2 border-base-200",
            member_status_class(@entry.status)
          ]} />
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <p class="truncate text-[13px] font-medium text-base-content">
              <button
                type="button"
                data-profile-user-id={@entry.user.id}
                class="max-w-full truncate text-left hover:underline"
              >
                {@entry.user.display_name}
              </button>
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
