defmodule TavernWeb.VerificationLiveTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Accounts
  alias Tavern.Accounts.LoginRateLimiter
  alias Tavern.Bootstrap
  alias Tavern.Chat.User
  alias Tavern.Repo

  setup do
    LoginRateLimiter.reset!()
    Bootstrap.ensure_seed_data!()
    open_registration!()
    %{owner: owner_fixture()}
  end

  test "registration mails a confirmation link to the new member", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/register")

    view
    |> form("#registration-form", %{
      user: %{
        email: "newcomer@example.com",
        username: "newcomer",
        display_name: "Newcomer",
        password: "supersecurepass"
      }
    })
    |> render_submit()

    assert_receive {:mail_captured, %{to: "newcomer@example.com", text: text}}
    assert text =~ "/users/confirm/"
    assert is_nil(Repo.get_by!(User, email: "newcomer@example.com").confirmed_at)
  end

  test "an unverified member sees the banner and a composer that names the reason", %{conn: conn} do
    user = unverified_user_fixture(%{email: "pending@example.com"})

    {:ok, view, _html} = live_hydrated(log_in(conn, user), ~p"/")

    assert has_element?(view, "#verification-banner", "pending@example.com")
    assert has_element?(view, "#composer-locked-notice", "Verify your email to send messages.")
    refute has_element?(view, "#message-form")
  end

  test "resend mails a fresh link and then hits the limit", %{conn: conn} do
    user = unverified_user_fixture(%{email: "resend@example.com"})
    {:ok, view, _html} = live_hydrated(log_in(conn, user), ~p"/")

    for _ <- 1..3 do
      view |> element("#resend-verification") |> render_click()
      assert_receive {:mail_captured, %{to: "resend@example.com"}}
    end

    assert view |> element("#resend-verification") |> render_click() =~
             "You can ask for another link in"

    refute_receive {:mail_captured, _}
  end

  test "opening the link verifies the member, who can then send", %{conn: conn} do
    user = unverified_user_fixture(%{email: "opener@example.com"})
    conn = log_in(conn, user)

    :ok = Accounts.deliver_user_confirmation_instructions(user)
    assert_receive {:mail_captured, %{text: text}}
    [path] = Regex.run(~r{/users/confirm/\S+}, text)

    confirmed_conn = get(conn, path)
    assert redirected_to(confirmed_conn) == ~p"/"
    assert Phoenix.Flash.get(confirmed_conn.assigns.flash, :info) =~ "Your email is confirmed"

    {:ok, view, _html} = live_hydrated(conn, ~p"/")
    refute has_element?(view, "#verification-banner")
    assert has_element?(view, "#message-form")

    assert redirected_to(get(conn, path)) == ~p"/"
  end

  test "an open view unlocks when the member verifies in another tab", %{conn: conn, owner: owner} do
    user = unverified_user_fixture(%{email: "other-tab@example.com"})
    {:ok, view, _html} = live_hydrated(log_in(conn, user), ~p"/")
    {:ok, owner_view, _html} = live_hydrated(log_in(build_conn(), owner), ~p"/")

    assert has_element?(view, "#composer-locked-notice")
    assert has_element?(owner_view, "#member-unverified-#{user.id}")

    :ok = Accounts.deliver_user_confirmation_instructions(user)
    assert_receive {:mail_captured, %{text: text}}
    [token] = Regex.run(~r{/users/confirm/(\S+)}, text, capture: :all_but_first)
    assert {:ok, _user} = Accounts.confirm_user(token)

    refute has_element?(view, "#verification-banner")
    refute has_element?(view, "#composer-locked-notice")
    assert has_element?(view, "#message-form")
    refute has_element?(owner_view, "#member-unverified-#{user.id}")
  end

  test "a verified member sees no banner", %{conn: conn} do
    {:ok, view, _html} = live_hydrated(log_in(conn, user_fixture()), ~p"/")
    refute has_element?(view, "#verification-banner")
  end

  test "the unverified badge shows only to members who can manage roles", %{
    conn: conn,
    owner: owner
  } do
    pending = unverified_user_fixture()
    member = user_fixture()

    {:ok, owner_view, _html} = live_hydrated(log_in(conn, owner), ~p"/")
    assert has_element?(owner_view, "#member-unverified-#{pending.id}")
    refute has_element?(owner_view, "#member-unverified-#{member.id}")

    {:ok, member_view, _html} = live_hydrated(log_in(build_conn(), member), ~p"/")
    assert has_element?(member_view, "#member-presence-#{pending.id}")
    refute has_element?(member_view, "#member-unverified-#{pending.id}")
  end

  test "Settings says why verification is inactive when no mail provider is set", %{
    conn: conn,
    owner: owner
  } do
    previous = Application.get_env(:tavern, Tavern.Mailer)
    Application.put_env(:tavern, Tavern.Mailer, provider: nil)
    on_exit(fn -> Application.put_env(:tavern, Tavern.Mailer, previous) end)

    {:ok, view, _html} = live(log_in(conn, owner), ~p"/settings?tab=roles")
    assert has_element?(view, "#verification-inactive", "MAIL_PROVIDER")
  end

  defp log_in(conn, user) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
