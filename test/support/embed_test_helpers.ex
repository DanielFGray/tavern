defmodule Tavern.EmbedTestHelpers do
  @moduledoc """
  Link-embed test helpers: page stubs for `Tavern.Embeds.SafeHTTP`, and a wait for the
  background fetches a message write starts.
  """

  import ExUnit.Assertions

  # A real 1x1 PNG, so a browser in an e2e run can decode the stored card image.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  def png, do: @png

  @doc """
  Stubs the link-preview network with pages at site.test: `/a` and `/b` have an Open Graph
  card with an image, YouTube answers oEmbed for any video. Each request is reported to
  `test_pid` as `{:embed_request, host, path}`. The stub is shared, because the fetch runs in a
  task the test did not start.
  """
  def stub_link_previews(test_pid) do
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(Tavern.Embeds.SafeHTTP, fn conn ->
      send(test_pid, {:embed_request, conn.host, conn.request_path})

      case {conn.host, conn.request_path} do
        {"site.test", "/" <> page} when page in ["a", "b"] ->
          Req.Test.html(conn, """
          <meta property="og:title" content="Page #{String.upcase(page)}">
          <meta property="og:description" content="About #{page}.">
          <meta property="og:image" content="https://images.site.test/#{page}.png">
          """)

        {"images.site.test", _path} ->
          conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, @png)

        {"www.youtube.com", "/oembed"} ->
          Req.Test.json(conn, %{"title" => "A video", "author_name" => "A channel"})

        {"i.ytimg.com", _path} ->
          conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, @png)

        _other ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  @doc "Waits until every running embed fetch has finished."
  def await_embed_fetches do
    for pid <- Task.Supervisor.children(Tavern.Embeds.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    :ok
  end
end
