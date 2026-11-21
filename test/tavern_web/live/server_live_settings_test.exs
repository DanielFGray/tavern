defmodule TavernWeb.ServerLiveSettingsTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits

  test "server settings can update server branding name", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_owner_user(conn)

    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    view
    |> form("#server-settings-form", %{server_settings: %{name: "Orbit HQ"}})
    |> render_submit()

    assert Chat.get_server_settings().name == "Orbit HQ"
    assert render(view) =~ "Orbit HQ"
  end

  test "administrator role surfaces server management controls", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    _owner =
      user_fixture(%{email: "serverlive-owner-admin@example.com", username: "owner_admin_ui"})

    admin_role =
      role_fixture(%{name: "Admin UI", permissions: PermissionBits.combine([:administrator])})

    user =
      user_fixture(%{
        email: "serverlive-admin-ui@example.com",
        username: "serverlive_admin_ui",
        display_name: "Serverlive Admin UI"
      })

    _member_role = member_role_fixture(user, admin_role)
    token = Tavern.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:admin-ui")

    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    assert has_element?(view, "#settings-tab-emoji")
  end

  test "manage_bots permission surfaces bot registry in server settings", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    manager_role =
      role_fixture(%{name: "Bot Manager", permissions: PermissionBits.combine([:manage_bots])})

    user =
      user_fixture(%{
        email: "bot-manager@example.com",
        username: "bot_manager",
        display_name: "Bot Manager"
      })

    _member_role = member_role_fixture(user, manager_role)
    token = Tavern.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:bot-manager")

    {:ok, view, _html} = live(conn, ~p"/settings?tab=bots")

    assert has_element?(view, "#bot-form")
    assert has_element?(view, "#bot-registry-list")
  end

  test "emoji managers can upload and delete custom emoji", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    manager_role =
      role_fixture(%{
        name: "Emoji Manager",
        permissions: PermissionBits.combine([:manage_emojis_and_stickers])
      })

    user =
      user_fixture(%{
        email: "emoji-manager@example.com",
        username: "emoji_manager",
        display_name: "Emoji Manager"
      })

    _member_role = member_role_fixture(user, manager_role)
    token = Tavern.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:emoji-manager")

    {:ok, view, _html} = live(conn, ~p"/settings?tab=emoji")

    png = Tavern.UploadFixtures.unique_png()

    upload =
      file_input(view, "#emoji-form", :emoji_image, [
        %{
          last_modified: 1_711_000_000_000,
          name: "blob.png",
          content: png,
          type: "image/png"
        }
      ])

    render_upload(upload, "blob.png")

    view
    |> form("#emoji-form", %{emoji: %{name: "blobhype", shortcode: ":blobhype:"}})
    |> render_submit()

    emoji = Tavern.Repo.get_by!(Chat.Emoji, name: "blobhype") |> Tavern.Repo.preload(:asset)
    assert has_element?(view, "#manage-emoji-#{emoji.id}")

    assert build_conn() |> get(Chat.asset_url(emoji.asset)) |> response(200) == png

    view |> element("#delete-emoji-#{emoji.id}") |> render_click()
    refute Tavern.Repo.get(Chat.Emoji, emoji.id)
    assert build_conn() |> get(Chat.asset_url(emoji.asset)) |> response(404)
    assert Tavern.ObjectStore.get(emoji.asset.storage_key) == {:error, :not_found}
  end

  test "an emoji delete from a page opened before the role was taken away is refused", %{
    conn: conn
  } do
    Bootstrap.ensure_seed_data!()

    manager_role =
      role_fixture(%{
        name: "Emoji Manager",
        permissions: PermissionBits.combine([:manage_emojis_and_stickers])
      })

    user =
      user_fixture(%{
        email: "stale-manager@example.com",
        username: "stale_manager",
        display_name: "Stale Manager"
      })

    member_role = member_role_fixture(user, manager_role)
    emoji = emoji_fixture(user)
    token = Tavern.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:stale-manager")

    {:ok, view, _html} = live(conn, ~p"/settings?tab=emoji")
    assert has_element?(view, "#delete-emoji-#{emoji.id}")

    Tavern.Repo.delete!(member_role)

    view |> element("#delete-emoji-#{emoji.id}") |> render_click()

    assert Tavern.Repo.get(Chat.Emoji, emoji.id)
    assert render(view) =~ "You do not have permission to manage emojis."
  end

  test "delete_custom_emoji/2 answers not_found for a missing emoji" do
    owner = owner_fixture()

    assert {:error, :not_found} =
             Chat.delete_custom_emoji(
               %Tavern.Accounts.Scope{user_id: owner.id},
               Ecto.UUID.generate()
             )
  end
end
