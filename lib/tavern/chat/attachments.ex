defmodule Tavern.Chat.Attachments do
  @moduledoc """
  Files a member attaches to a message they send (docs/design/attachments.md).

  A send hands its uploads to `prepare/2`, which reads each file and builds the attachment and
  its asset row. The message insert writes those rows (`Tavern.Chat.Message.create_changeset/3`),
  and `store_objects/1` puts the bytes in `Tavern.ObjectStore` inside the same transaction, so a
  failed put rolls the message back.

  An attachment is served only to a member who may view its message (`fetch/2`), never by the
  public `/uploads` route. Deleting a message deletes its attachments (`delete_for_message/1`).
  """

  import Ecto.Query, only: [from: 2]

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageAttachment
  alias Tavern.Chat.Visibility
  alias Tavern.ObjectStore
  alias Tavern.Repo

  @max_count 10
  @max_bytes 10_000_000
  @max_filename_length 200

  @doc "How many files one message may carry."
  def max_count, do: @max_count

  @doc "The largest file, in bytes, a message may carry."
  def max_bytes, do: @max_bytes

  @doc """
  Reads `uploads` (`%{path:, client_name:}`, as a LiveView upload hands them over) and builds the
  message's attachments, in order, each with an unsaved asset whose bytes are in its virtual
  `body` field for `store_objects/1`. The content type comes from the bytes: PNG, JPEG, GIF and WebP are images
  shown inline (`MediaAssets.image_type/1`); anything else is `application/octet-stream`, which
  the app serves only as a download. The client's claimed type is never used.

  More than `max_count/0` files is `{:error, :too_many_attachments}`, and a file over
  `max_bytes/0` is `{:error, :attachment_too_large}`.
  """
  def prepare(%Scope{}, []), do: {:ok, []}

  def prepare(%Scope{}, uploads) when length(uploads) > @max_count,
    do: {:error, :too_many_attachments}

  def prepare(%Scope{} = scope, uploads) when is_list(uploads) do
    uploads
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {upload, position}, {:ok, built} ->
      case build(scope, upload, position) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | built]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end
  end

  @doc """
  Puts the bytes of the inserted `message`'s attachments in the object store. Call it inside the
  transaction that inserted them, which must return the error so the rows roll back. Objects put
  before a failed one stay in the store with no row naming them, so no route serves them.
  """
  def store_objects(%Message{attachments: attachments}) when is_list(attachments) do
    Enum.reduce_while(attachments, :ok, fn %MessageAttachment{asset: asset}, :ok ->
      case ObjectStore.put(asset.storage_key, asset.body, asset.content_type) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  The attachment `attachment_id` with its asset and bytes, as `{:ok, attachment, body}`, when the
  scope may view its message now. A missing id, a deleted message and a message the scope may not
  view are all `{:error, :not_found}`, so the answer never tells which.
  """
  def fetch(%Scope{} = scope, attachment_id) do
    with {:ok, attachment_id} <- Ecto.UUID.cast(attachment_id),
         %MessageAttachment{} = attachment <-
           Repo.get(MessageAttachment, attachment_id) |> Repo.preload(:asset),
         %Message{deleted_at: nil} <- Visibility.visible_message(scope, attachment.message_id),
         {:ok, body, _stored_type} <- ObjectStore.get(attachment.asset.storage_key) do
      {:ok, attachment, body}
    else
      {:error, reason} when reason != :not_found and reason != :invalid -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Deletes the asset rows of message `message_id`'s attachments, and with them the attachment rows
  (`on_delete: :delete_all`). Returns `{:ok, storage_keys}` for `MediaAssets.delete_objects/1`:
  call it inside the transaction that deletes the message, and delete the objects after the
  commit.
  """
  def delete_for_message(message_id) do
    {_count, keys} =
      Repo.delete_all(
        from(asset in MediaAsset,
          join: attachment in MessageAttachment,
          on: attachment.asset_id == asset.id,
          where: attachment.message_id == ^message_id,
          select: asset.storage_key
        )
      )

    {:ok, keys}
  end

  @doc """
  The URL an attachment is served at. The file name is the last segment, so a browser saves the
  file under it.
  """
  def url(%MessageAttachment{id: id, asset: %MediaAsset{} = asset}),
    do: "/attachments/#{id}/#{URI.encode(filename(asset), &URI.char_unreserved?/1)}"

  @doc "The name the file is shown and saved under."
  def filename(%MediaAsset{original_filename: name}) when is_binary(name) and name != "",
    do: name

  def filename(%MediaAsset{content_type: type}), do: "file#{MediaAssets.extension(type)}"

  # --- Building ----------------------------------------------------------------------------------

  defp build(scope, %{path: path, client_name: client_name}, position) do
    with {:ok, body} <- File.read(path),
         :ok <- check_size(body) do
      {kind, content_type} = classify(body)

      {:ok,
       %MessageAttachment{
         kind: kind,
         position: position,
         asset: %MediaAsset{
           uploader_id: scope.user_id,
           kind: :attachment,
           storage_provider: "s3",
           storage_key: "attachments/#{Ecto.UUID.generate()}",
           original_filename: clean_filename(client_name),
           content_type: content_type,
           byte_size: byte_size(body),
           sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
           body: body
         }
       }}
    end
  end

  defp check_size(body) when byte_size(body) > @max_bytes, do: {:error, :attachment_too_large}
  defp check_size(_body), do: :ok

  defp classify(body) do
    case MediaAssets.image_type(body) do
      {:ok, content_type} -> {:image, content_type}
      :error -> {:file, "application/octet-stream"}
    end
  end

  # A name a browser may show and save: no directory part, no control characters, and short.
  defp clean_filename(name) when is_binary(name) do
    name
    |> String.split(["/", "\\"])
    |> List.last()
    |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
    |> String.trim()
    |> String.slice(0, @max_filename_length)
  end

  defp clean_filename(_name), do: nil
end
