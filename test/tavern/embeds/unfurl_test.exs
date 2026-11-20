defmodule Tavern.Embeds.UnfurlTest do
  use ExUnit.Case, async: true

  alias Tavern.Embeds.SafeHTTP
  alias Tavern.Embeds.Unfurl

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0::size(64)>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0::size(64)>>

  defp stub(routes) do
    Req.Test.stub(SafeHTTP, fn conn ->
      case Map.fetch(routes, {conn.host, conn.request_path}) do
        {:ok, {content_type, body}} ->
          conn
          |> Plug.Conn.put_resp_content_type(content_type, nil)
          |> Plug.Conn.send_resp(200, body)

        :error ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  describe "pages" do
    test "reads the Open Graph card and downloads its image" do
      stub(%{
        {"site.test", "/post"} =>
          {"text/html; charset=utf-8",
           """
           <html><head>
             <title>Fallback title</title>
             <meta property="og:title" content="The &amp; Story">
             <meta property="og:description" content="What happened next.">
             <meta property="og:site_name" content="Example News">
             <meta property="og:image" content="//images.site.test/cover.png">
           </head><body></body></html>
           """},
        {"images.site.test", "/cover.png"} => {"image/png", @png}
      })

      assert {:ok, preview} = Unfurl.preview("https://site.test/post")
      assert preview.kind == :link
      assert preview.title == "The & Story"
      assert preview.description == "What happened next."
      assert preview.site_name == "Example News"
      assert preview.image == %{body: @png, content_type: "image/png"}
    end

    test "falls back to Twitter tags, then <title> and the meta description" do
      stub(%{
        {"site.test", "/twitter"} =>
          {"text/html",
           ~s(<meta name="twitter:title" content="Tweeted"><meta name="twitter:description" content="Short.">)},
        {"site.test", "/plain"} =>
          {"text/html",
           "<head><title>\n  Plain   page\n</title><meta name=\"description\" content=\"About it.\"></head>"}
      })

      assert {:ok, %{title: "Tweeted", description: "Short."}} =
               Unfurl.preview("https://site.test/twitter")

      assert {:ok, %{title: "Plain page", description: "About it.", site_name: "site.test"}} =
               Unfurl.preview("https://site.test/plain")
    end

    test "a page with nothing to show, or that is not HTML, has no preview" do
      stub(%{
        {"site.test", "/empty"} => {"text/html", "<html><body>hi</body></html>"},
        {"site.test", "/data.json"} => {"application/json", ~s({"title": "nope"})}
      })

      assert Unfurl.preview("https://site.test/empty") == :error
      assert Unfurl.preview("https://site.test/data.json") == :error
      assert Unfurl.preview("https://site.test/gone") == :error
    end

    test "an image that fails its checks is left out, and the card keeps its text" do
      page = fn image ->
        {"text/html",
         ~s(<meta property="og:title" content="T"><meta property="og:image" content="#{image}">)}
      end

      stub(%{
        {"site.test", "/html-as-image"} => page.("https://images.site.test/fake.png"),
        {"site.test", "/huge"} => page.("https://images.site.test/huge.jpg"),
        {"site.test", "/private"} => page.("http://10.0.0.1/cover.png"),
        {"images.site.test", "/fake.png"} => {"image/png", "<svg onload=alert(1)>"},
        {"images.site.test", "/huge.jpg"} =>
          {"image/jpeg", @jpeg <> :binary.copy(<<0>>, 5_000_001)}
      })

      for path <- ["/html-as-image", "/huge", "/private"] do
        assert {:ok, %{title: "T", image: nil}} = Unfurl.preview("https://site.test" <> path),
               path
      end
    end

    test "page text is cleaned and capped" do
      long = String.duplicate("word ", 200)

      stub(%{
        {"site.test", "/messy"} =>
          {"text/html",
           "<meta property=\"og:title\" content=\"bad\x00\x07 text \xFF\"><meta property=\"og:description\" content=\"#{long}\">"}
      })

      assert {:ok, preview} = Unfurl.preview("https://site.test/messy")
      assert String.valid?(preview.title)
      refute preview.title =~ <<0>>
      assert String.length(preview.description) <= 350
    end
  end

  describe "image files" do
    test "a link to an image is an image preview of its bytes, typed by its magic bytes" do
      stub(%{
        {"site.test", "/cat.png"} => {"image/png", @png},
        {"site.test", "/photo"} => {"text/html", @jpeg}
      })

      assert {:ok,
              %{
                kind: :image,
                title: nil,
                description: nil,
                site_name: "site.test",
                image: %{body: @png, content_type: "image/png"}
              }} = Unfurl.preview("https://site.test/cat.png")

      assert {:ok, %{kind: :image, image: %{content_type: "image/jpeg"}}} =
               Unfurl.preview("https://site.test/photo")
    end

    test "an image over 5 MB, or a file that is neither image nor page, has no preview" do
      stub(%{
        {"site.test", "/huge.jpg"} => {"image/jpeg", @jpeg <> :binary.copy(<<0>>, 5_000_000)},
        {"site.test", "/fake.png"} => {"image/png", "<svg onload=alert(1)>"}
      })

      assert Unfurl.preview("https://site.test/huge.jpg") == :error
      assert Unfurl.preview("https://site.test/fake.png") == :error
    end

    test "a page over the image limit is still read from its first megabyte" do
      page =
        ~s(<head><meta property="og:title" content="Big page"></head>) <>
          String.duplicate("<p>filler</p>", 600_000)

      stub(%{{"site.test", "/big"} => {"text/html", page}})

      assert byte_size(page) > 5_000_001
      assert {:ok, %{kind: :link, title: "Big page"}} = Unfurl.preview("https://site.test/big")
    end
  end

  describe "YouTube" do
    test "takes the title from oEmbed and the thumbnail from i.ytimg.com" do
      test_pid = self()

      Req.Test.stub(SafeHTTP, fn conn ->
        send(test_pid, {:requested, conn.host, conn.request_path, conn.query_string})

        case {conn.host, conn.request_path} do
          {"www.youtube.com", "/oembed"} ->
            Req.Test.json(conn, %{"title" => "A video", "author_name" => "A channel"})

          {"i.ytimg.com", "/vi/dQw4w9WgXcQ/hqdefault.jpg"} ->
            conn
            |> Plug.Conn.put_resp_content_type("image/jpeg")
            |> Plug.Conn.send_resp(200, @jpeg)
        end
      end)

      assert {:ok, preview} = Unfurl.preview("https://youtu.be/dQw4w9WgXcQ")

      assert %{
               kind: :video,
               provider: "youtube",
               video_id: "dQw4w9WgXcQ",
               title: "A video",
               description: "A channel",
               site_name: "YouTube",
               image: %{content_type: "image/jpeg"}
             } = preview

      assert_received {:requested, "www.youtube.com", "/oembed", query}

      assert URI.decode_query(query)["url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    end

    test "a video oEmbed does not know has no preview" do
      Req.Test.stub(SafeHTTP, &Plug.Conn.send_resp(&1, 404, "Not Found"))
      assert Unfurl.preview("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == :error
    end
  end
end
