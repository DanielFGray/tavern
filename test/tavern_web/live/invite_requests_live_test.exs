defmodule TavernWeb.InviteRequestsLiveTest do
  # The intake and send limits are server-wide counters in Valkey, so these tests run alone.
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.InviteRequest
  alias Tavern.Chat.InviteRequestLimits
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.ServerSettings
  alias Tavern.Repo

  setup do
    InviteRequestLimits.reset!()
    on_exit(&InviteRequestLimits.reset!/0)

    owner = owner_fixture()
    channel_fixture(%{slug: "general", name: "general"})
    moderator = user_fixture()
    member = user_fixture()

    role =
      role_fixture(%{permissions: PermissionBits.combine([:view_channel, :manage_applications])})

    member_role_fixture(moderator, role)
    set_settings!(registration_mode: :invite_only, accept_invite_requests: true)

    %{owner: owner, moderator: moderator, member: member}
  end

  describe "the request form on /register" do
    test "takes an address and answers Request received", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#invite-request-form", %{invite_request: %{email: "asker@example.com"}})
      |> render_submit()

      assert has_element?(view, "#invite-request-received")
      refute has_element?(view, "#invite-request-form")
      assert Repo.get_by!(InviteRequest, email: "asker@example.com").status == :pending
      refute_received {:mail_captured, _}
    end

    test "answers the same for a member's address and stores nothing", %{
      conn: conn,
      member: member
    } do
      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#invite-request-form", %{invite_request: %{email: member.email}})
      |> render_submit()

      assert has_element?(view, "#invite-request-received")
      assert Repo.aggregate(InviteRequest, :count) == 0
    end

    test "is absent while the server does not accept requests", %{conn: conn} do
      set_settings!(accept_invite_requests: false)
      {:ok, view, _html} = live(conn, ~p"/register")
      refute has_element?(view, "#invite-request-form")
    end

    test "a link with a code fills the invite code field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register?code=abcd2345")

      assert has_element?(
               view,
               "#registration-form input[name='user[invite_code]'][value='abcd2345']"
             )
    end
  end

  describe "the queue in Settings > Server" do
    test "a manage_applications holder approves and the link is mailed", %{
      conn: conn,
      moderator: moderator
    } do
      request = request!("queue@example.com")
      {:ok, view, _html} = live(log_in_as(conn, moderator), ~p"/settings?tab=server")

      assert has_element?(view, "#invite-requests-panel")
      assert has_element?(view, "#invite_requests-#{request.id}", "queue@example.com")

      view |> element("#approve-invite-request-#{request.id}") |> render_click()

      assert_receive {:mail_captured, %{to: "queue@example.com"}}
      assert has_element?(view, "#invite-request-delivered-#{request.id}")
      assert has_element?(view, "#resend-invite-request-#{request.id}")
      refute has_element?(view, "#approve-invite-request-#{request.id}")
    end

    test "Resend over the per-address limit shows the reason", %{conn: conn, moderator: moderator} do
      request = request!("again@example.com")
      {:ok, view, _html} = live(log_in_as(conn, moderator), ~p"/settings?tab=server")

      view |> element("#approve-invite-request-#{request.id}") |> render_click()
      view |> element("#resend-invite-request-#{request.id}") |> render_click()

      assert has_element?(view, "#invite-request-error-#{request.id}", "not sent: daily limit")
    end

    test "deny, and deny all from one IP", %{conn: conn, moderator: moderator} do
      single = request!("single@example.com", "10.1.1.1")
      flood = for n <- 1..3, do: request!("flood#{n}@example.com", "10.2.2.2")
      {:ok, view, _html} = live(log_in_as(conn, moderator), ~p"/settings?tab=server")

      refute has_element?(view, "#deny-invite-requests-from-ip-#{single.id}")
      assert has_element?(view, "#invite_requests-#{hd(flood).id}", "3 requests from this IP")

      view |> element("#deny-invite-request-#{single.id}") |> render_click()
      assert Repo.reload!(single).status == :denied

      view |> element("#deny-invite-requests-from-ip-#{hd(flood).id}") |> render_click()
      assert Enum.all?(flood, &(Repo.reload!(&1).status == :denied))
      refute has_element?(view, "#approve-invite-request-#{List.last(flood).id}")
    end

    test "a member without the bit sees no queue", %{conn: conn, member: member} do
      request!("hidden@example.com")
      {:ok, view, _html} = live(log_in_as(conn, member), ~p"/settings?tab=server")
      refute has_element?(view, "#invite-requests-panel")
    end
  end

  describe "the accept setting" do
    test "is offered to a server manager when mail works", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(log_in_as(conn, owner), ~p"/settings?tab=server")

      assert has_element?(view, "#accept-invite-requests-input:not([disabled])")
      refute has_element?(view, "#accept-invite-requests-unavailable")
    end

    test "is disabled, and says why, while mail is not configured", %{conn: conn, owner: owner} do
      previous = Application.fetch_env!(:tavern, Tavern.Mailer)
      Application.put_env(:tavern, Tavern.Mailer, provider: nil)
      on_exit(fn -> Application.put_env(:tavern, Tavern.Mailer, previous) end)

      {:ok, view, _html} = live(log_in_as(conn, owner), ~p"/settings?tab=server")

      assert has_element?(view, "#accept-invite-requests-input[disabled]")
      assert has_element?(view, "#accept-invite-requests-unavailable", "MAIL_PROVIDER")
    end
  end

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Tavern.Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end

  defp request!(email, ip \\ "203.0.113.7") do
    {:ok, :received} = Chat.request_invite(%{"email" => email}, ip)
    Repo.get_by!(InviteRequest, email: email)
  end

  defp set_settings!(changes) do
    settings = Repo.one(ServerSettings) || %ServerSettings{name: "Tavern", singleton: true}

    settings
    |> Ecto.Changeset.change(changes)
    |> Repo.insert_or_update!()

    Chat.reset_server_settings_cache()
  end
end
