defmodule Tavern.Voice.Participant do
  @moduledoc """
  One member's record inside one voice room (docs/design/voice.md). Lives as a JSON value in
  the room's Valkey hash; `token` is fresh per join, so a LiveView can tell its own record from
  one a second tab replaced. `tracks` holds what the member publishes; each entry carries the
  publisher's Cloudflare session id and track name, which a subscriber needs to request it.
  """

  @kinds [:mic, :camera, :screen]

  @derive {Jason.Encoder, only: [
            :user_id,
            :token,
            :joined_at,
            :heartbeat_at,
            :muted,
            :publish_session_id,
            :recv_session_id,
            :tracks
          ]}

  defstruct [
    :user_id,
    :token,
    :joined_at,
    :heartbeat_at,
    :muted,
    :publish_session_id,
    :recv_session_id,
    :tracks
  ]

  def new(user_id) do
    now = DateTime.utc_now() |> DateTime.to_unix(:second)

    %__MODULE__{
      user_id: user_id,
      token: Ecto.UUID.generate(),
      joined_at: now,
      heartbeat_at: now,
      muted: false,
      tracks: %{}
    }
  end

  def decode!(json) when is_binary(json) do
    map = Jason.decode!(json)

    %__MODULE__{
      user_id: map["user_id"],
      token: map["token"],
      joined_at: map["joined_at"],
      heartbeat_at: map["heartbeat_at"],
      muted: map["muted"],
      publish_session_id: map["publish_session_id"],
      recv_session_id: map["recv_session_id"],
      tracks: Map.new(map["tracks"] || %{}, fn {kind, track} ->
        {String.to_existing_atom(kind), track}
      end)
    }
  end

  @doc "The published kinds that carry video: camera and screen."
  def video_tracks(%__MODULE__{} = record) do
    for(kind <- [:camera, :screen], record.tracks[kind] != nil, do: kind)
  end

  def published?(%__MODULE__{} = record, kind) when kind in @kinds, do: record.tracks[kind] != nil
end
