# Voice channels: mic, camera and screen share over Cloudflare Realtime SFU

Status: designed 2026-11-21. Task: "Write the voice design record". Epic: "Voice channels with camera and screen share".

A voice channel is a channel of kind `:voice`. The sidebar lists who is in each. A participant connects with mic, camera or screen share; media flows browser-to-browser over Cloudflare Realtime SFU (each person publishes once; Cloudflare forwards). Tavern never touches media. Tavern owns the room state and the signaling: the browser speaks plain WebRTC, and Tavern relays SDP between the browser and Cloudflare's HTTPS API. Push-to-talk is a separate proposal (ts-66db7d), not part of this design.

## Where each part lives

| Part | Owner |
| --- | --- |
| Room membership, published tracks, muted flags | `Tavern.Voice`, state in Valkey |
| SFU sessions and negotiation for one browser tab | that tab's ServerLive process |
| Media capture, PeerConnections, playback | the `.VoiceSession` colocated hook |
| Calls to `rtc.live.cloudflare.com` | `Tavern.Voice.Cloudflare` (Req) |
| Who may connect, speak, stream, moderate | `Visibility` abilities from `PermissionBits` |

## Room state

One Valkey hash per channel, key `voice:room:{channel_id}` (the deploy prefix applies). The field is the participant's user id; the value is a JSON record:

```json
{
  "user_id": "...",
  "token": "...",                   // fresh per join; a LiveView tells its own record from a replacement's
  "joined_at": 1737...,
  "heartbeat_at": 1737...,
  "muted": false,
  "publish_session_id": "...",      // Cloudflare session id, null until publishing
  "recv_session_id": "...",         // Cloudflare session id for receiving, null until connected
  "tracks": {                       // publications other rooms may subscribe to
    "mic":    { "trackName": "mic", "sessionId": "...", "mids": ["0"] },
    "camera": { "trackName": "camera", "sessionId": "...", "mids": ["1"], "rids": ["f", "h", "q"] },
    "screen": { "trackName": "screen", "sessionId": "...", "mids": ["2"], "rids": ["f", "h", "q"] }
  }
}
```

Track names are fixed: `mic`, `camera`, `screen`. Other participants learn publications from this record; the SFU identifies remote tracks by publisher session id and track name, so the record carries both.

Every participant's ServerLive process heartbeats its own record every 30 seconds (`heartbeat_at`, plus `EXPIRE 90` on the hash). A read prunes entries whose `heartbeat_at` is older than 90 seconds first. So:

- A LiveView process dies or a tab closes: the heartbeat stops, the entry expires within 90 seconds, and every other view sees the participant leave at its next read. The dying process also tries a best-effort explicit leave (`terminate/3`), so the common case is immediate.
- A node restarts: same as a dead process; the hash itself expires shortly after its last member does.
- Valkey is down: joins are refused with `{:error, :unavailable}` and the UI shows "voice is unavailable". A running call keeps its media (WebRTC does not depend on Tavern once negotiated); state changes and re-joins wait for Valkey.

### Member limit

The channel row carries `voice_member_limit`, default 6, bounded 1..25 in the changeset. Join runs one Lua script: prune expired entries, then refuse when the count is at the limit and the user is not already in, else write the record. The check and the write are one Valkey call, so two simultaneous joins cannot both take the last seat.

A second tab of the same user joining replaces the record (the record is keyed by user id). The replacing join broadcasts `{:voice_replaced, old_record}`; the old tab's LiveView drops its sessions and tells its browser to end, and the old tab's sessions are force-closed at Cloudflare.

## Room events

`Tavern.Voice` broadcasts after each state change:

- `{:voice_joined, channel_id, participants}` on the server topic — the sidebar re-renders the occupants under the channel.
- `{:voice_left, channel_id, participants}` on the server topic — same.
- `{:voice_published, channel_id, record}` and `{:voice_updated, channel_id, record}` (mute flags) on the channel topic — other participants subscribe or update tiles.
- `{:voice_moderated, channel_id, record}` on the channel topic — a moderator's mute or disconnect reached a participant; that participant's own LiveView acts on it.

ServerLive already syncs channel-topic subscriptions for every channel the user can view, so the voice pane needs no extra subscription; it reacts to the channel-topic events for the room it is in, and to the server-topic events for the sidebar.

## Signaling

Each browser tab has at most two SFU sessions, both created by its own ServerLive process: a publish session for its outgoing tracks and a receive session for everyone else's. Separate sessions keep the per-session mutation ordering (serialize every SDP exchange) trivial: each session's exchanges originate from one browser and are handled in one process, in arrival order.

Join (`TavernWeb.ServerLive.Voice`, event `voice_join`):

1. `Visibility.authorize_write(scope, :connect_voice, channel)`.
2. `Tavern.Voice.join(channel, user, limit)` — the Lua join above.
3. The LiveView stores the record and pushes `voice_ready` to the browser with the TURN config.

Publish mic (event `voice_publish`, one per publish or unpublish):

1. Authorize `:speak_voice` (mic) or `:stream_voice` (camera, screen).
2. The browser hook captured the track, created the offer with `addTransceiver(track, {direction: "sendonly"})` (simulcast `sendEncodings` for video), waited for ICE gathering, and sent `{type, sdp, mids}`.

Camera and screen start from the controls' `voice_toggle_video`: the LiveView authorizes
`:stream_voice` first and answers with `voice_video_request {kind, active}`, so the browser
captures (`getUserMedia` for camera, `getDisplayMedia` for screen) only after the right is
decided. An `active: true` answer means the click turns the kind off: the hook stops its
tracks and sends `voice_unpublish`, which force-closes the recorded mids at the SFU and
clears the record entry. The screen's own "Stop sharing" bar kills the capture track; the
hook listens for `track.onended` and takes the same unpublish path, so the room record
cannot claim a screen that is gone. A later publish adds fresh transceivers to the same
publish session; the SDP sections accumulate, which is accepted until real behavior shows
otherwise (then: a fresh publish session per video cycle).

3. The LiveView calls `POST /sessions/new`, then `POST /sessions/{id}/tracks/new` with the offer and the local track entries, and records the returned session id.
4. It pushes the SFU answer to the browser; the hook applies `setRemoteDescription` and reports `connected`.
5. The LiveView writes the track into the room record and broadcasts `{:voice_published, ...}`.

Subscribe (driven by the LiveView on room and publication events):

1. For each other participant's track not yet subscribed, the LiveView calls `POST /sessions/{recv_id}/tracks/new` with `{location: "remote", sessionId, trackName}` entries (no local offer). It creates the receive session on first use.
2. The response carries an SFU offer; the LiveView pushes it to the browser.
3. The hook applies it, answers, waits for gathering, and sends its answer; the LiveView calls `PUT /sessions/{recv_id}/renegotiate` with it.
4. The hook matches received tracks to publications by the `mid` list the LiveView pushed along with the offer.

Unpublish or leave (`voice_unpublish`, `voice_leave`, process terminate): the LiveView calls `PUT /sessions/{id}/tracks/close` with `force: true` (no negotiation needed), deletes or updates the record, and broadcasts. The browser also stops its own captures and closes PeerConnections. Moderator disconnect uses the same leave path against another user's record.

Mute (`voice_mute`): the browser toggles `track.enabled` on the mic track — media keeps flowing or stops at the track level; no SFU call. The LiveView updates the record and broadcasts `{:voice_updated, ...}`. A moderator mute writes the flag and broadcasts `{:voice_moderated, ...}`; the target's LiveView disables the track server-side-instructed and its browser confirms.

Speaking indicator: the hook watches the mic with an `AudioContext` analyser and sends only transitions (`voice_speaking_start` / `voice_speaking_stop`). The LiveView broadcasts the transition on the channel topic; no room record changes, so mute stays the single source of truth for who may be heard.

## Abilities

Five new bits in `PermissionBits`: `connect_voice`, `speak_voice`, `stream_voice`, `mute_voice_members`, `disconnect_voice_members`. The default role grants `connect_voice`, `speak_voice` and `stream_voice`, so everyone connects and speaks by default; the moderator bits go to staff roles like the other moderation bits. Channel overwrites apply to all five like any other bit, decided in `Visibility` from the one load. The gates:

| Step | Gate |
| --- | --- |
| join | `:connect_voice` |
| publish mic / unmute | `:speak_voice` |
| publish camera or screen | `:stream_voice` |
| mute another member | `:mute_voice_members` |
| disconnect another member | `:disconnect_voice_members` |

Losing a bit mid-call takes effect at the next gate: a revoked speaker keeps their negotiated track until they next publish, but a revoke also runs the moderator-mute path against them (the revoke handler calls `Tavern.Voice.set_muted/3` server-side), so enforcement is immediate without renegotiation.

## Text chat beside the grid

A voice channel's pane is a grid of participant tiles with the message transcript beside it, exactly as a text channel's pane renders messages — messages are already keyed by channel id, and `:send_messages` works on a voice channel. No new message kind, no thread rules on voice channels (`Channel.thread_host?/1` excludes `:voice`).

## Video in the tiles

- **One area per kind.** A tile renders one video area for each kind the participant publishes, screen first, then camera. The area has the id `voice-video-<user id>-<kind>` and `phx-update="ignore"`, so the `<video>` element the hook puts in it survives the tile's re-renders on every speaking change. The server renders an area only after it records the track, and removes it when the track stops.
- **The area asks for its track.** Each area carries the `.VoiceVideo` hook. When the area mounts, the hook sends a `voice:video-area` DOM event, and `.VoiceSession` places the matching track from its buffer, keyed `<user id>:<kind>`. A track that arrives before its area waits in the buffer. This also covers a reader who comes back to the voice channel: the areas mount again and ask again.
- **Your own video.** The SFU never sends a tab its own tracks (`missing_publications/2` skips them), so `.VoiceSession` buffers the captured track under the reader's own id. Your preview appears when the server has accepted the publish, so a visible preview means you are streaming.
- **No sound from video elements.** The `<video>` elements are muted. Sound plays only through the hook's `<audio>` elements. A screen share uses `object-contain`, so the whole picture shows; a camera uses `object-cover`.

## Configuration

```elixir
config :tavern, Tavern.Voice.Cloudflare,
  app_id: System.get_env("CLOUDFLARE_REALTIME_APP_ID"),
  app_secret: System.get_env("CLOUDFLARE_REALTIME_APP_SECRET"),
  turn_key_id: System.get_env("CLOUDFLARE_TURN_KEY_ID"),
  turn_key_token: System.get_env("CLOUDFLARE_TURN_KEY_TOKEN")
```

One Realtime app and secret pair serves local, staged and production. The TURN key is a
separate server-side secret: Tavern never sends it to a browser. `Tavern.Voice.Cloudflare.turn_ice_servers/1`
mints short-lived credentials for each joining session (Cloudflare's credential endpoint, the
same ICE-servers response the browser passes to `RTCPeerConnection`); without a TURN key the
mint is skipped and the browser gets Cloudflare's STUN server. `Tavern.Voice.Cloudflare.configured?/0`
is false unless `app_id` and `app_secret` are set; without them the voice join button shows
"voice not configured" and `Tavern.Voice.join/3` is never reached. Tests stub the API with
`Req.Test` (test config pins `req_opts: [plug: {Req.Test, Tavern.Voice.Cloudflare}]`); the
two-browser smoke against real Cloudflare runs by hand on staged (ts-84fdd2).
