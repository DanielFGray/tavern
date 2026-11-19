defmodule TavernWeb.BannedLiveTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Chat.Membership
  alias Tavern.Repo

  test "log out link submits DELETE to /logout", %{conn: conn} do
    conn = login_excluded_user(conn, "banned_link", %{"banned" => true})

    {:ok, view, _html} = live(conn, ~p"/banned")

    assert has_element?(view, "#banned-page #logout-link[href='/logout'][data-method='delete']")
  end

  test "a banned member sees the ban page with the reason and ban time", %{conn: conn} do
    conn =
      login_excluded_user(conn, "banned_page", %{
        "banned" => true,
        "ban_reason" => "repeat abuse"
      })

    {:ok, view, _html} = live(conn, ~p"/banned")

    assert has_element?(view, "#banned-page #banned-heading")
    assert has_element?(view, "#banned-page #banned-at")
    assert has_element?(view, "#banned-page #ban-reason")
    assert render(view) =~ "repeat abuse"
    refute has_element?(view, "#removed-page")
    refute has_element?(view, "#removed-heading")
  end

  test "a kicked member sees the removal page and no ban details", %{conn: conn} do
    conn = login_excluded_user(conn, "kicked_page", %{"kicked" => true})

    {:ok, view, _html} = live(conn, ~p"/banned")

    assert has_element?(view, "#removed-page #removed-heading")
    assert has_element?(view, "#removed-page #logout-link[href='/logout'][data-method='delete']")
    refute has_element?(view, "#banned-page")
    refute has_element?(view, "#banned-heading")
    refute has_element?(view, "#banned-at")
    refute has_element?(view, "#ban-reason")
  end

  test "a kicked member rejoins with a code and lands in the app; a banned member has no field",
       %{conn: conn} do
    owner = owner_fixture()
    channel = channel_fixture()
    {:ok, invite} = Tavern.Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id})

    banned_conn = login_excluded_user(conn, "no_field_banned", %{"banned" => true})
    {:ok, banned_view, _html} = live(banned_conn, ~p"/banned")
    refute has_element?(banned_view, "#rejoin-form")

    kicked_conn = login_excluded_user(build_conn(), "field_kicked", %{"kicked" => true})
    {:ok, view, _html} = live(kicked_conn, ~p"/banned")
    assert has_element?(view, "#removed-page #rejoin-form #rejoin-code")

    view |> form("#rejoin-form", invite: %{code: "wrongcode"}) |> render_submit()
    assert has_element?(view, "#rejoin-error")

    view |> form("#rejoin-form", invite: %{code: invite.code}) |> render_submit()
    assert_redirect(view, ~p"/")
  end

  defp login_excluded_user(conn, name, flags) do
    user =
      user_fixture(%{
        email: "#{name}@example.com",
        username: name,
        display_name: name
      })

    user = user_with_membership!(user.id)

    user.membership
    |> Membership.deactivate_changeset(DateTime.utc_now(), flags)
    |> Repo.update!()

    post(conn, ~p"/login", %{
      user: %{email: user.email, password: "supersecurepass"}
    })
  end
end
