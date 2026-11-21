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
end
