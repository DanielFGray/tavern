defmodule Tavern.Embeds.Links do
  @moduledoc """
  Finds the links in a message body that get an embed, and recognises YouTube video links.
  Pure functions: nothing here reads the network or the database.
  """

  @max_links 5
  @max_url_length 2048

  # A URL runs to the next whitespace, angle bracket or `](`, where a markdown link's text ends
  # and its target begins: in a linked image, `[![alt](https://img)](https://page)`, both URLs
  # are links. The optional brackets around a URL are captured so a link written as
  # `<https://...>` can be left without an embed, as Discord does.
  @url_pattern ~r{(<?)(https?://(?:(?!\]\()[^\s<>])+)(>?)}i

  # Code is shown as written, so a link inside it is text, not a link.
  @fenced_code ~r/```.*?```/s
  @inline_code ~r/`[^`\n]*`/

  @trailing_punctuation [".", ",", ":", ";", "!", "?", "'", "\"", "*", "_", "~"]

  @youtube_watch_hosts ["youtube.com", "www.youtube.com", "m.youtube.com"]
  @video_id ~r/\A[A-Za-z0-9_-]{11}\z/

  @doc """
  The http and https links in `body` that get an embed, in the order written, each once, at most
  #{@max_links}. A link wrapped in angle brackets, or inside a code span or block, gets none.
  """
  def embeddable(body) when is_binary(body) do
    body
    |> String.replace(@fenced_code, " ")
    |> String.replace(@inline_code, " ")
    |> then(&Regex.scan(@url_pattern, &1, capture: :all_but_first))
    |> Enum.flat_map(fn
      ["<", _url, ">"] -> []
      [_open, url, _close] -> url |> trim_trailing_punctuation() |> valid_url()
    end)
    |> Enum.uniq()
    |> Enum.take(@max_links)
  end

  def embeddable(_body), do: []

  @doc """
  The video id of a YouTube watch, short or youtu.be link, as `{:ok, id}`, or `:error`. The
  host must match exactly, and the id must be 11 characters of `[A-Za-z0-9_-]`, because it is
  put into the player's URL.
  """
  def youtube_video_id(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when scheme in ["http", "https"] ->
        uri |> video_id_candidate(String.downcase(host || "")) |> validate_video_id()

      _ ->
        :error
    end
  end

  @doc "Whether `id` is a well-formed YouTube video id."
  def valid_video_id?(id) when is_binary(id), do: Regex.match?(@video_id, id)
  def valid_video_id?(_id), do: false

  defp video_id_candidate(%URI{path: "/watch", query: query}, host)
       when host in @youtube_watch_hosts and is_binary(query),
       do: query |> URI.decode_query() |> Map.get("v")

  defp video_id_candidate(%URI{path: "/shorts/" <> id}, host) when host in @youtube_watch_hosts,
    do: id

  defp video_id_candidate(%URI{path: "/" <> id}, "youtu.be"), do: id
  defp video_id_candidate(_uri, _host), do: nil

  defp validate_video_id(id) do
    if valid_video_id?(id), do: {:ok, id}, else: :error
  end

  # Prose often ends a link with punctuation, and a link in parentheses ends with ")". A ")" is
  # kept when the URL itself opened one, as in Wikipedia links.
  defp trim_trailing_punctuation(url) do
    last = String.last(url)

    if last in @trailing_punctuation or (last == ")" and unbalanced_close?(url)),
      do: url |> String.slice(0..-2//1) |> trim_trailing_punctuation(),
      else: url
  end

  defp unbalanced_close?(url) do
    count = fn char -> url |> String.graphemes() |> Enum.count(&(&1 == char)) end
    count.(")") > count.("(")
  end

  defp valid_url(url) do
    with true <- byte_size(url) <= @max_url_length,
         {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] <-
           URI.new(url),
         true <- is_binary(host) and host != "" do
      [url]
    else
      _ -> []
    end
  end
end
