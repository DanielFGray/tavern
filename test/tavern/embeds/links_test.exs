defmodule Tavern.Embeds.LinksTest do
  use ExUnit.Case, async: true

  alias Tavern.Embeds.Links

  describe "embeddable/1" do
    test "finds http and https links in order, each once, trimming prose punctuation" do
      body =
        "see https://example.com/a, then (http://example.com/b) and https://example.com/a again."

      assert Links.embeddable(body) == ["https://example.com/a", "http://example.com/b"]
    end

    test "keeps a closing parenthesis the URL opened" do
      assert Links.embeddable("https://en.wikipedia.org/wiki/Tavern_(disambiguation)") ==
               ["https://en.wikipedia.org/wiki/Tavern_(disambiguation)"]
    end

    test "the image URL in markdown image syntax is a link" do
      body = ~S{![a cat](https://example.com/cat.png) ![](https://example.com/dog.gif "Dog")}

      assert Links.embeddable(body) == [
               "https://example.com/cat.png",
               "https://example.com/dog.gif"
             ]
    end

    test "a linked image gives both the image and the link target" do
      assert Links.embeddable("[![a cat](https://example.com/cat.png)](https://example.com/cats)") ==
               ["https://example.com/cat.png", "https://example.com/cats"]
    end

    test "a link in angle brackets gets no embed" do
      assert Links.embeddable("quiet <https://example.com/quiet> loud https://example.com/loud") ==
               ["https://example.com/loud"]
    end

    test "a link in code gets no embed" do
      body = "`https://example.com/inline`\n```\nhttps://example.com/fenced\n```"
      assert Links.embeddable(body) == []
    end

    test "takes at most five links" do
      body = Enum.map_join(1..7, " ", &"https://example.com/#{&1}")
      assert length(Links.embeddable(body)) == 5
    end

    test "ignores other schemes" do
      assert Links.embeddable("ftp://example.com javascript:alert(1) mailto:a@example.com") == []
    end
  end

  describe "youtube_video_id/1" do
    test "reads watch, short, mobile and youtu.be links" do
      for url <- [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtube.com/watch?feature=share&v=dQw4w9WgXcQ",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ"
          ] do
        assert Links.youtube_video_id(url) == {:ok, "dQw4w9WgXcQ"}, url
      end
    end

    test "refuses look-alike hosts and malformed ids" do
      for url <- [
            "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com.evil.test/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=short",
            "https://www.youtube.com/watch?v=dQw4w9WgXc%22",
            "https://youtu.be/dQw4w9WgXcQ/../x",
            "https://www.youtube.com/channel/dQw4w9WgXcQ"
          ] do
        assert Links.youtube_video_id(url) == :error, url
      end
    end
  end
end
