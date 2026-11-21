defmodule Tavern.Voice do
  @moduledoc """
  Voice room state for the Cloudflare Realtime SFU call (docs/design/voice.md).

  One Valkey hash per voice channel, `voice:room:{channel_id}`, holds one participant record
  per member in the room. The participant's own ServerLive process is the only writer of its
  record (join, heartbeat, publish, mute), except a moderator's mute and disconnect, which write
  another member's record. A Lua script does each prune-then-decide so the member limit and the
  expiry stay race-free without a locking process.

  Tavern holds no media session state beyond these records and the session ids inside them:
  the browser owns its PeerConnections, Cloudflare owns the media, and this module owns only
  who is in the room and what each member publishes. Every state change broadcasts; the
  ServerLive processes react.
  """

  require Logger

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Valkey
  alias Tavern.Voice.Cloudflare
  alias Tavern.Voice.Participant

  # A record whose heartbeat stopped for this long is gone: its LiveView died or its tab closed
  # without a leave. Reads and joins prune such records.
  @stale_after_seconds 90
  # The hash itself lives twice the prune age, so a room with active members never expires.
  @room_ttl_seconds 240

  # --- Join and leave -------------------------------------------------------------------------

  @doc """
  Joins `channel` as `user`. Refuses with `{:error, :unconfigured}` when the deploy holds no
  Realtime secrets, `{:error, :room_full}` when the member limit is met, and
  `{:error, :unavailable}` when Valkey is unreachable. A member already in the room replaces
  its record: a second tab takes over, and the first tab is told through `{:voice_joined, ...}`.
  """
  def join(%Channel{kind: :voice, id: channel_id, voice_member_limit: limit}, user) do
    if Cloudflare.configured?() do
      record = Participant.new(user.id)
      user_id = user.id
      now = unix_now()
      limit = max(limit, 1)

      with {:ok, "ok"} <- join_script(channel_id, user_id, limit, record, now),
           participants <- read_participants(channel_id) do
        Topics.broadcast_server({:voice_joined, channel_id, participants})
        {:ok, record, participants}
      else
        {:ok, "full"} -> {:error, :room_full}
        {:error, :unavailable} = error -> error
      end
    else
      {:error, :unconfigured}
    end
  end

  def join(%Channel{}, _user), do: {:error, :not_found}

  @doc """
  Removes the member's record and broadcasts the leave. `token` (optional) must match the
  record's, so a replaced tab cannot delete the tab that took its seat; a mismatch answers
  `{:error, :replaced}` and broadcasts nothing. A member not in the room is
  `{:error, :not_connected}`.
  """
  def leave(channel_id, user_id, token \\ "") do
    with {:ok, "ok"} <- leave_script(channel_id, user_id, token) do
      participants = read_participants(channel_id)
      Topics.broadcast_server({:voice_left, channel_id, participants})
      {:ok, participants}
    else
      {:error, :unavailable} = error -> error
      _ -> {:error, :not_connected}
    end
  end

  @doc """
  Refreshes the member's heartbeat. `{:error, :gone}` means the record vanished or another tab
  replaced it: the caller re-decides from `participants/1`.
  """
  def heartbeat(channel_id, user_id, token) do
    case update_own(channel_id, user_id, "heartbeat_at", Jason.encode!(unix_now()), token) do
      {:ok, _record} -> :ok
      {:error, :unavailable} = error -> error
      _ -> {:error, :gone}
    end
  end

  @doc "The room's participants, stale records pruned, joined order kept. A failed read is an error tuple."
  def participants(channel_id) do
    case read_script(channel_id) do
      {:ok, records} when is_list(records) ->
        Enum.map(records, &Participant.decode!/1)

      {:ok, nil} ->
        []

      {:error, reason} = error ->
        Logger.warning("voice: room read failed: #{inspect(reason)}")
        error
    end
  end

  # --- Publishing and own state ---------------------------------------------------------------

  @doc """
  Records one published track of the member's own record and broadcasts it, or removes the
  entry when `track` is nil. `kind` is `:mic`, `:camera` or `:screen`.
  """
  def publish_track(channel_id, user_id, token, kind, track, rids)
      when kind in [:mic, :camera, :screen] do
    value =
      cond do
        is_nil(track) -> "__delete__"
        is_nil(rids) -> Jason.encode!(track)
        true -> Jason.encode!(Map.put(track, "rids", rids))
      end

    with {:ok, record} <- update_own(channel_id, user_id, "tracks.#{kind}", value, token) do
      Topics.broadcast_channel(channel_id, {:voice_published, channel_id, record})
      {:ok, record}
    else
      {:error, :unavailable} = error -> error
      {:error, :gone} -> {:error, :not_connected}
    end
  end

  @doc "Sets the member's own muted flag and broadcasts it. No SFU call: mute is track level."
  def set_muted(channel_id, user_id, token, muted) when muted in [true, false] do
    with {:ok, record} <- update_own(channel_id, user_id, "muted", Jason.encode!(muted), token) do
      Topics.broadcast_channel(channel_id, {:voice_updated, channel_id, record})
      {:ok, record}
    else
      {:error, :unavailable} = error -> error
      {:error, :gone} -> {:error, :not_connected}
    end
  end

  @doc "Stores one SFU session id of the member's own record, or nil to clear it."
  def set_session(channel_id, user_id, which, session_id, token \\ "")
      when which in [:publish_session_id, :recv_session_id] do
    value = if is_nil(session_id), do: "__delete__", else: Jason.encode!(session_id)
    set_field(channel_id, user_id, Atom.to_string(which), value, token)
  end

  # --- Moderation -----------------------------------------------------------------------------

  @doc """
  Mutes another member inside `channel_id`: the scope needs `:mute_voice_members` in the
  channel and must rank over the subject (`Visibility.voice_moderate?/4`). The target's
  ServerLive acts on the `{:voice_moderated, ...}` broadcast; this only writes the flag.
  """
  def mute_member(%Scope{} = scope, channel_id, subject_id) do
    moderate(scope, channel_id, subject_id, :mute_voice_members, fn _record ->
      with {:ok, "ok"} <- set_field(channel_id, subject_id, "muted", "true", ""),
           {:ok, updated} <- own_participant(channel_id, subject_id) do
        Topics.broadcast_channel(channel_id, {:voice_updated, channel_id, updated})
        Topics.broadcast_channel(channel_id, {:voice_moderated, channel_id, subject_id, :mute})
        {:ok, updated}
      else
        {:error, :gone} -> {:error, :not_connected}
        error -> error
      end
    end)
  end

  @doc """
  Disconnects another member: `:disconnect_voice_members` and rank, as `mute_member/3`. The
  record is removed; the target's ServerLive ends its SFU sessions, and every view sees the
  leave through the server-topic broadcast.
  """
  def disconnect_member(%Scope{} = scope, channel_id, subject_id) do
    moderate(scope, channel_id, subject_id, :disconnect_voice_members, fn _record ->
      # The moderator path skips the token check: the record was verified just above.
      with {:ok, "ok"} <- leave_script(channel_id, subject_id, "") do
        participants = read_participants(channel_id)
        Topics.broadcast_server({:voice_left, channel_id, participants})
        Topics.broadcast_channel(channel_id, {:voice_moderated, channel_id, subject_id, :disconnect})
        {:ok, participants}
      end
    end)
  end

  defp moderate(scope, channel_id, subject_id, bit, apply) do
    if Visibility.voice_moderate?(scope, bit, channel_id, subject_id) do
      case find_participant(channel_id, subject_id) do
        {:ok, record} -> apply.(record)
        {:error, :unavailable} = error -> error
        _ -> {:error, :not_connected}
      end
    else
      {:error, :forbidden}
    end
  end

  # --- Valkey scripts -------------------------------------------------------------------------

  # Every script prunes stale records first: a dead tab must not keep its seat or be listed.
  @join_script ~s"""
    local function prune(room, now)
      local stale = {}
      for _, user_id in ipairs(redis.call('HKEYS', room)) do
        local rec = cjson.decode(redis.call('HGET', room, user_id))
        if now - tonumber(rec.heartbeat_at) > #{@stale_after_seconds} then
          stale[#stale + 1] = user_id
        end
      end
      for _, user_id in ipairs(stale) do redis.call('HDEL', room, user_id) end
    end
    prune(KEYS[1], tonumber(ARGV[1]))
    if redis.call('HEXISTS', KEYS[1], ARGV[2]) == 0 and redis.call('HLEN', KEYS[1]) >= tonumber(ARGV[3]) then
      return 'full'
    end
    redis.call('HSET', KEYS[1], ARGV[2], ARGV[4])
    redis.call('EXPIRE', KEYS[1], #{@room_ttl_seconds})
    return 'ok'
  """

  @read_script ~s"""
    local function prune(room, now)
      local stale = {}
      for _, user_id in ipairs(redis.call('HKEYS', room)) do
        local rec = cjson.decode(redis.call('HGET', room, user_id))
        if now - tonumber(rec.heartbeat_at) > #{@stale_after_seconds} then
          stale[#stale + 1] = user_id
        end
      end
      for _, user_id in ipairs(stale) do redis.call('HDEL', room, user_id) end
    end
    prune(KEYS[1], tonumber(ARGV[1]))
    return redis.call('HVALS', KEYS[1])
  """

  @update_script ~s"""
    local value = redis.call('HGET', KEYS[1], ARGV[1])
    if not value then return 'gone' end
    local rec = cjson.decode(value)
    if ARGV[4] ~= '' and rec.token ~= ARGV[4] then return 'stale' end
    local path = {}
    for part in string.gmatch(ARGV[2], '[^.]+') do path[#path + 1] = part end
    local t = rec
    for i = 1, #path - 1 do
      if t[path[i]] == nil then t[path[i]] = {} end
      t = t[path[i]]
    end
    if ARGV[3] == '__delete__' then
      t[path[#path]] = nil
    else
      t[path[#path]] = cjson.decode(ARGV[3])
    end
    redis.call('HSET', KEYS[1], ARGV[1], cjson.encode(rec))
    redis.call('EXPIRE', KEYS[1], #{@room_ttl_seconds})
    return 'ok'
  """

  @leave_script ~s"""
    local value = redis.call('HGET', KEYS[1], ARGV[1])
    if not value then return 'gone' end
    local rec = cjson.decode(value)
    if ARGV[2] ~= '' and rec.token ~= ARGV[2] then return 'replaced' end
    redis.call('HDEL', KEYS[1], ARGV[1])
    redis.call('EXPIRE', KEYS[1], #{@room_ttl_seconds})
    return 'ok'
  """

  defp join_script(channel_id, user_id, limit, record, now) do
    eval(@join_script, channel_id, [
      now,
      user_id,
      limit,
      Jason.encode!(record)
    ])
  end

  defp read_script(channel_id) do
    eval(@read_script, channel_id, [unix_now()])
  end

  defp leave_script(channel_id, user_id, token) do
    eval(@leave_script, channel_id, [user_id, token])
  end

  # Sets one dotted field of the record, `__delete__` removing it. `token` guards the write:
  # empty skips the check (the moderator path writes another member's record), a token must
  # match or the script refuses, so a replaced tab's write cannot land on its replacement.
  defp set_field(channel_id, user_id, path, value, token) do
    eval(@update_script, channel_id, [user_id, path, value, token])
  end

  # The own-record write: the script refuses when the token no longer matches.
  defp update_own(channel_id, user_id, path, value, token) do
    case set_field(channel_id, user_id, path, value, token) do
      {:ok, "ok"} -> own_participant(channel_id, user_id)
      {:ok, _other} -> {:error, :gone}
      error -> error
    end
  end

  defp own_participant(channel_id, user_id) do
    case find_participant(channel_id, user_id) do
      {:ok, record} -> {:ok, record}
      {:error, :unavailable} = error -> error
      _ -> {:error, :gone}
    end
  end

  defp find_participant(channel_id, user_id) do
    case read_script(channel_id) do
      {:ok, records} when is_list(records) ->
        Enum.find_value(records, {:error, :not_connected}, fn json ->
          record = Participant.decode!(json)
          record.user_id == user_id and {:ok, record}
        end)

      _ ->
        {:error, :unavailable}
    end
  end

  defp eval(script, channel_id, args) do
    case Valkey.command(["EVAL", script, "1", namespaced(room_key(channel_id)) | args]) do
      {:ok, result} -> {:ok, result}
      {:error, reason} = error ->
        Logger.warning("voice: valkey command failed: #{inspect(reason)}")
        error
    end
  end

  # `participants/1` answers the plain list (or an error); the callers that broadcast want the
  # list either way, so a failed read broadcasts an empty room.
  defp read_participants(channel_id) do
    case participants(channel_id) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp room_key(channel_id), do: "voice:room:" <> channel_id

  # Same deploy prefix Ephemeral puts on its keys; the Valkey user may touch only these.
  defp namespaced(key), do: Application.fetch_env!(:tavern, :valkey_key_prefix) <> key

  defp unix_now(now \\ DateTime.utc_now()), do: DateTime.to_unix(now, :second)
end
