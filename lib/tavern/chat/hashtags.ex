defmodule Tavern.Chat.Hashtags do
  @moduledoc """
  The tags of a thread: each `#word` in its title or its starter message (docs/design/forums.md,
  "Tags").

  A tag is `#` followed by 1 to 50 letters, digits, `_` or `-`, case-folded. It must not follow
  a letter, digit, `_`, `-`, `/`, `&` or `#`, so `a#b`, a URL fragment (`/page#part`), an HTML
  entity (`&#39;`) and `##` give none. A longer run gives no tag rather than a cut one. A thread
  keeps the first 10 distinct tags, title first.
  """

  @max_tags 10

  @tag ~r/(?<![\p{L}\p{N}_\-\/&#])#([\p{L}\p{N}_\-]{1,50})(?![\p{L}\p{N}_\-])/u

  @doc "The tags in `title` and then `body`, distinct, in order of first use, at most 10."
  def extract(title, body) do
    [title, body]
    |> Enum.flat_map(&scan/1)
    |> Enum.uniq()
    |> Enum.take(@max_tags)
  end

  @doc "The tags a search names (`#word`), and its other words."
  def split_query(query) when is_binary(query) do
    words = String.split(query)
    {tags, rest} = Enum.split_with(words, &(scan(&1) != [] and String.starts_with?(&1, "#")))
    {tags |> Enum.flat_map(&scan/1) |> Enum.uniq(), rest}
  end

  def split_query(_none), do: {[], []}

  defp scan(text) when is_binary(text) do
    for [_match, tag] <- Regex.scan(@tag, text), do: String.downcase(tag)
  end

  defp scan(_none), do: []
end
