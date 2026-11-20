defmodule Tavern.Embeds.Unfurl do
  @moduledoc """
  Turns one link into a preview: a page's Open Graph or Twitter card, falling back to its
  `<title>` and meta description, or a YouTube video's title and thumbnail from YouTube's
  oEmbed endpoint. Every request goes through `Tavern.Embeds.SafeHTTP`.

  A preview is a map with `:url`, `:kind` (`:link` or `:video`), `:provider`, `:title`,
  `:description`, `:site_name`, `:video_id` and `:image` (`nil`, or `%{body: bytes,
  content_type: type}` for a PNG, JPEG, GIF or WebP checked by its magic bytes).
  """

  alias Tavern.Chat.MediaAssets
  alias Tavern.Embeds.Links
  alias Tavern.Embeds.SafeHTTP

  @max_html_bytes 1_000_000
  @max_image_bytes 5_000_000
  @max_oembed_bytes 64_000

  @max_title 256
  @max_description 350
  @max_site_name 100

  @html_types ["text/html", "application/xhtml+xml"]

  @doc """
  The preview of `url` as `{:ok, preview}`, or `:error` when the link cannot be fetched or has
  nothing to show (no title and no description). A preview image that fails its checks is left
  out; the rest of the preview is kept.
  """
  def preview(url) when is_binary(url) do
    case Links.youtube_video_id(url) do
      {:ok, video_id} -> youtube(url, video_id)
      :error -> page(url)
    end
  end

  defp youtube(url, video_id) do
    oembed_url =
      "https://www.youtube.com/oembed?" <>
        URI.encode_query(%{
          "format" => "json",
          "url" => "https://www.youtube.com/watch?v=" <> video_id
        })

    with {:ok, %{body: body}} <-
           SafeHTTP.get(oembed_url,
             max_bytes: @max_oembed_bytes,
             over_limit: :refuse,
             accept: "application/json"
           ),
         {:ok, %{"title" => title} = oembed} when is_binary(title) <- Jason.decode(body),
         title when title != nil <- clean(title, @max_title) do
      {:ok,
       %{
         url: url,
         kind: :video,
         provider: "youtube",
         title: title,
         description: clean(oembed["author_name"], @max_description),
         site_name: "YouTube",
         video_id: video_id,
         image: fetch_image("https://i.ytimg.com/vi/#{video_id}/hqdefault.jpg")
       }}
    else
      _ -> :error
    end
  end

  defp page(url) do
    with {:ok, %{url: final_url, content_type: content_type, body: body}} <-
           SafeHTTP.get(url,
             max_bytes: @max_html_bytes,
             accept: "text/html,application/xhtml+xml"
           ),
         true <- html?(content_type),
         document = LazyHTML.from_document(body),
         meta = meta_tags(document),
         title when title != nil <- page_title(meta, document) || meta_description(meta) do
      description = meta_description(meta)

      {:ok,
       %{
         url: url,
         kind: :link,
         provider: nil,
         title: title,
         description: if(description == title, do: nil, else: description),
         site_name: clean(meta["og:site_name"], @max_site_name) || host_name(final_url),
         video_id: nil,
         image: meta |> image_url(final_url) |> fetch_image()
       }}
    else
      _ -> :error
    end
  end

  defp html?(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";")
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in @html_types))
  end

  defp html?(_content_type), do: false

  # Each meta tag's `property` or `name`, lowercased, to its first `content`.
  defp meta_tags(document) do
    document
    |> LazyHTML.query("meta[content]")
    |> Enum.reduce(%{}, fn node, acc ->
      key = List.first(LazyHTML.attribute(node, "property") ++ LazyHTML.attribute(node, "name"))
      content = List.first(LazyHTML.attribute(node, "content"))

      if is_binary(key) and is_binary(content),
        do: Map.put_new(acc, String.downcase(key), content),
        else: acc
    end)
  end

  defp page_title(meta, document) do
    clean(meta["og:title"], @max_title) || clean(meta["twitter:title"], @max_title) ||
      document
      |> LazyHTML.query("title")
      |> Enum.take(1)
      |> Enum.map(&LazyHTML.text/1)
      |> List.first()
      |> clean(@max_title)
  end

  defp meta_description(meta) do
    clean(meta["og:description"], @max_description) ||
      clean(meta["twitter:description"], @max_description) ||
      clean(meta["description"], @max_description)
  end

  defp image_url(meta, page_url) do
    with image when is_binary(image) <-
           meta["og:image:secure_url"] || meta["og:image"] || meta["twitter:image"] ||
             meta["twitter:image:src"],
         {:ok, image} <- URI.new(String.trim(image)) do
      page_url |> URI.merge(image) |> URI.to_string()
    else
      _ -> nil
    end
  end

  defp fetch_image(nil), do: nil

  defp fetch_image(url) do
    with {:ok, %{body: body}} <-
           SafeHTTP.get(url,
             max_bytes: @max_image_bytes,
             over_limit: :refuse,
             accept: "image/png,image/jpeg,image/gif,image/webp"
           ),
         {:ok, content_type} <- MediaAssets.image_type(body) do
      %{body: body, content_type: content_type}
    else
      _ -> nil
    end
  end

  defp host_name(url) do
    case URI.new(url) do
      {:ok, %URI{host: "www." <> host}} -> host
      {:ok, %URI{host: host}} -> host
      _ -> nil
    end
  end

  # Page text arrives in any encoding and any length. Stored text is valid UTF-8 without control
  # characters, on one line, and capped, so a hostile page cannot break the insert or the card.
  defp clean(text, max) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, max)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp clean(_text, _max), do: nil
end
