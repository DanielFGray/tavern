defmodule TavernWeb.ServerLiveVoiceTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Voice

  # Voice gate tests stub the Realtime API (docs/design/voice.md). The join and leave flows
  # call Cloudflare only when the browser publishes, so a stub that answers every path covers
  # the ones these tests drive.
  setup do
    Req.Test.stub(Tavern.Voice.Cloudflare, fn conn ->
      Req.Test.json(conn, %{"sessionId" => "stub-session"})
    end)

    Tavern.Bootstrap.ensure_seed_data!()

    owner = owner_fixture()
    voice = channel_fixture(%{name: "Lounge Voice", kind: :voice, voice_member_limit: 2})

    %{owner: owner, voice: voice}
  end

  test "a voice channel renders its join card, not the text-channel composer", %{
    conn: conn,
    voice: voice
  } do
    {:ok, view, _html} = live_hydrated(log_in_member_user(conn), "/?channel=#{voice.slug}")

    assert has_element?(view, "#voice-room")
    assert has_element?(view, "#voice-join-button")
    # The voice channel's composer lives in its chat column, not pinned to the pane bottom.
    assert has_element?(view, "#voice-chat")
  end

  test "joining puts the member in the room and the sidebar lists them", %{
    conn: conn,
    voice: voice
  } do
    conn = log_in_member_user(conn)
    user = current_user_from_conn(conn)

    {:ok, view, _html} = live_hydrated(conn, "/?channel=#{voice.slug}")

    view
    |> element("#voice-join-button")
    |> render_click()

    assert has_element?(view, "#voice-mic-toggle")
    assert has_element?(view, "#voice-leave-button")

    assert [%Voice.Participant{} = participant] = Voice.participants(voice.id)
    assert participant.user_id == user.id

    # The server-topic broadcast reaches the same view's sidebar.
    assert has_element?(view, "#voice-call-bar")
  end

  test "the join is refused with a flash past the member limit", %{conn: conn, voice: voice} do
    conn = log_in_member_user(conn)
    user = current_user_from_conn(conn)

    {:ok, _first, _} = Voice.join(voice, %{id: Ecto.UUID.generate()})
    {:ok, _second, _} = Voice.join(voice, %{id: Ecto.UUID.generate()})

    {:ok, view, _html} = live_hydrated(conn, "/?channel=#{voice.slug}")

    view
    |> element("#voice-join-button")
    |> render_click()

    # The refusal is a flash on the view, asserted as an element, not raw HTML.
    assert has_element?(view, "p", "This voice channel is full.")

    assert [] == Enum.filter(Voice.participants(voice.id), &(&1.user_id == user.id))
  end

  test "leaving ends the call and clears the bar", %{conn: conn, voice: voice} do
    {:ok, view, _html} = live_hydrated(log_in_member_user(conn), "/?channel=#{voice.slug}")

    view |> element("#voice-join-button") |> render_click()
    assert has_element?(view, "#voice-leave-button")

    view |> element("#voice-leave-button") |> render_click()

    assert [] == Voice.participants(voice.id)
    refute has_element?(view, "#voice-call-bar")
  end

  test "the publisher's own tile gets a video area for the kind it publishes", %{
    conn: conn,
    voice: voice
  } do
    Req.Test.stub(Tavern.Voice.Cloudflare, fn conn ->
      case Enum.take(conn.path_info, -2) do
        ["tracks", "new"] ->
          Req.Test.json(conn, %{
            "tracks" => [%{"mid" => "1", "trackName" => "camera"}],
            "sessionDescription" => %{"type" => "answer", "sdp" => "v=0"}
          })

        _ ->
          Req.Test.json(conn, %{"sessionId" => "stub-session"})
      end
    end)

    conn = log_in_member_user(conn)
    user = current_user_from_conn(conn)
    {:ok, view, _html} = live_hydrated(conn, "/?channel=#{voice.slug}")
    view |> element("#voice-join-button") |> render_click()

    render_hook(view, "voice_publish", %{
      "kind" => "camera",
      "sdp" => "v=0",
      "mids" => [%{"mid" => "1"}]
    })

    assert_reply(view, %{session_description: %{"type" => "answer"}})

    assert has_element?(view, "#voice-camera-toggle[aria-pressed=true]")
    assert has_element?(view, "#voice-video-#{user.id}-camera")
  end

  test "each published video kind gets its own area that LiveView patches leave alone", %{
    conn: conn,
    voice: voice
  } do
    {:ok, view, _html} = live_hydrated(log_in_member_user(conn), "/?channel=#{voice.slug}")
    view |> element("#voice-join-button") |> render_click()

    peer = %{id: Ecto.UUID.generate()}
    {:ok, record, _} = Voice.join(voice, peer)
    screen = %{"trackName" => "screen", "sessionId" => "s1", "mids" => ["1"]}
    camera = %{"trackName" => "camera", "sessionId" => "s1", "mids" => ["2"]}
    {:ok, _} = Voice.publish_track(voice.id, peer.id, record.token, :screen, screen, ["f"])
    {:ok, _} = Voice.publish_track(voice.id, peer.id, record.token, :camera, camera, ["f"])

    screen_area = "#voice-video-#{peer.id}-screen[phx-update=ignore][phx-hook]"
    camera_area = "#voice-video-#{peer.id}-camera[phx-update=ignore][phx-hook]"
    assert has_element?(view, screen_area)
    assert has_element?(view, camera_area)

    {:ok, _} = Voice.publish_track(voice.id, peer.id, record.token, :screen, nil, nil)

    refute has_element?(view, screen_area)
    assert has_element?(view, camera_area)
  end
end
