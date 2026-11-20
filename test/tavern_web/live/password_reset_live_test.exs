defmodule TavernWeb.PasswordResetLiveTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Accounts.LoginRateLimiter
  alias Tavern.Bootstrap

  setup do
    LoginRateLimiter.reset!()
    Bootstrap.ensure_seed_data!()
    :ok
  end

  test "the login page links to the request page while mail works", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")
    assert has_element?(view, ~s(#forgot-password[href="/users/reset-password"]))
  end

  test "the login page hides the link while no mail provider is set", %{conn: conn} do
    without_mail()

    {:ok, view, _html} = live(conn, ~p"/login")
    refute has_element?(view, "#forgot-password")
  end

  test "the request page explains that reset is unavailable without mail", %{conn: conn} do
    without_mail()

    {:ok, view, _html} = live(conn, ~p"/users/reset-password")
    assert has_element?(view, "#password-reset-unavailable")
    refute has_element?(view, "#password-reset-request-form")
  end

  test "an email with an account and one without get the same reply", %{conn: conn} do
    user = user_fixture(%{email: "known@example.com"})

    replies =
      for email <- [user.email, "stranger@example.com"] do
        {:ok, view, _html} = live(conn, ~p"/users/reset-password")

        view
        |> form("#password-reset-request-form", reset: %{email: email})
        |> render_submit()

        view |> element("#password-reset-sent") |> render()
      end

    assert [reply, reply] = replies
    assert_receive {:mail_captured, %{to: "known@example.com"}}
    refute_receive {:mail_captured, _}, 150
  end

  test "the request form stops answering after too many attempts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/reset-password")

    for _ <- 1..5 do
      {:ok, view, _html} = live(conn, ~p"/users/reset-password")

      view
      |> form("#password-reset-request-form", reset: %{email: "x@example.com"})
      |> render_submit()

      assert has_element?(view, "#password-reset-sent")
    end

    html =
      view
      |> form("#password-reset-request-form", reset: %{email: "x@example.com"})
      |> render_submit()

    assert html =~ "Too many attempts"
    refute has_element?(view, "#password-reset-sent")
  end

  test "the link's page sets a new password and sends the member to log in", %{conn: conn} do
    user = user_fixture()
    token = reset_token(user)
    session = Accounts.generate_user_session_token(user)

    {:ok, view, _html} = live(conn, ~p"/users/reset-password/#{token}")
    assert has_element?(view, "#password-reset-form")

    assert view
           |> form("#password-reset-form", user: %{password: "short"})
           |> render_change() =~ "should be at least 12 character"

    {:ok, login_conn} =
      view
      |> form("#password-reset-form", user: %{password: "a brand new password"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/login")

    assert html_response(login_conn, 200) =~ "Your password is changed"
    assert is_nil(Accounts.get_user_by_session_token(session))
    assert Accounts.get_user_by_email_and_password(user.email, "a brand new password")
  end

  test "a used link shows the error and a way to ask again", %{conn: conn} do
    user = user_fixture()
    token = reset_token(user)
    {:ok, _} = Accounts.reset_user_password(token, %{"password" => "a brand new password"})

    {:ok, view, _html} = live(conn, ~p"/users/reset-password/#{token}")
    assert has_element?(view, "#password-reset-invalid")
    assert has_element?(view, "#request-new-reset")
    refute has_element?(view, "#password-reset-form")
  end

  test "a link spent while the form is open shows the error on save", %{conn: conn} do
    user = user_fixture()
    token = reset_token(user)

    {:ok, view, _html} = live(conn, ~p"/users/reset-password/#{token}")
    {:ok, _} = Accounts.reset_user_password(token, %{"password" => "a brand new password"})

    view
    |> form("#password-reset-form", user: %{password: "another new password"})
    |> render_submit()

    assert has_element?(view, "#password-reset-invalid")
  end

  test "the link works for a signed-in member too", %{conn: conn} do
    user = user_fixture()
    token = reset_token(user)

    {:ok, view, _html} = live(log_in(conn, user), ~p"/users/reset-password/#{token}")
    assert has_element?(view, "#password-reset-form")
  end

  defp reset_token(user) do
    :ok =
      Accounts.request_password_reset(
        user.email,
        "198.51.100.#{System.unique_integer([:positive])}"
      )

    assert_receive {:mail_captured, %{to: to, text: text}}
    assert to == user.email
    [token] = Regex.run(~r{/users/reset-password/(\S+)}, text, capture: :all_but_first)
    token
  end

  defp log_in(conn, user) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp without_mail do
    previous = Application.get_env(:tavern, Tavern.Mailer)
    Application.put_env(:tavern, Tavern.Mailer, provider: nil)
    on_exit(fn -> Application.put_env(:tavern, Tavern.Mailer, previous) end)
  end
end
