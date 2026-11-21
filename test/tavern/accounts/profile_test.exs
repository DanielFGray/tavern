defmodule Tavern.Accounts.ProfileTest do
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Chat.MediaAsset
  alias Tavern.Repo
  alias Tavern.UploadFixtures

  setup do
    Tavern.Bootstrap.ensure_seed_data!()
    %{user: user_fixture()}
  end

  describe "bio" do
    test "holds up to 300 characters", %{user: user} do
      assert {:ok, user} =
               Accounts.update_profile_user(user, %{"bio" => String.duplicate("a", 300)})

      assert String.length(user.bio) == 300

      assert {:error, changeset} =
               Accounts.update_profile_user(user, %{"bio" => String.duplicate("a", 301)})

      assert %{bio: [_]} = errors_on(changeset)
    end
  end

  describe "avatar" do
    test "a chosen file becomes the avatar and its bytes are stored", %{user: user} do
      upload = UploadFixtures.png_upload("me.png")

      assert {:ok, user} = Accounts.update_profile_user(user, %{}, {:replace, upload})

      assert %MediaAsset{kind: :avatar, content_type: "image/png"} = user.avatar_asset
      assert user.avatar_asset.uploader_id == user.id
      assert UploadFixtures.stored?(upload.body)
    end

    test "replacing drops the old row and its object", %{user: user} do
      first = UploadFixtures.png_upload()
      {:ok, user} = Accounts.update_profile_user(user, %{}, {:replace, first})
      old_id = user.avatar_asset_id

      second = UploadFixtures.png_upload()
      {:ok, user} = Accounts.update_profile_user(user, %{}, {:replace, second})

      refute user.avatar_asset_id == old_id
      refute Repo.get(MediaAsset, old_id)
      refute UploadFixtures.stored?(first.body)
      assert UploadFixtures.stored?(second.body)
    end

    test "removing clears the avatar and deletes the row and object", %{user: user} do
      upload = UploadFixtures.png_upload()
      {:ok, user} = Accounts.update_profile_user(user, %{}, {:replace, upload})
      old_id = user.avatar_asset_id

      assert {:ok, user} = Accounts.update_profile_user(user, %{}, :remove)

      assert user.avatar_asset_id == nil
      refute Repo.get(MediaAsset, old_id)
      refute UploadFixtures.stored?(upload.body)
    end

    test "a file that is not an image is refused and nothing changes", %{user: user} do
      fake = UploadFixtures.upload("me.png", "image/png", "not an image")

      assert {:error, :invalid_upload_type} =
               Accounts.update_profile_user(user, %{"bio" => "new"}, {:replace, fake})

      reloaded = Repo.get!(Tavern.Chat.User, user.id)
      assert reloaded.avatar_asset_id == nil
      assert reloaded.bio == user.bio
    end

    test "an invalid field keeps the old avatar and stores no new object", %{user: user} do
      first = UploadFixtures.png_upload()
      {:ok, user} = Accounts.update_profile_user(user, %{}, {:replace, first})

      second = UploadFixtures.png_upload()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_profile_user(user, %{"display_name" => ""}, {:replace, second})

      assert Repo.get!(Tavern.Chat.User, user.id).avatar_asset_id == user.avatar_asset_id
      assert UploadFixtures.stored?(first.body)
      refute UploadFixtures.stored?(second.body)
    end
  end

  describe "get_profile/2" do
    test "a viewer who has left the server gets no card", %{user: user} do
      viewer = user_fixture()
      {:ok, _} = Accounts.delete_account(viewer.id)

      assert Accounts.get_profile(scope_for(viewer), {:id, user.id}) == nil
    end

    test "lists roles highest first and leaves out the default role", %{user: user} do
      low = role_fixture(%{name: "Low", position: 1})
      high = role_fixture(%{name: "High", position: 2})
      member_role_fixture(user, low)
      member_role_fixture(user, high)

      card = Accounts.get_profile(scope_for(user), {:id, user.id})

      assert Enum.map(card.roles, & &1.name) == ["High", "Low"]
      assert card.status in [:online, :recent, :offline]
    end
  end
end
