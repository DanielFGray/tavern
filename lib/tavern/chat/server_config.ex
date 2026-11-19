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
      with {:ok, icon_change} <- resolve_icon_change(scope, attrs) do
        save_settings(server_settings, name_attrs, icon_change)
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
  defp write_settings(scope, fun) do
    Repo.transact(fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_server, :server) do
        fun.(lock_server_settings())
      end
    end)
    |> tap(fn
      {:ok, _settings} ->
        reset_server_settings_cache()
        Topics.broadcast_server_settings_changed()

      {:error, _reason} ->
        :ok
    end)
  end

  defp save_settings(server_settings, name_attrs, icon_change) do
    with {:ok, settings} <-
           server_settings
           |> settings_changeset(name_attrs, icon_change)
           |> Repo.insert_or_update() do
      if icon_change != :keep do
        maybe_delete_server_icon_asset(server_settings.icon_asset)
      end

      {:ok, Repo.preload(settings, [:icon_asset], force: true)}
    end
  end

  defp resolve_icon_change(scope, attrs) do
    case Map.get(attrs, "icon_upload") do
      nil ->
        {:ok, :keep}

      upload ->
        case MediaAssets.create_server_icon_from_upload(scope, upload) do
          {:ok, asset} -> {:ok, {:replace, asset.id}}
          {:error, reason, :upload} -> {:error, reason}
        end
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
  # kind pointed here by an old write must stay so manage_emojis cannot be bypassed.
  defp maybe_delete_server_icon_asset(%MediaAsset{kind: :server_icon} = asset) do
    MediaAssets.delete_media_asset(asset)
  end

  defp maybe_delete_server_icon_asset(_asset), do: :ok

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
