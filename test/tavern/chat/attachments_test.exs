defmodule Tavern.Chat.AttachmentsTest do
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.Attachments
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.MessageAttachment
  alias Tavern.Chat.PermissionBits
  alias Tavern.UploadFixtures

  setup do
    Tavern.Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    channel = channel_fixture(%{name: "Lobby"})
    %{owner: owner, channel: channel, member: user_fixture()}
  end

  describe "sending with attachments" do
    test "an image and a file are stored, typed from their bytes, in order", ctx do
      image = UploadFixtures.png_upload("cat.png")
      file = UploadFixtures.upload("../../notes.txt", "image/png", "plain words")

      assert {:ok, message} =
               Chat.create_message(scope_for(ctx.member), ctx.channel.id, %{"body" => "look"}, [
                 image,
                 file
               ])

      assert [first, second] = Enum.sort_by(message.attachments, & &1.position)
      assert %MessageAttachment{kind: :image, asset: %{content_type: "image/png"}} = first
      assert first.asset.original_filename == "cat.png"
      assert first.asset.kind == :attachment
      assert first.asset.uploader_id == ctx.member.id

      # The client called it a PNG; the bytes say otherwise. The directory part is dropped.
      assert %MessageAttachment{kind: :file} = second
      assert second.asset.content_type == "application/octet-stream"
      assert second.asset.original_filename == "notes.txt"

      assert UploadFixtures.stored?(image.body)
      assert UploadFixtures.stored?(file.body)
    end

    test "a message may carry attachments and no text", ctx do
      upload = UploadFixtures.png_upload()

      assert {:ok, message} =
               Chat.create_message(scope_for(ctx.member), ctx.channel.id, %{"body" => "  "}, [
                 upload
               ])

      assert message.body == ""
      assert [_] = message.attachments

      assert {:error, changeset} =
               Chat.create_message(scope_for(ctx.member), ctx.channel.id, %{"body" => " "})

      assert %{body: [_]} = errors_on(changeset)
    end

    test "editing such a message to no text keeps it valid", ctx do
      {:ok, message} =
        Chat.create_message(scope_for(ctx.member), ctx.channel.id, %{"body" => "caption"}, [
          UploadFixtures.png_upload()
        ])

      assert {:ok, edited} =
               Chat.update_message(scope_for(ctx.member), message.id, %{"body" => ""})

      assert edited.body == ""
    end

    test "without attach_files the send is refused and nothing is stored", ctx do
      everyone = default_role()

      {:ok, _} =
        Chat.put_overwrite(
          scope_for(ctx.owner),
          ctx.channel.id,
          {:role, everyone.id},
          0,
          PermissionBits.combine([:attach_files])
        )

      upload = UploadFixtures.png_upload()

      assert {:error, :attach_files_forbidden} =
               Chat.create_message(scope_for(ctx.member), ctx.channel.id, %{"body" => "hi"}, [
                 upload
               ])

      refute UploadFixtures.stored?(upload.body)
      assert Repo.aggregate(MediaAsset, :count) == 0
      refute Chat.channel_abilities(scope_for(ctx.member), ctx.channel.id).attach_files

      # Text alone still goes through.
      assert {:ok, _} =
               Chat.create_message(scope_for(ctx.member), ctx.channel.id, %{"body" => "hi"})
    end

    test "too many files or one too large is refused before any write", ctx do
      uploads = for _ <- 0..Attachments.max_count(), do: UploadFixtures.png_upload()

      assert {:error, :too_many_attachments} =
               Chat.create_message(
                 scope_for(ctx.member),
                 ctx.channel.id,
                 %{"body" => "x"},
                 uploads
               )

      big = UploadFixtures.upload("big.bin", "", :binary.copy("a", Attachments.max_bytes() + 1))

      assert {:error, :attachment_too_large} =
               Chat.create_message(scope_for(ctx.member), ctx.channel.id, %{"body" => "x"}, [big])

      assert messages_in(ctx.channel.id) == []
    end
  end

  describe "reading attachments" do
    setup ctx do
      upload = UploadFixtures.png_upload()

      {:ok, message} =
        Chat.create_message(scope_for(ctx.member), ctx.channel.id, %{"body" => "pic"}, [upload])

      [attachment] = message.attachments
      %{message: message, attachment: attachment, upload: upload}
    end

    test "a member who may view the message gets the bytes", ctx do
      assert {:ok, %MessageAttachment{}, body} =
               Attachments.fetch(scope_for(ctx.owner), ctx.attachment.id)

      assert body == ctx.upload.body
    end

    test "a member who may not view the channel is told it does not exist", ctx do
      outsider = user_fixture()

      {:ok, _} =
        Chat.put_overwrite(
          scope_for(ctx.owner),
          ctx.channel.id,
          {:user, outsider.id},
          0,
          PermissionBits.combine([:view_channel])
        )

      assert {:error, :not_found} = Attachments.fetch(scope_for(outsider), ctx.attachment.id)
      assert {:error, :not_found} = Attachments.fetch(scope_for(outsider), Ecto.UUID.generate())
      assert {:error, :not_found} = Attachments.fetch(scope_for(outsider), "not-a-uuid")
    end

    test "the public uploads route never serves an attachment", ctx do
      assert {:error, :not_found} = MediaAssets.fetch_upload(ctx.attachment.asset.storage_key)
    end

    test "the message carries its attachments when read again", ctx do
      {:ok, messages} = Chat.list_messages(scope_for(ctx.owner), ctx.channel.id)
      assert [%{attachments: [%MessageAttachment{asset: %MediaAsset{}}]}] = messages
    end

    test "deleting the message deletes its attachments and their objects", ctx do
      assert {:ok, deleted} = Chat.delete_message(scope_for(ctx.member), ctx.message.id)
      assert deleted.attachments == []
      refute Repo.get(MessageAttachment, ctx.attachment.id)
      refute Repo.get(MediaAsset, ctx.attachment.asset_id)
      refute UploadFixtures.stored?(ctx.upload.body)
    end
  end

  test "url/1 ends in the file name, escaped" do
    attachment = %MessageAttachment{
      id: "abc",
      asset: %MediaAsset{original_filename: "my cat?.png", content_type: "image/png"}
    }

    assert Attachments.url(attachment) == "/attachments/abc/my%20cat%3F.png"
  end
end
