defmodule Tavern.Chat.ServerConfigTest do
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures
  import Tavern.UploadFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat.Emoji
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.ServerConfig
  alias Tavern.Chat.ServerConfigListener
  alias Tavern.Chat.ServerSettings
  alias Tavern.Chat.Topics
  alias Tavern.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    :ok
  end

  test "update_server_settings ignores a client icon_asset_id pointing at an emoji asset" do
    owner = owner_fixture()
    emoji = emoji_fixture(owner)
    asset = emoji.asset

    assert {:ok, settings} =
             ServerConfig.update_server_settings(scope_for(owner), %{
               "name" => "HQ",
               "icon_asset_id" => asset.id
             })

    assert settings.name == "HQ"
    assert is_nil(settings.icon_asset_id)
    assert Repo.get(MediaAsset, asset.id)
    assert Repo.get(Emoji, emoji.id)
  end

  test "a later icon upload does not delete an emoji that was never the icon" do
    owner = owner_fixture()
    emoji = emoji_fixture(owner)
    asset = emoji.asset

    assert {:ok, _} =
             ServerConfig.update_server_settings(scope_for(owner), %{
               "name" => "HQ",
               "icon_asset_id" => asset.id
             })

    upload = png_upload("first.png")

    assert {:ok, settings} =
             ServerConfig.update_server_settings(scope_for(owner), %{
               "name" => "HQ",
               "icon_upload" => upload
             })

    assert settings.icon_asset.kind == :server_icon
    assert settings.icon_asset_id != asset.id
    assert Repo.get(MediaAsset, asset.id)
    assert Repo.get(Emoji, emoji.id)
  end

  test "remove_server_icon clears the icon and deletes the old server-icon asset" do
    owner = owner_fixture()
    upload = png_upload("keep-then-remove.png")

    assert {:ok, settings} =
             ServerConfig.update_server_settings(scope_for(owner), %{
               "name" => "HQ",
               "icon_upload" => upload
             })

    icon_id = settings.icon_asset_id

    assert {:ok, cleared} = ServerConfig.remove_server_icon(scope_for(owner))

    assert is_nil(cleared.icon_asset_id)
    assert is_nil(Repo.get(MediaAsset, icon_id))
  end

  test "an upload replaces the icon and deletes the previous server-icon asset" do
    owner = owner_fixture()
    first = png_upload("first.png")

    assert {:ok, settings} =
             ServerConfig.update_server_settings(scope_for(owner), %{
               "name" => "HQ",
               "icon_upload" => first
             })

    first_id = settings.icon_asset_id

    second = png_upload("second.png")

    assert {:ok, replaced} =
             ServerConfig.update_server_settings(scope_for(owner), %{
               "name" => "HQ",
               "icon_upload" => second
             })

    assert replaced.icon_asset_id != first_id
    assert replaced.icon_asset.kind == :server_icon
    assert is_nil(Repo.get(MediaAsset, first_id))
    assert Repo.get(MediaAsset, replaced.icon_asset_id)
    refute stored?(first.body)
    assert stored?(second.body)
  end

  test "a refused settings write keeps the old icon and stores no new object" do
    owner = owner_fixture()
    first = png_upload("first.png")

    assert {:ok, settings} =
             ServerConfig.update_server_settings(scope_for(owner), %{
               "name" => "HQ",
               "icon_upload" => first
             })

    second = png_upload("second.png")

    assert {:error, %Ecto.Changeset{}} =
             ServerConfig.update_server_settings(scope_for(owner), %{
               "name" => String.duplicate("x", 101),
               "icon_upload" => second
             })

    assert ServerConfig.get_server_settings().icon_asset_id == settings.icon_asset_id
    assert stored?(first.body)
    refute stored?(second.body)
  end

  test "remove_server_icon leaves a non-server-icon asset in place when clearing the pointer" do
    owner = owner_fixture()
    emoji = emoji_fixture(owner)
    asset = emoji.asset

    settings =
      case Repo.one(from(s in ServerSettings, preload: [:icon_asset])) do
        nil -> %ServerSettings{name: "HQ", singleton: true}
        row -> row
      end

    {:ok, _} =
      settings
      |> Ecto.Changeset.change(%{icon_asset_id: asset.id, name: "HQ", singleton: true})
      |> Repo.insert_or_update()

    assert {:ok, cleared} = ServerConfig.remove_server_icon(scope_for(owner))

    assert is_nil(cleared.icon_asset_id)
    assert Repo.get(MediaAsset, asset.id)
    assert Repo.get(Emoji, emoji.id)
  end

  test "a settings write drops this node's cached copy and announces the change" do
    owner = owner_fixture()
    :ok = Topics.subscribe_server_settings()
    _ = ServerConfig.get_server_settings()

    assert {:ok, _} = ServerConfig.update_server_settings(scope_for(owner), %{"name" => "HQ"})

    assert_receive :server_settings_changed
    assert ServerConfig.get_server_settings().name == "HQ"
  end

  test "a settings change committed elsewhere replaces this node's cached copy on the broadcast" do
    cached = ServerConfig.get_server_settings()

    # Another node's write: the row changes, and this node's cache is not told.
    {:ok, _} =
      cached
      |> Ecto.Changeset.change(%{name: "Changed elsewhere"})
      |> Repo.insert_or_update()

    assert ServerConfig.get_server_settings().name == cached.name

    Topics.broadcast_server_settings_changed()
    _ = :sys.get_state(ServerConfigListener)

    assert ServerConfig.get_server_settings().name == "Changed elsewhere"
  end
end
