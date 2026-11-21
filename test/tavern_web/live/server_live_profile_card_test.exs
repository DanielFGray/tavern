defmodule TavernWeb.ServerLiveProfileCardTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn, "card")
    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view, viewer: current_user_from_conn(conn)}
  end

  test "no card is open until one is asked for", %{view: view} do
    assert has_element?(view, "#profile-card-root")
    refute has_element?(view, "#profile-card")
  end

  test "a member's card shows name, username, bio, roles and join date", %{view: view} do
    member =
      user_fixture(%{
        username: "card_target",
        display_name: "Card Target",
        bio: "Hello **there**"
      })

    role = role_fixture(%{name: "Cardholders", position: 3, color: 0xFF8800})
    member_role_fixture(member, role)

    render_hook(view, "show_profile", %{"user_id" => member.id})

    assert has_element?(view, "#profile-card-name", "Card Target")
    assert has_element?(view, "#profile-card-username", "@card_target")
    assert has_element?(view, ~s(#profile-card-bio[data-markdown-source="Hello **there**"]))
    assert has_element?(view, "#profile-card-role-#{role.id}", "Cardholders")
    refute has_element?(view, "#profile-card-owner")
    refute has_element?(view, "#profile-card-bot")
  end

  test "the card can be found by username, which is how an @mention names a member", %{view: view} do
    user_fixture(%{username: "by_name", display_name: "By Name"})

    render_hook(view, "show_profile", %{"username" => "by_name"})

    assert has_element?(view, "#profile-card-name", "By Name")
  end

  test "an owner and a bot carry their badges", %{view: view} do
    owner = owner_fixture(%{username: "badge_owner"})
    bot = bot_fixture(owner)

    render_hook(view, "show_profile", %{"user_id" => owner.id})
    assert has_element?(view, "#profile-card-owner")

    render_hook(view, "show_profile", %{"user_id" => bot.id})
    assert has_element?(view, "#profile-card-bot")
    refute has_element?(view, "#profile-card-owner")
  end

  test "a card without a bio or roles omits those sections", %{view: view} do
    member = user_fixture(%{username: "bare_card", bio: nil})

    render_hook(view, "show_profile", %{"user_id" => member.id})

    assert has_element?(view, "#profile-card")
    refute has_element?(view, "#profile-card-bio")
    refute has_element?(view, "#profile-card-roles")
  end

  test "a newer request replaces the card, and hide closes it", %{view: view} do
    first = user_fixture(%{username: "first_card", display_name: "First Card"})
    second = user_fixture(%{username: "second_card", display_name: "Second Card"})

    render_hook(view, "show_profile", %{"user_id" => first.id})
    render_hook(view, "show_profile", %{"user_id" => second.id})
    assert has_element?(view, "#profile-card-name", "Second Card")
    refute has_element?(view, "#profile-card-name", "First Card")

    render_hook(view, "hide_profile", %{})
    refute has_element?(view, "#profile-card")
  end

  test "a deleted account, an unknown name and a malformed id open no card", %{view: view} do
    gone = user_fixture(%{username: "gone_card"})
    {:ok, _} = Accounts.delete_account(gone.id)

    for params <- [
          %{"user_id" => gone.id},
          %{"username" => "gone_card"},
          %{"username" => "nobody_here"},
          %{"user_id" => "not-a-uuid"},
          %{}
        ] do
      render_hook(view, "show_profile", params)
      refute has_element?(view, "#profile-card"), inspect(params)
    end
  end

  test "an open card closes when the next request finds nothing", %{view: view} do
    member = user_fixture(%{username: "then_gone"})

    render_hook(view, "show_profile", %{"user_id" => member.id})
    assert has_element?(view, "#profile-card")

    render_hook(view, "show_profile", %{"username" => "nobody_here"})
    refute has_element?(view, "#profile-card")
  end

  test "a member row and a message author carry the trigger attribute", %{
    view: view,
    viewer: viewer
  } do
    await_hydration(view)

    assert has_element?(
             view,
             ~s(#member-presence-#{viewer.id} [data-profile-user-id="#{viewer.id}"])
           )
  end
end
