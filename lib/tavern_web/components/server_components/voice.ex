defmodule TavernWeb.ServerComponents.Voice do
  @moduledoc """
  The voice room view: tiles for everyone in the room, the join card when this tab is not in
  it, and the call bar that keeps the call in the sidebar while the reader is elsewhere
  (docs/design/voice.md). The `.VoiceSession` hook owns the media; the tiles carry
  `data-voice-*` attributes the hook reads and writes.
  """

  use TavernWeb, :html

  attr :server, :map, required: true

  # A voice channel's pane is the room beside its own text chat (docs/design/voice.md): the
  # grid on the left, the channel's transcript on the right with the one composer under it.
  def active_voice_view(assigns) do
    channel = assigns.server.active_channel
    in_room? = voice_channel_id(assigns.server) == channel.id

    participants =
      if in_room?,
        do: assigns.server.voice_participants,
        else: occupants(assigns.server, channel.id)

    assigns =
      assigns
      |> assign(:channel, channel)
      |> assign(:in_room?, in_room?)
      |> assign(:room_participants, participants)

    ~H"""
    <div id="voice-room" class="flex min-h-0 flex-1">
      <div class="flex min-w-0 flex-1 flex-col items-center justify-center gap-6 overflow-y-auto p-6">
        <div class="flex flex-col items-center gap-2 text-center">
          <.icon name="hero-speaker-wave" class="size-8 text-base-content/40" />
          <h2 class="text-lg font-semibold">{@channel.name}</h2>
          <p class="text-sm text-base-content/60">
            {length(@room_participants)} of {@channel.voice_member_limit} in voice
          </p>
        </div>

        <%= if @server.voice_configured? do %>
          <%= if @in_room? do %>
            <.voice_grid server={@server} participants={@room_participants} />
            <.voice_controls server={@server} />
          <% else %>
            <.join_card server={@server} channel={@channel} participants={@room_participants} />
          <% end %>
        <% else %>
          <div
            id="voice-not-configured"
            class="rounded-lg border border-dashed border-base-300 bg-base-100 p-6 text-center"
          >
            <p class="text-sm font-semibold">Voice not configured</p>
            <p class="mt-1 max-w-xs text-xs text-base-content/60">
              This server has no Realtime app credentials set, so nobody can join voice channels yet.
            </p>
          </div>
        <% end %>
      </div>

      <aside
        id="voice-chat"
        class="relative hidden w-[var(--panel-voice-chat-w,24rem)] min-w-64 max-w-[min(40rem,45vw)] shrink-0 flex-col border-l border-base-300 bg-base-200 lg:flex"
      >
        <p class="border-b border-base-300 px-4 py-2 text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
          #{@channel.name} chat
        </p>
        <TavernWeb.ServerComponents.Messages.message_stream server={@server} />
        <TavernWeb.ServerComponents.Composer.composer_dock server={@server} />
        <TavernWeb.ServerComponents.PanelResize.resize_handle
          name="voice-chat"
          panel="voice-chat"
          edge="left"
          label="Resize voice channel chat"
        />
      </aside>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :channel, :map, required: true
  attr :participants, :list, required: true

  defp join_card(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-4">
      <div class="flex flex-wrap justify-center gap-2">
        <span
          :for={participant <- @participants}
          id={"voice-join-occupant-#{participant.user_id}"}
          class="flex items-center gap-1.5 rounded-full bg-base-100 px-2 py-1 text-xs"
        >
          <.avatar user={member(@server, participant.user_id)} class="size-5 text-[9px]" />
          {participant_name(@server, participant.user_id)}
        </span>
      </div>

      <button
        type="button"
        id="voice-join-button"
        phx-click="voice_join"
        phx-value-channel-id={@channel.id}
        class="rounded-lg bg-emerald-500 px-6 py-2.5 text-sm font-semibold text-white shadow transition hover:bg-emerald-400 active:scale-[0.98]"
      >
        Join voice
      </button>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :participants, :list, required: true

  defp voice_grid(assigns) do
    ~H"""
    <div class="grid w-full max-w-2xl grid-cols-2 gap-3 sm:grid-cols-3">
      <.voice_tile
        :for={participant <- @participants}
        server={@server}
        participant={participant}
        speaking={MapSet.member?(@server.voice_speaking, participant.user_id)}
        has_video?={participant.tracks[:camera] != nil or participant.tracks[:screen] != nil}
      />
    </div>
    """
  end

  attr :server, :map, required: true
  attr :participant, :map, required: true
  attr :speaking, :boolean, required: true
  attr :has_video?, :boolean, required: true

  # The tile is what the hook touches: `data-voice-speaking` marks the ring, and the tile is
  # where received audio elements get attached.
  defp voice_tile(assigns) do
    ~H"""
    <div
      id={"voice-tile-#{@participant.user_id}"}
      data-voice-tile
      data-user-id={@participant.user_id}
      data-voice-speaking={to_string(@speaking)}
      class={[
        "relative flex flex-col items-center gap-2 rounded-xl border bg-base-100 p-3 transition",
        @speaking &&
          "border-emerald-400/70 shadow-[0_0_0_2px_color-mix(in_oklab,var(--color-success)_30%,transparent)]",
        !@speaking && "border-base-300"
      ]}
    >
      <div
        :if={@has_video?}
        class="w-full aspect-video overflow-hidden rounded-lg bg-black"
        data-voice-video
      />
      <%= if !@has_video? do %>
        <.avatar user={member(@server, @participant.user_id)} class="size-12 text-sm" />
      <% end %>
      <span class="max-w-full truncate text-xs font-semibold">
        {participant_name(@server, @participant.user_id)}
        <%= if @participant.user_id == @server.current_user.id do %>
          (you)
        <% end %>
      </span>
      <span
        :if={@participant.muted}
        class="absolute right-2 top-2 rounded bg-base-300 px-1 py-0.5 text-[10px] font-bold text-base-content/70"
        title="Muted"
      >
        <.icon name="hero-signal-slash" class="size-3.5" />
      </span>
    </div>
    """
  end

  attr :server, :map, required: true

  defp voice_controls(assigns) do
    record = assigns.server.voice_record
    muted = record && record.muted
    camera_live? = record && record.tracks[:camera] != nil
    screen_live? = record && record.tracks[:screen] != nil

    assigns =
      assigns
      |> assign(:muted, muted)
      |> assign(:camera_live?, camera_live?)
      |> assign(:screen_live?, screen_live?)

    ~H"""
    <div class="flex items-center gap-3">
      <button
        type="button"
        id="voice-mic-toggle"
        phx-click="voice_mute_toggle"
        phx-value-muted={to_string(!@muted)}
        aria-pressed={to_string(@muted)}
        class={[
          "flex items-center gap-2 rounded-lg px-4 py-2.5 text-sm font-semibold shadow transition active:scale-[0.98]",
          @muted && "bg-rose-500 text-white hover:bg-rose-400",
          !@muted && "bg-base-100 text-base-content hover:bg-base-100/70"
        ]}
      >
        <.icon name={if @muted, do: "hero-signal-slash", else: "hero-microphone"} class="size-5" />
        {if @muted, do: "Unmute", else: "Mute"}
      </button>

      <button
        type="button"
        id="voice-camera-toggle"
        phx-click="voice_toggle_video"
        phx-value-kind="camera"
        aria-pressed={to_string(@camera_live?)}
        title={if @camera_live?, do: "Stop camera", else: "Start camera"}
        class={[
          "rounded-lg px-3 py-2.5 text-sm font-semibold shadow transition active:scale-[0.98]",
          @camera_live? && "bg-sky-500 text-white hover:bg-sky-400",
          !@camera_live? && "bg-base-100 text-base-content hover:bg-base-100/70"
        ]}
      >
        <.icon
          name={if @camera_live?, do: "hero-video-camera-slash", else: "hero-video-camera"}
          class="size-5"
        />
      </button>

      <button
        type="button"
        id="voice-screen-toggle"
        phx-click="voice_toggle_video"
        phx-value-kind="screen"
        aria-pressed={to_string(@screen_live?)}
        title={if @screen_live?, do: "Stop sharing", else: "Share screen"}
        class={[
          "rounded-lg px-3 py-2.5 text-sm font-semibold shadow transition active:scale-[0.98]",
          @screen_live? && "bg-violet-500 text-white hover:bg-violet-400",
          !@screen_live? && "bg-base-100 text-base-content hover:bg-base-100/70"
        ]}
      >
        <.icon name="hero-computer-desktop" class="size-5" />
      </button>

      <button
        type="button"
        id="voice-leave-button"
        phx-click="voice_leave"
        class="rounded-lg bg-rose-600 px-4 py-2.5 text-sm font-semibold text-white shadow transition hover:bg-rose-500 active:scale-[0.98]"
      >
        Leave
      </button>
    </div>
    """
  end

  attr :server, :map, required: true

  # The call bar lives in the channel drawer, above the member's own card, whenever this tab is
  # in a voice room and is reading another channel.
  def call_bar(assigns) do
    server = assigns.server

    assigns =
      assigns
      |> assign(:call_channel, server.voice_channel)
      |> assign(:show?, server.voice_channel != nil)
      |> assign(:muted, server.voice_record && server.voice_record.muted)
      |> assign(
        :sharing_screen?,
        server.voice_record && server.voice_record.tracks[:screen] != nil
      )

    ~H"""
    <div
      :if={@show?}
      id="voice-call-bar"
      class="border-t border-base-300 bg-base-100 px-3 py-2"
    >
      <div class="flex items-center gap-2">
        <span class="relative flex size-2 shrink-0">
          <span class="absolute inline-flex size-2 animate-ping rounded-full bg-emerald-400 opacity-60" />
          <span class="relative inline-flex size-2 rounded-full bg-emerald-400" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="truncate text-[12px] font-semibold">{@call_channel.name}</p>
          <p class="truncate text-[10px] text-base-content/55">
            <%= if @sharing_screen? do %>
              sharing screen · {length(occupants(@server, @call_channel.id))} in voice
            <% else %>
              {length(occupants(@server, @call_channel.id))} in voice
            <% end %>
          </p>
        </div>
        <button
          type="button"
          id="call-bar-mic"
          phx-click="voice_mute_toggle"
          phx-value-muted={to_string(!@muted)}
          title={if @muted, do: "Unmute", else: "Mute"}
          class={[
            "rounded-md px-2 py-1.5 transition",
            @muted && "bg-rose-500/15 text-rose-400",
            !@muted && "text-base-content/70 hover:bg-base-200"
          ]}
        >
          <.icon name={if @muted, do: "hero-signal-slash", else: "hero-microphone"} class="size-4" />
        </button>
        <button
          type="button"
          id="call-bar-leave"
          phx-click="voice_leave"
          title="Leave call"
          class="rounded-md bg-rose-600 px-2 py-1.5 text-white transition hover:bg-rose-500"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp voice_channel_id(server) do
    case server.voice_channel do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp occupants(server, channel_id), do: Map.get(server.voice_occupants, channel_id, [])

  defp member(server, user_id) do
    Enum.find_value(server.member_presence, fn entry ->
      entry.user.id == user_id && entry.user
    end) || %{display_name: "Member", username: "member", id: user_id}
  end

  # A participant whose account row is not in the presence list (edge case on a busy server)
  # shows as "Member" rather than crashing the sidebar.
  defp participant_name(server, user_id) do
    case member(server, user_id) do
      %{display_name: name} -> name
      _ -> "Member"
    end
  end
end
