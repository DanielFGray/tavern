defmodule Tavern.Chat.Embeds do
  @moduledoc """
  Link embeds: the stored previews of the links in a message. See `docs/design/link-embeds.md`.

  After a message write commits, `schedule/2` starts one background task under
  `Tavern.Embeds.TaskSupervisor` that fetches the links with no embed yet (`Tavern.Embeds.Unfurl`),
  copies their images into the object store, then stores what the message still wants in one
  transaction and broadcasts the message. A failed fetch stores nothing.

  The message writes in `Tavern.Chat.Messages` call `prune/1` inside their own transaction, so an edit
  drops the embeds of links it removed, and a deletion or a suppression drops them all. Image
  objects are deleted after the transaction commits (`delete_objects/1`).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.Message
  alias Tavern.Chat.Messages
  alias Tavern.Chat.MessageEmbed
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Embeds.Links
  alias Tavern.Embeds.Unfurl
  alias Tavern.ObjectStore
  alias Tavern.Repo

  @task_supervisor Tavern.Embeds.TaskSupervisor
  @upload_dir "embeds"

  # One link can take a page fetch and an image fetch, each with a five-second budget.
  @preview_timeout_ms 12_000

  @doc """
  Starts the background fetch for the links `message` wants that are not in `embedded_urls`. A
  message with no such link starts no task, so most writes cost nothing here. When the
  supervisor is at its limit, the fetch is dropped and the message keeps no new embed.
  """
  def schedule(%Message{} = message, embedded_urls) do
    case wanted_urls(message) -- embedded_urls do
      [] ->
        :ok

      urls ->
        case Task.Supervisor.start_child(@task_supervisor, fn ->
               fetch_and_store(message.id, urls)
             end) do
          {:ok, _pid} -> :ok
          {:error, :max_children} -> :ok
        end
    end
  end

  @doc """
  Fetches previews of `urls` for the message, then stores them. Returns `{:ok, message}` when
  it stored at least one and broadcast the message, `:none` otherwise.

  The store transaction decides `:embed_links` for the author as of now, locks the message,
  and keeps only the previews of links its current body still wants and that have no embed:
  the message may have been edited, suppressed or deleted while the fetch ran.
  """
  def fetch_and_store(message_id, urls) do
    urls
    |> Task.async_stream(&Unfurl.preview/1,
      max_concurrency: length(urls),
      timeout: @preview_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, preview}} -> [preview]
      _failed -> []
    end)
    |> case do
      [] -> :none
      previews -> previews |> Enum.map(&put_image_object/1) |> store(message_id)
    end
  end

  @doc """
  Drops the embeds `message` no longer wants and puts the rest in its link order. Must run
  inside the transaction that wrote the message, with the message row locked. A deleted or
  suppressed message wants none. Returns `{kept_urls, image_keys}`: the storage keys go to
  `delete_objects/1` after the commit.
  """
  def prune(%Message{} = message) do
    wanted = wanted_urls(message)

    {kept, dropped} =
      MessageEmbed
      |> where([embed], embed.message_id == ^message.id)
      |> preload(:image_asset)
      |> Repo.all()
      |> Enum.split_with(&(&1.url in wanted))

    Enum.each(kept, fn embed ->
      position = Enum.find_index(wanted, &(&1 == embed.url))

      if position != embed.position,
        do: embed |> Ecto.Changeset.change(position: position) |> Repo.update!()
    end)

    Repo.delete_all(from(embed in MessageEmbed, where: embed.id in ^Enum.map(dropped, & &1.id)))

    assets = dropped |> Enum.map(& &1.image_asset) |> Enum.reject(&is_nil/1)
    Repo.delete_all(from(asset in MediaAsset, where: asset.id in ^Enum.map(assets, & &1.id)))

    {Enum.map(kept, & &1.url), Enum.map(assets, & &1.storage_key)}
  end

  @doc """
  Deletes image objects after the transaction that dropped their rows has committed. A failed
  delete leaves an object no row names, which `/uploads` does not serve.
  """
  def delete_objects(storage_keys) do
    Enum.each(storage_keys, fn key ->
      case ObjectStore.delete(key) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("embed image #{key} not deleted: #{inspect(reason)}")
      end
    end)
  end

  defp wanted_urls(%Message{deleted_at: nil, suppress_embeds: false, body: body}),
    do: Links.embeddable(body)

  defp wanted_urls(%Message{}), do: []

  # The image bytes go to the object store before the transaction, so the transaction holds no
  # lock during network I/O. A preview whose image cannot be stored keeps its text.
  defp put_image_object(%{image: %{body: body, content_type: content_type}} = preview) do
    key = "#{@upload_dir}/#{Ecto.UUID.generate()}#{MediaAssets.extension(content_type)}"

    case ObjectStore.put(key, body, content_type) do
      :ok ->
        %{
          preview
          | image: %{
              storage_key: key,
              content_type: content_type,
              byte_size: byte_size(body),
              sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
            }
        }

      {:error, reason} ->
        Logger.warning("embed image for #{preview.url} not stored: #{inspect(reason)}")
        %{preview | image: nil}
    end
  end

  defp put_image_object(preview), do: preview

  defp store(previews, message_id) do
    Repo.transact(fn ->
      with %Message{} = message <- Repo.get(Message, message_id),
           author_scope = %Scope{user_id: message.author_id},
           :ok <-
             Visibility.authorize_write(author_scope, :embed_links, %Channel{
               id: message.channel_id
             }),
           %Message{} = message <- Messages.lock_live_message(message_id),
           wanted when wanted != [] <- wanted_urls(message) do
        embedded =
          MapSet.new(
            Repo.all(from(e in MessageEmbed, where: e.message_id == ^message_id, select: e.url))
          )

        stored =
          previews
          |> Enum.filter(&(&1.url in wanted and not MapSet.member?(embedded, &1.url)))
          |> Enum.map(
            &insert_embed(message, &1, Enum.find_index(wanted, fn url -> url == &1.url end))
          )

        if stored == [],
          do: {:error, :none},
          else: {:ok, {Messages.reload_message(message_id), stored}}
      else
        _refused -> {:error, :none}
      end
    end)
    |> case do
      {:ok, {message, stored}} ->
        previews |> Enum.reject(&(&1.url in stored)) |> image_keys() |> delete_objects()
        Topics.broadcast_channel(message.channel_id, {:message_updated, message})
        {:ok, message}

      {:error, _reason} ->
        previews |> image_keys() |> delete_objects()
        :none
    end
  end

  defp insert_embed(message, preview, position) do
    image_asset_id =
      case preview.image do
        nil ->
          nil

        image ->
          %MediaAsset{}
          |> MediaAsset.changeset(Map.merge(image, %{kind: :embed, storage_provider: "s3"}))
          |> Repo.insert!()
          |> Map.fetch!(:id)
      end

    Repo.insert!(%MessageEmbed{
      message_id: message.id,
      position: position,
      url: preview.url,
      kind: preview.kind,
      provider: preview.provider,
      title: preview.title,
      description: preview.description,
      site_name: preview.site_name,
      video_id: preview.video_id,
      image_asset_id: image_asset_id,
      fetched_at: DateTime.utc_now()
    })

    preview.url
  end

  defp image_keys(previews) do
    for %{image: %{storage_key: key}} <- previews, do: key
  end
end
