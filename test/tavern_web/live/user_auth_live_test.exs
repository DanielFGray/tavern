defmodule TavernWeb.UserAuthLiveTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Tavern.Accounts.LoginRateLimiter
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Invite
  alias Tavern.Repo
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  setup do
    LoginRateLimiter.reset!()
    :ok
  end

  test "registration flow creates account and signs the user in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/register")

    registration_form =
      form(view, "#registration-form", %{
        user: %{
          email: "signup@example.com",
          username: "signup_user",
          display_name: "Signup User",
          password: "supersecurepass"
        }
      })

    render_submit(registration_form)

    conn = follow_trigger_action(registration_form, conn)

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Account created"
  end

  test "registration signs in through the login limiter", %{conn: conn} do
    Enum.each(1..5, fn _attempt ->
      _result = LoginRateLimiter.check_attempt("127.0.0.1", "limited-signup@example.com")
    end)

    {:ok, view, _html} = live(conn, ~p"/register")

    registration_form =
      form(view, "#registration-form", %{
        user: %{
          email: "limited-signup@example.com",
          username: "limited_signup",
          display_name: "Limited Signup",
          password: "supersecurepass"
        }
      })

    render_submit(registration_form)

    conn = follow_trigger_action(registration_form, conn)

    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many login attempts"
  end

  test "registration form validation does not hash the password" do
    changeset =
      Tavern.Accounts.change_registration_user(%Tavern.Chat.User{}, %{
        email: "validate@example.com",
        username: "validate_user",
        display_name: "Validate User",
        password: "supersecurepass"
      })

    assert changeset.valid?
    refute Ecto.Changeset.get_change(changeset, :hashed_password)
  end

  test "first registration signs in the owner", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/register")

    registration_form =
      form(view, "#registration-form", %{
        user: %{
          email: "owner-signup@example.com",
          username: "owner_signup",
          display_name: "Owner Signup",
          password: "supersecurepass"
        }
      })

    render_submit(registration_form)
    conn = follow_trigger_action(registration_form, conn)

    assert redirected_to(conn) == ~p"/"

    member =
      Tavern.Accounts.get_user_by_email("owner-signup@example.com")
      |> Tavern.Repo.preload(:membership)

    assert member.membership.is_owner
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Account created"
  end

  test "a registration page opened before the switch to invite-only is refused", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    open_registration!()
    owner = owner_fixture(%{email: "stale-owner@example.com", username: "stale_owner"})

    {:ok, view, _html} = live(conn, ~p"/register")
    refute has_element?(view, "input[name='user[invite_code]']")

    assert {:ok, _settings} =
             Chat.update_server_settings(scope_for(owner), %{"registration_mode" => "invite_only"})

    view
    |> form("#registration-form", %{
      user: %{
        email: "stale@example.com",
        username: "stale_user",
        display_name: "Stale",
        password: "supersecurepass"
      }
    })
    |> render_submit()

    assert render(view) =~ "An invite code is required to register."
    refute Repo.exists?(from u in Chat.User, where: u.email == "stale@example.com")
  end

  test "invite-only registration asks for a valid invite code", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture(%{email: "invite-owner@example.com", username: "invite_owner"})
    channel = channel_fixture()

    assert {:ok, _settings} =
             Chat.update_server_settings(scope_for(owner), %{"registration_mode" => "invite_only"})

    assert {:ok, invite} = Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id})

    {:ok, view, _html} = live(conn, ~p"/register")
    assert has_element?(view, "input[name='user[invite_code]']")

    # Without a code the registration refuses before it creates an account.
    view
    |> form("#registration-form", %{
      user: %{
        email: "noinvite@example.com",
        username: "noinvite_user",
        display_name: "No Invite",
        password: "supersecurepass"
      }
    })
    |> render_submit()

    assert render(view) =~ "An invite code is required to register."
    refute Repo.exists?(from u in Chat.User, where: u.email == "noinvite@example.com")

    # A bad code is refused the same way.
    view
    |> form("#registration-form", %{
      user: %{
        email: "badcode@example.com",
        username: "badcode_user",
        display_name: "Bad Code",
        password: "supersecurepass",
        invite_code: "notacode"
      }
    })
    |> render_submit()

    assert render(view) =~ "That invite code is not valid."
    refute Repo.exists?(from u in Chat.User, where: u.email == "badcode@example.com")

    # A valid code registers the account and consumes one use.
    registration_form =
      form(view, "#registration-form", %{
        user: %{
          email: "invited@example.com",
          username: "invited_user",
          display_name: "Invited",
          password: "supersecurepass",
          invite_code: invite.code
        }
      })

    render_submit(registration_form)
    conn = follow_trigger_action(registration_form, conn)

    assert redirected_to(conn) == ~p"/"

    member =
      Tavern.Accounts.get_user_by_email("invited@example.com")
      |> Tavern.Repo.preload(:membership)

    assert member.membership.user_id == member.id
    refute member.membership.is_owner
    assert Repo.reload!(Repo.get!(Invite, invite.id)).uses == 1
  end

  test "login redirects authenticated user into server shell", %{conn: conn} do
    user_fixture(%{
      email: "login@example.com",
      username: "login_user",
      display_name: "Login User"
    })

    {:ok, view, _html} = live(conn, ~p"/login")

    login_form =
      form(view, "#login-form", %{
        user: %{
          email: "login@example.com",
          password: "supersecurepass",
          remember_me: "true"
        }
      })

    render_submit(login_form)

    conn = follow_trigger_action(login_form, conn)

    assert redirected_to(conn) == ~p"/"
  end

  test "server shell requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  test "login rate limiting blocks repeated invalid attempts", %{conn: conn} do
    user_fixture(%{email: "ratelimit@example.com", username: "ratelimit_user"})

    attempts =
      Enum.map(1..6, fn _attempt ->
        conn
        |> recycle()
        |> post(~p"/login", %{
          user: %{email: "ratelimit@example.com", password: "wrongpass", remember_me: "false"}
        })
      end)

    assert Phoenix.Flash.get(Enum.at(attempts, 4).assigns.flash, :error) ==
             "Invalid email or password."

    assert Phoenix.Flash.get(List.last(attempts).assigns.flash, :error) =~
             "Too many login attempts"
  end

  test "authenticated user can open server shell and post as self", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    user_fixture(%{
      email: "server@example.com",
      username: "server_user",
      display_name: "Server User"
    })

    {:ok, login_view, _html} = live(conn, ~p"/login")

    login_form =
      form(login_view, "#login-form", %{
        user: %{email: "server@example.com", password: "supersecurepass"}
      })

    render_submit(login_form)

    conn = follow_trigger_action(login_form, conn)

    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    view |> element("#user-menu-button") |> render_click()
    assert has_element?(view, "#logout-link")
    assert has_element?(view, "#user-menu-settings")
    assert render(view) =~ "@server_user"

    html =
      view
      |> form("#message-form", %{message: %{body: "auth works"}})
      |> render_submit()

    assert html =~ "auth works"
    assert render(view) =~ "Server User"
  end

  test "banned user login redirects to banned screen", %{conn: conn} do
    banned_user =
      user_fixture(%{
        email: "banned@example.com",
        username: "banned_user",
        display_name: "Banned User"
      })

    banned_user = user_with_membership!(banned_user.id)

    banned_user.membership
    |> Tavern.Chat.Membership.deactivate_changeset(DateTime.utc_now(), %{
      "banned" => true,
      "ban_reason" => "repeat abuse"
    })
    |> Tavern.Repo.update!()

    {:ok, login_view, _html} = live(conn, ~p"/login")

    login_form =
      form(login_view, "#login-form", %{
        user: %{email: "banned@example.com", password: "supersecurepass"}
      })

    render_submit(login_form)

    conn = follow_trigger_action(login_form, conn)

    assert redirected_to(conn) == ~p"/banned"

    {:ok, banned_view, _html} = live(conn, ~p"/banned")
    assert render(banned_view) =~ "repeat abuse"
  end
end
