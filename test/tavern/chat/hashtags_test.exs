defmodule Tavern.Chat.HashtagsTest do
  use ExUnit.Case, async: true

  alias Tavern.Chat.Hashtags

  describe "extract/2" do
    test "takes #words from the title, then the body" do
      assert Hashtags.extract("Help with #setup", "see #docs and #setup") == ["setup", "docs"]
    end

    test "folds case" do
      assert Hashtags.extract("#Elixir", "#ELIXIR #elixir") == ["elixir"]
    end

    test "keeps letters, digits, underscores and hyphens" do
      assert Hashtags.extract("", "#bug_report #v2-beta #café #タグ") ==
               ["bug_report", "v2-beta", "café", "タグ"]
    end

    test "ends a tag at punctuation" do
      assert Hashtags.extract("", "(#one), #two. #three!") == ["one", "two", "three"]
    end

    test "ignores a # inside a word, a URL fragment, an HTML entity and a heading" do
      assert Hashtags.extract("", "a#b https://x.test/page#part &#39; ## title # heading") == []
    end

    test "gives no tag for a run longer than 50 characters" do
      long = String.duplicate("a", 51)
      exact = String.duplicate("b", 50)
      assert Hashtags.extract("", "##{long} ##{exact}") == [exact]
    end

    test "keeps at most 10 tags" do
      body = Enum.map_join(1..12, " ", &"#t#{&1}")
      assert Hashtags.extract("", body) == Enum.map(1..10, &"t#{&1}")
    end

    test "a post without tags has none" do
      assert Hashtags.extract("Plain title", "plain body") == []
      assert Hashtags.extract(nil, nil) == []
    end
  end

  describe "split_query/1" do
    test "splits #tags from other words" do
      assert Hashtags.split_query("#Bug crash #ui on start") ==
               {["bug", "ui"], ["crash", "on", "start"]}
    end

    test "a lone # is a word" do
      assert Hashtags.split_query("# crash") == {[], ["#", "crash"]}
    end

    test "nothing searches nothing" do
      assert Hashtags.split_query(nil) == {[], []}
      assert Hashtags.split_query("  ") == {[], []}
    end
  end
end
