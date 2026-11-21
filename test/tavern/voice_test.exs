defmodule Tavern.VoiceTest do
  use Tavern.DataCase, async: false

  alias Tavern.Chat.Channel
  alias Tavern.ChatFixtures
  alias Tavern.Voice
  alias Tavern.Voice.Participant

  @pubsub Tavern.PubSub

  setup do
    # Every room key is unique per test, so the real Valkey holds no state across tests.
    %{channel_id: Ecto.UUID.generate()}
  end

  # Topics broadcasts with `broadcast_from`, which skips the calling process. The test calls
  # the context directly, so a separate listener process subscribes and forwards room events.
  defp listen(topic) do
    parent = self()

    pid =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(@pubsub, topic)
        send(parent, {:listening, self()})
        listen_loop(parent)
      end)

    assert_receive {:listening, ^pid}
  end

  defp listen_loop(parent) do
    receive do
      message ->
        send(parent, {:room_event, message})
        listen_loop(parent)
    end
  end

  describe "join/2" do
    test "writes the record and lists the participant", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 6)
      user = %{id: Ecto.UUID.generate()}

      assert {:ok, record, participants} = Voice.join(channel, user)
      assert record.user_id == user.id
      assert record.token
      assert record.muted == false
      assert record.tracks == %{}

      assert [%Participant{} = listed] = Voice.participants(channel_id)
      assert listed.token == record.token
      assert participants == [listed]
    end

    test "a second join replaces the record with a fresh token", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 6)
      user = %{id: Ecto.UUID.generate()}
      {:ok, first, _} = Voice.join(channel, user)
      {:ok, second, _} = Voice.join(channel, user)

      assert second.token != first.token
      assert [listed] = Voice.participants(channel_id)
      assert listed.token == second.token
    end

    test "refuses the join past the member limit and keeps the seat free", %{channel_id: channel_id} do
      Voice.join(voice_channel(channel_id, 1), %{id: Ecto.UUID.generate()})

      assert {:error, :room_full} =
               Voice.join(voice_channel(channel_id, 1), %{id: Ecto.UUID.generate()})

      assert [_] = Voice.participants(channel_id)
    end

    test "a member already in the room may rejoin at the limit", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 1)
      user = %{id: Ecto.UUID.generate()}
      {:ok, _first, _} = Voice.join(channel, user)

      assert {:ok, _record, _participants} = Voice.join(channel, user)
    end

    test "refuses to join a channel that is not voice", %{channel_id: channel_id} do
      channel = %Channel{id: channel_id, kind: :text, voice_member_limit: 6}

      assert {:error, :not_found} = Voice.join(channel, %{id: Ecto.UUID.generate()})
    end
  end

  describe "leave/2 and heartbeat/3" do
    test "leave removes the record and clears the room", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 6)
      user = %{id: Ecto.UUID.generate()}
      {:ok, _record, _} = Voice.join(channel, user)

      assert {:ok, []} = Voice.leave(channel_id, user.id)
      assert [] = Voice.participants(channel_id)
      assert {:error, :not_connected} = Voice.leave(channel_id, user.id)
    end

    test "heartbeat keeps the record and reports gone after the record vanishes", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 6)
      user = %{id: Ecto.UUID.generate()}
      {:ok, record, _} = Voice.join(channel, user)

      assert :ok = Voice.heartbeat(channel_id, user.id, record.token)
      {:ok, [_]} = Voice.leave(channel_id, user.id)

      assert {:error, :gone} = Voice.heartbeat(channel_id, user.id, record.token)
    end

    test "heartbeat reports gone when another tab replaced the record", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 6)
      user = %{id: Ecto.UUID.generate()}
      {:ok, first, _} = Voice.join(channel, user)
      {:ok, _second, _} = Voice.join(channel, user)

      assert {:error, :gone} = Voice.heartbeat(channel_id, user.id, first.token)
    end
  end

  describe "publish_track/6 and set_muted/4" do
    setup %{channel_id: channel_id} do
      listen("chat:channel:" <> channel_id)
      :ok
    end

    test "records the track and broadcasts it", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 6)
      user = %{id: Ecto.UUID.generate()}
      {:ok, record, _} = Voice.join(channel, user)

      track = %{"trackName" => "mic", "sessionId" => "s1", "mids" => ["0"]}
      assert {:ok, _record} = Voice.publish_track(channel_id, user.id, record.token, :mic, track, nil)

      assert_receive {:room_event, {:voice_published, ^channel_id, published}}, 500
      assert published.tracks[:mic] == track

      assert [listed] = Voice.participants(channel_id)
      assert listed.tracks[:mic] == track
    end

    test "a publish under a stale token is refused", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 6)
      user = %{id: Ecto.UUID.generate()}
      {:ok, first, _} = Voice.join(channel, user)
      {:ok, _second, _} = Voice.join(channel, user)

      track = %{"trackName" => "mic", "sessionId" => "s1", "mids" => ["0"]}

      assert {:error, :not_connected} =
               Voice.publish_track(channel_id, user.id, first.token, :mic, track, nil)
    end

    test "removing the track clears the entry", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 6)
      user = %{id: Ecto.UUID.generate()}
      {:ok, record, _} = Voice.join(channel, user)

      track = %{"trackName" => "camera", "sessionId" => "s1", "mids" => ["1"]}
      {:ok, _} = Voice.publish_track(channel_id, user.id, record.token, :camera, track, ["f", "h", "q"])
      assert {:ok, record} = Voice.publish_track(channel_id, user.id, record.token, :camera, nil, nil)

      assert record.tracks[:camera] == nil
      assert_receive {:room_event, {:voice_published, ^channel_id, _}, 500
    end

    test "set_muted flips the flag and broadcasts", %{channel_id: channel_id} do
      channel = voice_channel(channel_id, 6)
      user = %{id: Ecto.UUID.generate()}
      {:ok, record, _} = Voice.join(channel, user)

      assert {:ok, record} = Voice.set_muted(channel_id, user.id, record.token, true)
      assert record.muted == true

      assert_receive {:room_event, {:voice_updated, ^channel_id, updated}, 500
      assert updated.muted == true

      assert [listed] = Voice.participants(channel_id)
      assert listed.muted == true
    end
  end

  describe "moderation" do
    setup do
      owner = ChatFixtures.owner_fixture()
      member = ChatFixtures.user_fixture()
      other_member = ChatFixtures.user_fixture()
      channel = ChatFixtures.channel_fixture(%{name: "Voice", kind: :voice, voice_member_limit: 6})

      listen("chat:channel:" <> channel.id)

      %{
        channel: channel,
        owner: owner,
        member: member,
        other_member: other_member
      }
    end

    test "mute_member writes the flag and broadcasts when the actor holds the bit and ranks over",
         %{channel: channel, owner: owner, member: member} do
      {:ok, _record, _} = Voice.join(channel, %{id: member.id})

      assert {:ok, %{muted: true}} =
               Voice.mute_member(ChatFixtures.scope_for(owner), channel.id, member.id)

      assert_receive {:room_event, {:voice_moderated, _channel_id, subject_id, :mute}, 500
      assert subject_id == member.id
    end

    test "mute_member is forbidden for a member without the bit", %{channel: channel, member: member, other_member: other_member} do
      {:ok, _record, _} = Voice.join(channel, %{id: other_member.id})

      assert {:error, :forbidden} =
               Voice.mute_member(ChatFixtures.scope_for(member), channel.id, other_member.id)
    end

    test "the owner cannot be muted", %{channel: channel, member: member} do
      owner = ChatFixtures.owner_fixture()

      assert {:error, :forbidden} = Voice.mute_member(ChatFixtures.scope_for(member), channel.id, owner.id)
    end

    test "disconnect_member removes the record and broadcasts the leave",
         %{channel: channel, owner: owner, member: member} do
      {:ok, _record, _} = Voice.join(channel, %{id: member.id})

      assert {:ok, []} = Voice.disconnect_member(ChatFixtures.scope_for(owner), channel.id, member.id)

      assert_receive {:room_event, {:voice_left, _channel_id, []}}, 500
      assert_receive {:room_event, {:voice_moderated, _channel_id, subject_id, :disconnect}, 500
      assert subject_id == member.id
      assert [] = Voice.participants(channel.id)
    end
  end

  # A `%Channel{}` for the room-state tests that runs on no database row: the room key is a fresh
  # UUID, so Valkey holds nothing across tests and nothing leaks.
  defp voice_channel(id, limit) do
    %Channel{id: id, kind: :voice, voice_member_limit: limit}
  end
end
