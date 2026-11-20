defmodule Tavern.Chat.MediaAssets do
  @moduledoc """
  Uploaded images. Each asset's bytes live in `Tavern.ObjectStore` under its `storage_key`,
  and the app serves them at `asset_url/1`.
  """

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.MediaAsset
  alias Tavern.ObjectStore
  alias Tavern.Repo

  def asset_url(%MediaAsset{storage_key: storage_key}) when is_binary(storage_key),
    do: "/uploads/#{storage_key}"

  @doc """
  The bytes and recorded content type of the asset stored at `storage_key`, as
  `{:ok, body, content_type}`. A key with no asset row is `{:error, :not_found}` and never
  reaches the store, so a request can read only an object the app recorded, with the type the
  app checked when it stored it.
  """
  def fetch_upload(storage_key) when is_binary(storage_key) do
    case Repo.get_by(MediaAsset, storage_provider: "s3", storage_key: storage_key) do
      nil ->
        {:error, :not_found}

      %MediaAsset{content_type: content_type} ->
        with {:ok, body, _stored_type} <- ObjectStore.get(storage_key) do
          {:ok, body, content_type}
        end
    end
  end

  @doc """
  Stores an uploaded image as an asset of `kind` (`:emoji` or `:server_icon`), with the scope's
  member as its uploader, and runs `use_asset` with the asset row. Returns what `use_asset`
  returns, or `{:error, reason}`.

  The content type comes from the file's magic bytes (`image_type/1`), so a file that is not a
  PNG, JPEG, GIF or WebP is `{:error, :invalid_upload_type}` whatever its name or the type the
  client claimed. The object goes to the store last, after `use_asset` returns `{:ok, _}`: a
  write that fails before then leaves no object behind, and a failed store returns its error.

  It decides nothing: the caller has already authorised the write that uses the asset. Call it
  inside the caller's transaction, which must return the error so the asset row rolls back.
  """
  def store_upload(%Scope{} = scope, %{path: path, client_name: client_name}, kind, use_asset)
      when is_function(use_asset, 1) do
    with {:ok, body} <- File.read(path),
         {:ok, content_type} <- upload_type(body),
         {:ok, asset} <-
           %MediaAsset{}
           |> MediaAsset.changeset(%{
             uploader_id: scope.user_id,
             kind: kind,
             storage_provider: "s3",
             storage_key: "#{upload_dir(kind)}/#{Ecto.UUID.generate()}#{extension(content_type)}",
             original_filename: client_name,
             content_type: content_type,
             byte_size: byte_size(body),
             sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
           })
           |> Repo.insert(),
         {:ok, result} <- use_asset.(asset),
         :ok <- ObjectStore.put(asset.storage_key, body, content_type) do
      {:ok, result}
    end
  end

  def delete_media_asset(%MediaAsset{storage_key: storage_key} = asset) do
    with :ok <- ObjectStore.delete(storage_key) do
      Repo.delete(asset)
    end
  end

  @doc """
  The image type of `bytes` from its magic bytes: `{:ok, content_type}` for PNG, JPEG, GIF and
  WebP, `:error` for anything else, whatever name or Content-Type came with the bytes.
  """
  def image_type(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, "image/png"}
  def image_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  def image_type(<<"GIF87a", _::binary>>), do: {:ok, "image/gif"}
  def image_type(<<"GIF89a", _::binary>>), do: {:ok, "image/gif"}
  def image_type(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def image_type(_bytes), do: :error

  @doc "The file extension for one of the accepted image content types, with its dot."
  def extension("image/png"), do: ".png"
  def extension("image/jpeg"), do: ".jpg"
  def extension("image/gif"), do: ".gif"
  def extension("image/webp"), do: ".webp"
  def extension(_), do: ".bin"

  defp upload_type(body) do
    case image_type(body) do
      {:ok, content_type} -> {:ok, content_type}
      :error -> {:error, :invalid_upload_type}
    end
  end

  defp upload_dir(:emoji), do: "emojis"
  defp upload_dir(:server_icon), do: "server_icons"
end
