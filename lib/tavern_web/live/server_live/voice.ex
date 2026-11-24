defmodule TavernWeb.ServerLive.Voice do
  @moduledoc """
  Voice rooms on the server page (docs/design/voice.md).

  One ServerLive process mediates one browser tab's part of the call: it authorizes, holds the
  tab's participant record (`Tavern.Voice`), calls `Tavern.Voice.Cloudflare` for the tab's two
  SFU sessions, and relays every SDP exchange to the `.VoiceSession` hook. All of the tab's own
  exchanges arrive at this process, so each session's negotiation serializes naturally.

  Subscribes run in passes: one batched `tracks/new` on the receive session, the SFU offer to
  the browser, its answer back to `renegotiate`. Publications that arrive mid-exchange wait for
  the next pass, so a session never has two mutations in flight.

  The participant keeps publishing while the reader browses other channels; leaving the page or
  closing the tab runs `terminate/3`, which leaves the room and force-closes the SFU tracks.
  """

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3]

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Voice
  alias Tavern.Voice.Cloudflare

  require Logger

  @heartbeat_interval_ms 30_000
  @publish_kinds ~w(mic camera screen)
  @video_kinds ~w(camera screen)
  @rids ~w(f h q)

  @kind_atoms %{"mic" => :mic, "camera" => :camera, "screen" => :screen}

  @events ~w(voice_join voice_leave voice_mute_toggle voice_toggle_video voice_publish voice_unpublish voice_sf_offer_answer voice_speaking voice_permission_denied voice_client_error)

  def events, do: @events

  # --- Mount and hydration ---------------------------------------------------------------------

  def init(socket) do
    socket
    |> assign(:voice_channel, nil)
    |> assign(:voice_record, nil)
    |> assign(:voice_participants, [])
    |> assign(:voice_occupants, %{})
    |> assign(:voice_subscriptions, MapSet.new())
    |> assign(:voice_recv_session_id, nil)
    |> assign(:voice_negotiating?, false)
    |> assign(:voice_speaking, MapSet.new())
    |> assign(:voice_configured?, Cloudflare.configured?())
  end

  @doc "Reads the room of every listed voice channel for the sidebar's occupant lists."
  def refresh_occupants(socket) do
    occupants =
      socket.assigns.channels
      |> Enum.filter(&(&1.kind == :voice))
      |> Map.new(fn channel ->
        # `participants/1` answers the bare list, or an error when Valkey is down.
        {channel.id,
         case Voice.participants(channel.id) do
           list when is_list(list) -> list
           _ -> []
         end}
      end)

    assign(socket, :voice_occupants, occupants)
  end

  @doc """
  The reader left the page or the tab closed: leave the room and force-close this tab's SFU
  tracks, best effort. A crashed process is cleaned up by the record's expiry instead.
  """
  def terminate(_reason, socket) do
    case socket.assigns[:voice_record] do
      %{} = record -> leave_and_close(socket, record)
      _ -> :ok
    end

    :ok
  end

  # --- Client events ---------------------------------------------------------------------------

  def handle_event("voice_join", %{"channel-id" => channel_id}, socket) do
    # Already in this room; a second click just navigates.
    if socket.assigns.voice_channel && socket.assigns.voice_channel.id == channel_id do
      {:noreply, socket}
    else
      {:noreply, join_channel(channel_id, socket)}
    end
  end

  def handle_event("voice_leave", _params, socket), do: {:noreply, teardown(socket)}

  # The controls ask before the browser captures: this decides the ability (`:stream_voice`)
  # and answers with what the member is publishing now, so the click means on or off.
  def handle_event("voice_toggle_video", %{"kind" => kind}, socket) when kind in @video_kinds do
    with %Scope{} = scope <- socket.assigns.current_scope,
         %{} = channel <- socket.assigns.voice_channel,
         true <- Visibility.can?(scope, :stream_voice, channel) || {:error, :forbidden},
         %{tracks: tracks} = record when is_map(record) <- socket.assigns.voice_record do
      {:noreply,
       push_event(socket, "voice_video_request", %{
         kind: kind,
         active: tracks[String.to_existing_atom(kind)] != nil
       })}
    else
      {:error, :forbidden} -> {:noreply, put_flash(socket, :error, "You cannot stream here.")}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("voice_toggle_video", _params, socket), do: {:noreply, socket}

  # The browser's capture or publish step failed. Only the browser sees that error, so the log
  # line is the one place it can be read after the fact.
  def handle_event(
        "voice_client_error",
        %{"step" => step, "kind" => kind, "error" => error},
        socket
      )
      when step in ~w(capture publish) and kind in @publish_kinds and is_binary(error) do
    Logger.warning(
      "voice: browser #{step} of #{kind} failed: #{inspect(String.slice(error, 0, 300))}"
    )

    {:noreply, socket}
  end

  def handle_event("voice_client_error", _params, socket), do: {:noreply, socket}

  def handle_event("voice_permission_denied", _params, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Microphone access was refused.")
     |> teardown()}
  end

  # Muting yourself is always allowed; speaking again needs `:speak_voice` (the design's gate
  # table puts "publish mic / unmute" under it), so a revoked speaker cannot come back.
  def handle_event("voice_mute_toggle", %{"muted" => muted}, socket) do
    with %{user_id: user_id, token: token} = record when is_map(record) <-
           socket.assigns.voice_record,
         true <-
           (truthy?(muted) or
              Visibility.can?(
                socket.assigns.current_scope,
                :speak_voice,
                socket.assigns.voice_channel
              )) ||
             {:error, :forbidden},
         {:ok, record} <-
           Voice.set_muted(room_channel_id(socket), user_id, token, truthy?(muted)) do
      {:noreply,
       socket
       |> update_room_record(record)
       |> push_event("voice_mic_state", %{muted: truthy?(muted)})}
    else
      {:error, :forbidden} -> {:noreply, put_flash(socket, :error, "You cannot speak here.")}
      _ -> {:noreply, socket}
    end
  end

  # The browser captured a track and holds a gathered offer. One publish session carries every
  # kind: camera and screen add transceivers to it and send only their own entries. The SFU's
  # answer is the reply, so the hook applies it before it offers the next kind.
  def handle_event("voice_publish", %{"kind" => kind} = params, socket)
      when kind in @publish_kinds do
    with %Scope{} = scope <- socket.assigns.current_scope,
         %{} = channel <- socket.assigns.voice_channel,
         true <-
           publish_allowed?(scope, channel, Map.fetch!(@kind_atoms, kind)) || {:error, :forbidden},
         {:ok, session_id} <- ensure_publish_session(socket),
         {:ok, mids, answer} <- publish_tracks(session_id, params) do
      socket = update(socket, :voice_record, &%{&1 | publish_session_id: session_id})
      track = %{"trackName" => kind, "sessionId" => session_id, "mids" => mids}
      rids = if kind in @video_kinds, do: @rids, else: nil

      socket =
        case Voice.publish_track(
               room_channel_id(socket),
               socket.assigns.voice_record.user_id,
               socket.assigns.voice_record.token,
               Map.fetch!(@kind_atoms, kind),
               track,
               rids
             ) do
          {:ok, record} -> update_room_record(socket, record)
          _ -> socket
        end

      {:reply, %{session_description: answer["sessionDescription"]}, socket}
    else
      {:error, :forbidden} -> {:noreply, put_flash(socket, :error, "You cannot stream here.")}
      {:error, {:track, results}} -> track_refusal(socket, results)
      {:error, reason} -> voice_failed(socket, "publish", reason)
    end
  end

  def handle_event("voice_publish", _params, socket), do: {:noreply, socket}

  def handle_event("voice_unpublish", %{"kind" => kind}, socket) when kind in @video_kinds do
    with %{tracks: tracks} = record when is_map(record) <- socket.assigns.voice_record,
         track when track != nil <- tracks[Map.fetch!(@kind_atoms, kind)] do
      close_tracks(track["sessionId"], track["mids"])

      socket =
        case Voice.publish_track(
               room_channel_id(socket),
               record.user_id,
               record.token,
               Map.fetch!(@kind_atoms, kind),
               nil,
               nil
             ) do
          {:ok, record} -> update_room_record(socket, record)
          _ -> socket
        end

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("voice_unpublish", _params, socket), do: {:noreply, socket}

  # The browser answered an SFU offer. This ends one subscribe exchange; the next pass picks up
  # anything published meanwhile.
  def handle_event("voice_sf_offer_answer", %{"sdp" => sdp}, socket) do
    socket =
      if socket.assigns.voice_recv_session_id && socket.assigns.voice_negotiating? do
        session_id = socket.assigns.voice_recv_session_id

        case Cloudflare.renegotiate(session_id, sdp) do
          {:ok, _} -> :ok
          {:error, reason} -> log_failed("renegotiate", reason)
        end

        assign(socket, :voice_negotiating?, false)
      else
        socket
      end

    send(self(), :voice_subscribe_pass)
    {:noreply, socket}
  end

  def handle_event("voice_speaking", %{"speaking" => speaking}, socket) do
    case socket.assigns.voice_record do
      # A muted member's analyser can still see their mic; the flag is the source of truth.
      %{muted: false, user_id: user_id} = record when is_map(record) ->
        Topics.broadcast_channel(
          room_channel_id(socket),
          {:voice_speaking, room_channel_id(socket), user_id, truthy?(speaking)}
        )

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # A join into another room leaves it (its seat and its SFU tracks) before taking the new one.
  defp join_channel(channel_id, %{assigns: %{voice_channel: %{}}} = socket),
    do: join_channel(channel_id, teardown(socket))

  # Answers the socket: the callers wrap it in {:noreply, ...}.
  defp join_channel(channel_id, socket) do
    with %Scope{} = scope <- socket.assigns.current_scope,
         %{} = channel <- Visibility.visible_channel(scope, channel_id),
         true <- Visibility.can?(scope, :connect_voice, channel) || {:error, :forbidden},
         {:ok, record, participants} <- Voice.join(channel, socket.assigns.current_user) do
      socket =
        socket
        |> assign(:voice_channel, channel)
        |> assign(:voice_record, record)
        |> reset_room_state(participants)
        |> refresh_occupants()

      Process.send_after(self(), :voice_heartbeat, @heartbeat_interval_ms)

      push_event(socket, "voice_ready", %{
        ice_servers: Cloudflare.turn_ice_servers(),
        user_id: socket.assigns.current_user.id
      })
    else
      {:error, :room_full} -> put_flash(socket, :error, "This voice channel is full.")
      {:error, :unconfigured} -> put_flash(socket, :error, "Voice is not configured.")
      {:error, :unavailable} -> put_flash(socket, :error, "Voice is unavailable right now.")
      {:error, :forbidden} -> put_flash(socket, :error, "You cannot join this channel.")
      _ -> put_flash(socket, :error, "That channel does not exist.")
    end
  end

  # --- Room and PubSub messages ----------------------------------------------------------------

  def handle_info(:voice_heartbeat, socket) do
    case socket.assigns.voice_record do
      %{user_id: user_id, token: token} ->
        case Voice.heartbeat(room_channel_id(socket), user_id, token) do
          :ok -> :ok
          {:error, reason} -> log_failed("heartbeat", reason)
        end

        Process.send_after(self(), :voice_heartbeat, @heartbeat_interval_ms)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(:voice_subscribe_pass, socket), do: {:noreply, subscribe_pass(socket)}

  def handle_info({:voice_joined, channel_id, participants}, socket) do
    socket = update_occupants(socket, channel_id, participants)

    socket =
      if own_room?(socket, channel_id) do
        socket
        |> assign(:voice_participants, participants)
        |> replaced_elsewhere()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:voice_left, channel_id, participants}, socket) do
    socket = update_occupants(socket, channel_id, participants)

    socket =
      if own_room?(socket, channel_id),
        do: assign(socket, :voice_participants, participants),
        else: socket

    {:noreply, socket}
  end

  def handle_info({:voice_published, channel_id, record}, socket) do
    if own_room?(socket, channel_id) do
      socket = update_room_record(socket, record)
      send(self(), :voice_subscribe_pass)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:voice_updated, channel_id, record}, socket) do
    if own_room?(socket, channel_id) do
      {:noreply, update_room_record(socket, record)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:voice_moderated, channel_id, subject_id, action}, socket) do
    record = socket.assigns.voice_record

    cond do
      own_room?(socket, channel_id) && record && record.user_id == subject_id && action == :mute ->
        {:noreply,
         socket
         |> assign(:voice_record, %{record | muted: true})
         |> push_event("voice_moderated_mute", %{})}

      own_room?(socket, channel_id) && record && record.user_id == subject_id &&
          action == :disconnect ->
        {:noreply, teardown(socket)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:voice_speaking, channel_id, user_id, speaking?}, socket) do
    if own_room?(socket, channel_id) do
      speaking =
        if speaking?,
          do: MapSet.put(socket.assigns.voice_speaking, user_id),
          else: MapSet.delete(socket.assigns.voice_speaking, user_id)

      {:noreply, assign(socket, :voice_speaking, speaking)}
    else
      {:noreply, socket}
    end
  end

  # --- Subscribe flow --------------------------------------------------------------------------

  # Requests every publication this tab does not receive yet, in one batch on the receive
  # session, and hands the SFU offer to the browser with its mid-to-publisher mapping.
  defp subscribe_pass(socket) do
    case socket.assigns.voice_record do
      %{} = record when socket.assigns.voice_channel != nil ->
        socket = forget_stale_subscriptions(socket)

        cond do
          missing_publications(socket, record) == [] -> socket
          socket.assigns.voice_negotiating? -> socket
          true -> request_subscriptions(socket, record)
        end

      _ ->
        socket
    end
  end

  # A publication the publisher stopped or replaced keeps no seat: forget its key, so a camera
  # restarted on the same session and track name is requested again.
  defp forget_stale_subscriptions(socket) do
    live_keys =
      MapSet.new(
        for participant <- socket.assigns.voice_participants,
            {_kind, track} <- participant.tracks,
            track != nil,
            do: publication_key(track)
      )

    update(socket, :voice_subscriptions, &MapSet.intersection(&1, live_keys))
  end

  defp missing_publications(socket, record) do
    for participant <- socket.assigns.voice_participants,
        participant.user_id != record.user_id,
        {_kind, track} <- participant.tracks,
        track != nil,
        not MapSet.member?(socket.assigns.voice_subscriptions, publication_key(track)) do
      {participant, track}
    end
  end

  defp request_subscriptions(socket, record) do
    wanted = missing_publications(socket, record)

    with {:ok, session_id} <- ensure_recv_session(socket, record),
         {:ok, %{"sessionDescription" => description} = result} <-
           Cloudflare.new_tracks(session_id, %{"tracks" => Enum.map(wanted, &remote_entry/1)}),
         mapping when mapping != [] <- subscription_mapping(wanted, result) do
      socket =
        socket
        |> assign(:voice_recv_session_id, session_id)
        |> assign(
          :voice_subscriptions,
          MapSet.union(
            socket.assigns.voice_subscriptions,
            MapSet.new(Enum.map(mapping, &publication_key(&1)))
          )
        )
        |> assign(:voice_negotiating?, true)

      push_event(socket, "voice_sf_offer", %{session_description: description, mapping: mapping})
    else
      {:error, reason} ->
        log_failed("subscribe", reason)
        socket

      # Nothing in the batch succeeded: the next room event schedules another pass.
      _ ->
        socket
    end
  end

  defp remote_entry({_participant, track}) do
    entry = %{
      "location" => "remote",
      "sessionId" => track["sessionId"],
      "trackName" => track["trackName"]
    }

    # The publisher advertises the layers; a video subscriber asks for the best layer with
    # alphabetical fallback (docs/design/voice.md).
    if track["rids"] != nil and track["rids"] != [] do
      Map.put(entry, "simulcast", %{
        "preferredRid" => "f",
        "priorityOrdering" => "asciibetical",
        "ridNotAvailable" => "asciibetical"
      })
    else
      entry
    end
  end

  # The response lists one result per requested track, each with its receiving mid on success or
  # an errorCode. Only successful entries go to the browser; failed ones retry on the next pass.
  defp subscription_mapping(wanted, result) do
    results = result["tracks"] || []

    for {result, {participant, track}} <- Enum.zip(results, wanted),
        is_nil(result["errorCode"]),
        mid = result["mid"] do
      %{
        "mid" => mid,
        "sessionId" => track["sessionId"],
        "trackName" => track["trackName"],
        "kind" => track["trackName"],
        "userId" => participant.user_id
      }
    end
  end

  # --- Leaving and session cleanup -------------------------------------------------------------

  defp teardown(socket) do
    case socket.assigns.voice_record do
      %{} = record ->
        leave_and_close(socket, record)
        push_event(socket, "voice_ended", %{})

      _ ->
        socket
    end
    |> assign(:voice_channel, nil)
    |> assign(:voice_record, nil)
    |> reset_room_state([])
    |> refresh_occupants()
  end

  # The assigns every room state change resets: the participants list is the only part that
  # differs between a fresh join and a cleared tab.
  defp reset_room_state(socket, participants) do
    socket
    |> assign(:voice_participants, participants)
    |> assign(:voice_subscriptions, MapSet.new())
    |> assign(:voice_recv_session_id, nil)
    |> assign(:voice_negotiating?, false)
    |> assign(:voice_speaking, MapSet.new())
  end

  defp leave_and_close(socket, record) do
    # The leave is token-guarded in Valkey: a replaced tab's terminate answers
    # `:not_connected` and deletes nothing that belongs to its replacement.
    case Voice.leave(room_channel_id(socket), record.user_id, record.token) do
      {:ok, _participants} -> :ok
      {:error, reason} -> log_failed("leave", reason)
    end

    for {_kind, track} <- record.tracks, track != nil do
      close_tracks(track["sessionId"], track["mids"])
    end

    :ok
  end

  # Force-closes published tracks without negotiation (connection patterns, "Stop forwarding
  # without negotiation"). An SFU session with no live tracks is discarded by Cloudflare's own
  # lifetime rules, so nothing is sent for the sessions themselves.
  defp close_tracks(_session_id, nil), do: :ok
  defp close_tracks(_session_id, []), do: :ok

  defp close_tracks(session_id, mids) do
    case Cloudflare.close_tracks(session_id, Enum.map(mids, &%{"mid" => &1})) do
      {:ok, _} -> :ok
      {:error, reason} -> log_failed("close_tracks", reason)
    end
  end

  # A second tab took this member's seat: this tab's record is gone, so it keeps only its own
  # SFU sessions to close and hands the call over.
  defp replaced_elsewhere(socket) do
    record = socket.assigns.voice_record
    own = Enum.find(socket.assigns.voice_participants, &(&1.user_id == record.user_id))

    cond do
      is_nil(own) ->
        # Pruned as stale; nothing to hand over.
        socket

      own.token != record.token ->
        for {_kind, track} <- record.tracks, track != nil do
          close_tracks(track["sessionId"], track["mids"])
        end

        socket
        |> push_event("voice_replaced", %{})
        |> assign(:voice_channel, nil)
        |> assign(:voice_record, nil)
        |> reset_room_state([])

      true ->
        socket
    end
  end

  # --- Helpers ---------------------------------------------------------------------------------

  defp publish_allowed?(scope, channel, :mic), do: Visibility.can?(scope, :speak_voice, channel)

  defp publish_allowed?(scope, channel, kind) when kind in [:camera, :screen],
    do: Visibility.can?(scope, :stream_voice, channel)

  # Every per-track result must have succeeded; a partial failure leaves the tab and the SFU
  # session disagreeing, so the whole publish is refused and the browser retries.
  defp publish_tracks(session_id, params) do
    mids = for(mid <- params["mids"] || [], mid = mid["mid"], do: mid)

    entries =
      Enum.map(mids, fn mid ->
        %{"location" => "local", "mid" => mid, "trackName" => params["kind"]}
      end)

    case Cloudflare.new_tracks(session_id, %{
           "sessionDescription" => %{"type" => "offer", "sdp" => params["sdp"]},
           "tracks" => entries
         }) do
      {:ok, %{"tracks" => results} = body} when is_list(results) ->
        if Enum.all?(results, &is_nil(&1["errorCode"])) do
          {:ok, Enum.map(results, & &1["mid"]), body}
        else
          {:error, {:track, results}}
        end

      {:ok, body} ->
        {:ok, [], body}

      {:error, _} = error ->
        error
    end
  end

  defp track_refusal(socket, results) do
    Logger.warning("voice: publish rejected per track: #{inspect(results)}")
    {:noreply, put_flash(socket, :error, "Voice media could not start.")}
  end

  defp voice_failed(socket, step, {:status, status, _body}) do
    Logger.warning("voice: #{step} failed with status #{status}")
    {:noreply, put_flash(socket, :error, "Voice media could not start (#{status}).")}
  end

  defp voice_failed(socket, step, reason) do
    Logger.warning("voice: #{step} failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Voice media could not start.")}
  end

  defp ensure_publish_session(socket) do
    case socket.assigns.voice_record.publish_session_id do
      nil ->
        with {:ok, session_id} <- Cloudflare.new_session(),
             {:ok, _} <-
               Voice.set_session(
                 room_channel_id(socket),
                 socket.assigns.voice_record.user_id,
                 :publish_session_id,
                 session_id,
                 socket.assigns.voice_record.token
               ) do
          {:ok, session_id}
        end

      session_id ->
        {:ok, session_id}
    end
  end

  defp ensure_recv_session(socket, record) do
    case socket.assigns.voice_recv_session_id do
      nil ->
        with {:ok, session_id} <- Cloudflare.new_session() do
          Voice.set_session(
            room_channel_id(socket),
            record.user_id,
            :recv_session_id,
            session_id,
            record.token
          )

          {:ok, session_id}
        end

      session_id ->
        {:ok, session_id}
    end
  end

  # Applies a participant record to the room list and, when it is this tab's own, to
  # `voice_record`. A change this tab makes reaches it only through here: the room broadcast
  # skips the sending process (`Topics.broadcast_channel/2` uses `broadcast_from`).
  defp update_room_record(socket, record) do
    socket
    |> update(:voice_participants, &replace_participant(&1, record))
    |> then(fn socket ->
      own = socket.assigns.voice_record

      if own && own.user_id == record.user_id && own.token == record.token do
        assign(socket, :voice_record, record)
      else
        socket
      end
    end)
  end

  defp replace_participant(participants, record) do
    {_, rest} = Enum.split_with(participants, &(&1.user_id == record.user_id))
    [record | rest]
  end

  defp update_occupants(socket, channel_id, participants) do
    update(socket, :voice_occupants, &Map.put(&1, channel_id, participants))
  end

  defp own_room?(socket, channel_id) do
    socket.assigns.voice_channel && socket.assigns.voice_channel.id == channel_id
  end

  defp room_channel_id(socket), do: socket.assigns.voice_channel.id

  defp publication_key(track), do: "#{track["sessionId"]}:#{track["trackName"]}"

  defp truthy?(value), do: value == true or value == "true"

  defp log_failed(step, reason) do
    Logger.warning("voice: #{step} failed: #{inspect(reason)}")
  end
end
