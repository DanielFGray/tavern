defmodule Tavern.Chat.ServerConfig do
  @moduledoc false

  import Ecto.Changeset, only: [put_change: 3]
  import Ecto.Query, warn: false

  @cache_key {__MODULE__, :server_settings}

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.ServerSettings
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  def get_server_settings do
    case :persistent_term.get(@cache_key, :missing) do
      :missing ->
        settings = load_server_settings()
        :persistent_term.put(@cache_key, settings)
        settings

      settings ->
        settings
    end
  end

  def change_server_settings(%ServerSettings{} = server_settings, attrs \\ %{}) do
    ServerSettings.changeset(server_settings, attrs)
  end

  @doc """
  Changes the server name, and replaces the icon when attrs hold an `"icon_upload"`.
  The scope must hold `manage_server` now, in the database: the write transaction decides it
  first, before an uploaded icon is stored. An `"icon_asset_id"` in attrs is ignored.
  """
  def update_server_settings(%Scope{} = scope, attrs) when is_map(attrs) do
    name_attrs = name_attrs(attrs)

    write_settings(scope, fn server_settings ->
      case Map.get(attrs, "icon_upload") do
        nil ->
          save_settings(server_settings, name_attrs, :keep)

        upload ->
          MediaAssets.store_upload(scope, upload, :server_icon, fn asset ->
            save_settings(server_settings, name_attrs, {:replace, asset.id})
          end)
      end
    end)
  end

  @doc """
  Clears the server icon. Needs `manage_server`. Deletes the previous asset only when its kind
  is `:server_icon`.
  """
  def remove_server_icon(%Scope{} = scope) do
    write_settings(scope, fn server_settings ->
      save_settings(
        server_settings,
        name_attrs(%{"name" => server_settings.name}),
        {:replace, nil}
      )
    end)
  end

  def server_icon_url(%ServerSettings{icon_asset: %MediaAsset{} = asset}),
    do: MediaAssets.asset_url(asset)

  def server_icon_url(%ServerSettings{icon_asset: %Ecto.Association.NotLoaded{}}), do: nil
  def server_icon_url(_settings), do: nil

  def default_server_name do
    Application.get_env(:tavern, :server_name, "Tavern")
  end

  @doc "Drops the cached server settings, so the next read loads from the database."
  def reset_server_settings_cache, do: :persistent_term.erase(@cache_key)

  # Decides `manage_server`, then locks the settings row, then runs `fun` with it, in one
  # transaction. After the commit, this node drops its cached copy before it returns, so the
  # writer's next read is current. The broadcast then drops the copy on every node, this one
  # included: a reader that loaded the old row before the commit may have stored it after the
  # erase, and only the later erase from the broadcast clears it.
  #
  # `fun` returns `{:ok, {settings, retired_keys}}`. The retired icon's object is deleted only
  # after the commit: a rollback keeps the old row, which must still find its object.
  defp write_settings(scope, fun) do
    Repo.transact(fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_server, :server) do
        fun.(lock_server_settings())
      end
    end)
    |> case do
      {:ok, {settings, retired_keys}} ->
        MediaAssets.delete_objects(retired_keys)
        reset_server_settings_cache()
        Topics.broadcast_server_settings_changed()
        {:ok, settings}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_settings(server_settings, name_attrs, icon_change) do
    with {:ok, settings} <-
           server_settings
           |> settings_changeset(name_attrs, icon_change)
           |> Repo.insert_or_update(),
         {:ok, retired_keys} <- retire_icon_asset(server_settings.icon_asset, icon_change) do
      {:ok, {Repo.preload(settings, [:icon_asset], force: true), retired_keys}}
    end
  end

  defp settings_changeset(server_settings, name_attrs, :keep) do
    server_settings
    |> ServerSettings.changeset(name_attrs)
    |> put_change(:singleton, true)
  end

  defp settings_changeset(server_settings, name_attrs, {:replace, icon_asset_id}) do
    server_settings
    |> ServerSettings.changeset(name_attrs)
    |> put_change(:singleton, true)
    |> put_change(:icon_asset_id, icon_asset_id)
  end

  # Only a purpose-built server icon may be deleted when the icon changes; an emoji or other
  # kind pointed here by an old write must stay so manage_emojis cannot be bypassed. Drops the
  # row and returns its storage key, for `MediaAssets.delete_objects/1` after the commit.
  defp retire_icon_asset(%MediaAsset{kind: :server_icon} = asset, {:replace, _icon_asset_id}) do
    MediaAssets.delete_asset_row(asset)
  end

  defp retire_icon_asset(_asset, _icon_change), do: {:ok, []}

  defp name_attrs(attrs) do
    attrs
    |> Map.take(["name", "registration_mode", "accept_invite_requests"])
    |> Map.put_new("name", default_server_name())
  end

  defp load_server_settings(query \\ ServerSettings) do
    case Repo.one(query) do
      nil -> %ServerSettings{name: default_server_name(), singleton: true, icon_asset: nil}
      settings -> Repo.preload(settings, [:icon_asset])
    end
  end

  # Writers read the previous icon under this lock, so two concurrent icon
  # changes never both delete the same old asset.
  defp lock_server_settings, do: load_server_settings(lock(ServerSettings, "FOR UPDATE"))
end
