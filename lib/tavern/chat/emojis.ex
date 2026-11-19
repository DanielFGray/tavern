defmodule Tavern.Chat.Emojis do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Emoji
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @doc """
  The custom emojis the scope's member may use: every available emoji for a member with
  `manage_emojis_and_stickers`, otherwise the listed ones open to everyone or to one of the
  member's roles. Empty when the scope has no active member.
  """
  def list_available_emojis(%Scope{} = scope) do
    case usable_by(scope) do
      nil -> []
      usable? -> Enum.filter(all_emojis(), usable?)
    end
  end

  @doc """
  The emoji `emoji_id`, when the scope's member may use it. `{:error, :invalid_emoji}` when the
  id names no emoji, `{:error, :forbidden}` when the member may not use it.
  """
  def fetch_available_emoji(%Scope{} = scope, emoji_id) do
    with {:ok, emoji} <- fetch_emoji(emoji_id),
         usable? when is_function(usable?) <- usable_by(scope),
         true <- usable?.(emoji) do
      {:ok, emoji}
    else
      {:error, :invalid_emoji} -> {:error, :invalid_emoji}
      _ -> {:error, :forbidden}
    end
  end

  def change_emoji(%Emoji{} = emoji, attrs \\ %{}) do
    Emoji.changeset(emoji, attrs)
  end

  @doc """
  Stores the uploaded image and creates a custom emoji from it. Needs `manage_emojis_and_stickers`
  now, in the database: the transaction decides it before the upload is read. Returns
  `{:error, :forbidden}` without it, `{:error, :invalid_upload_type}` (or another storage
  reason) for a refused file, and `{:error, changeset}` for bad attrs.
  """
  def create_custom_emoji(%Scope{} = scope, upload, attrs) when is_map(attrs) do
    attrs = normalize_emoji_attrs(attrs)

    Repo.transact(fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_emojis_and_stickers, :server),
           {:ok, asset} <- store_upload(scope, upload),
           {:ok, emoji} <-
             %Emoji{creator_id: scope.user_id}
             |> Emoji.changeset(Map.put(attrs, "asset_id", asset.id))
             |> Repo.insert() do
        {:ok, Repo.preload(emoji, [:asset, :creator, :emoji_roles])}
      end
    end)
  end

  defp store_upload(scope, upload) do
    case MediaAssets.create_media_asset_from_upload(scope, upload) do
      {:ok, asset} -> {:ok, asset}
      {:error, reason, :upload} -> {:error, reason}
    end
  end

  @doc """
  Deletes a custom emoji and its asset. Needs `manage_emojis_and_stickers` now, in the database.
  Returns `{:error, :forbidden}` without it and `{:error, :not_found}` for a missing emoji.
  """
  def delete_custom_emoji(%Scope{} = scope, emoji_id) do
    Repo.transact(fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_emojis_and_stickers, :server),
           {:ok, emoji} <- lock_emoji(emoji_id),
           {:ok, deleted_emoji} <- Repo.delete(emoji) do
        case deleted_emoji.asset do
          %MediaAsset{} = asset -> MediaAssets.delete_media_asset(asset)
          _ -> {:ok, nil}
        end

        {:ok, deleted_emoji}
      end
    end)
  end

  defp lock_emoji(emoji_id) do
    with {:ok, emoji_id} <- Ecto.UUID.cast(emoji_id),
         %Emoji{} = emoji <-
           Emoji |> where(id: ^emoji_id) |> lock("FOR UPDATE") |> preload(:asset) |> Repo.one() do
      {:ok, emoji}
    else
      _ -> {:error, :not_found}
    end
  end

  defp all_emojis do
    Emoji
    |> order_by([emoji], asc: emoji.name, asc: emoji.inserted_at)
    |> preload([:asset, :creator, :emoji_roles])
    |> Repo.all()
  end

  defp fetch_emoji(emoji_id) do
    with {:ok, emoji_id} <- Ecto.UUID.cast(emoji_id),
         %Emoji{} = emoji <-
           Emoji |> preload([:asset, :creator, :emoji_roles]) |> Repo.get(emoji_id) do
      {:ok, emoji}
    else
      _ -> {:error, :invalid_emoji}
    end
  end

  # Reads the scope's member and its manage_emojis_and_stickers decision once, and returns the
  # test for one emoji, so a list does not decide per emoji. Nil when no active member.
  defp usable_by(scope) do
    case Visibility.member(scope) do
      nil ->
        nil

      member ->
        role_ids = MapSet.new(member.member_roles, & &1.role_id)
        manager? = Visibility.can?(scope, :manage_emojis_and_stickers, :server)
        &usable?(&1, role_ids, manager?)
    end
  end

  defp usable?(%Emoji{} = emoji, role_ids, manager?) do
    cond do
      not emoji.available -> false
      manager? -> true
      emoji.emoji_roles == [] -> emoji.listed
      true -> emoji.listed and Enum.any?(emoji.emoji_roles, &MapSet.member?(role_ids, &1.role_id))
    end
  end

  defp normalize_emoji_attrs(attrs) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    name = String.trim(Map.get(attrs, "name", ""))
    shortcode = Map.get(attrs, "shortcode") |> blank_to_nil() |> normalize_shortcode(name)

    attrs
    |> Map.put("name", name)
    |> Map.put("shortcode", shortcode)
    |> Map.put_new("requires_colons", true)
    |> Map.put_new("available", true)
    |> Map.put_new("listed", true)
  end

  defp normalize_shortcode(nil, name), do: normalize_shortcode(name, name)

  defp normalize_shortcode(value, _name) when is_binary(value) do
    normalized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_+-]+/u, "_")
      |> String.trim("_:")

    if normalized == "", do: nil, else: ":#{normalized}:"
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
