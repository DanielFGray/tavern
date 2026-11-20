defmodule Tavern.Chat.MediaAssetsTest do
  @moduledoc """
  An upload's type comes from its bytes, and its object reaches the store only after the write
  that uses it.
  """
  use Tavern.DataCase, async: true

  import Tavern.ChatFixtures
  import Tavern.UploadFixtures

  alias Tavern.Chat
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.ObjectStore

  setup do
    %{scope: scope_for(owner_fixture())}
  end

  test "image_type/1 reads magic bytes" do
    assert MediaAssets.image_type(unique_png()) == {:ok, "image/png"}
    assert MediaAssets.image_type(<<0xFF, 0xD8, 0xFF, 0xE0>>) == {:ok, "image/jpeg"}
    assert MediaAssets.image_type("GIF87a....") == {:ok, "image/gif"}
    assert MediaAssets.image_type("GIF89a....") == {:ok, "image/gif"}
    assert MediaAssets.image_type("RIFF\0\0\0\0WEBPVP8 ") == {:ok, "image/webp"}
    assert MediaAssets.image_type("<svg></svg>") == :error
    assert MediaAssets.image_type("") == :error
  end

  test "a file that is not an image is refused, whatever the client said it was", ctx do
    upload = upload("pic.png", "image/png", "<svg onload=alert(1)></svg>")

    assert MediaAssets.store_upload(ctx.scope, upload, :emoji, &{:ok, &1}) ==
             {:error, :invalid_upload_type}

    refute stored?(upload.body)
    refute Repo.exists?(MediaAsset)
  end

  test "the stored type and extension come from the bytes, not the name or claimed type", ctx do
    jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, "#{System.unique_integer([:positive])}">>
    upload = upload("pic.png", "image/png", jpeg)

    assert {:ok, asset} = MediaAssets.store_upload(ctx.scope, upload, :emoji, &{:ok, &1})

    assert asset.content_type == "image/jpeg"
    assert asset.original_filename == "pic.png"
    assert String.ends_with?(asset.storage_key, ".jpg")
    assert ObjectStore.get(asset.storage_key) == {:ok, jpeg, "image/jpeg"}
  end

  test "a write that fails after the asset row stores no object", ctx do
    upload = png_upload()

    assert MediaAssets.store_upload(ctx.scope, upload, :emoji, fn _asset -> {:error, :refused} end) ==
             {:error, :refused}

    refute stored?(upload.body)
  end

  test "an emoji refused for a taken shortcode stores no object", ctx do
    first = png_upload("party.png")
    attrs = %{"name" => "party", "shortcode" => ":party:"}
    assert {:ok, _emoji} = Chat.create_custom_emoji(ctx.scope, first, attrs)

    second = png_upload("party.png")

    assert {:error, %Ecto.Changeset{}} =
             Chat.create_custom_emoji(ctx.scope, second, %{attrs | "name" => "party again"})

    assert stored?(first.body)
    refute stored?(second.body)
  end
end
