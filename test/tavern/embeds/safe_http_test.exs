defmodule Tavern.Embeds.SafeHTTPTest do
  @moduledoc """
  The fetcher refuses every URL that could reach the server itself or its private network, on
  the first request and on every redirect. Requests go to a `Req.Test` stub; host names resolve
  from `Tavern.TestDNS`.
  """
  use ExUnit.Case, async: true

  alias Tavern.Embeds.SafeHTTP

  @opts [max_bytes: 1_000]

  setup do
    test_pid = self()

    Req.Test.stub(SafeHTTP, fn conn ->
      send(test_pid, {:requested, conn.host, conn.request_path, conn.req_headers})

      case conn.request_path do
        "/to-private" -> redirect(conn, "http://internal.site.test/secret")
        "/to-loopback" -> redirect(conn, "http://127.0.0.1/admin")
        "/hop3" -> Req.Test.text(conn, "landed")
        "/hop" <> n -> redirect(conn, "/hop#{String.to_integer(n) + 1}")
        "/loop" -> redirect(conn, "/loop")
        "/big" -> Req.Test.text(conn, String.duplicate("a", 5_000))
        "/missing" -> Plug.Conn.send_resp(conn, 404, "")
        _ -> Req.Test.text(conn, "ok")
      end
    end)

    :ok
  end

  test "fetches a public URL with the plain user agent" do
    assert {:ok, %{url: "https://site.test/page", body: "ok"}} =
             SafeHTTP.get("https://site.test/page", @opts)

    assert_received {:requested, "site.test", "/page", headers}
    assert {"user-agent", "TavernBot (+link previews)"} in headers
  end

  test "refuses each private, local and special address range" do
    for host <- [
          "127.0.0.1",
          "10.1.2.3",
          "172.16.0.1",
          "192.168.0.10",
          "169.254.169.254",
          "100.64.0.1",
          "100.127.255.254",
          "0.0.0.0",
          "224.0.0.1",
          "255.255.255.255",
          "[::1]",
          "[::]",
          "[fd00::1]",
          "[fe80::1]",
          "[ff02::1]",
          "[::ffff:127.0.0.1]",
          "[64:ff9b::a00:1]",
          "internal.site.test",
          "tailnet.site.test",
          "mapped.site.test",
          "mixed.site.test"
        ] do
      assert {:error, {:blocked_address, _}} = SafeHTTP.get("http://#{host}/", @opts), host
    end

    refute_received {:requested, _, _, _}
  end

  test "refuses other schemes, other ports and user info" do
    for url <- [
          "ftp://site.test/",
          "file:///etc/passwd",
          "http://site.test:8080/",
          "https://site.test:22/",
          "http://user:pass@site.test/"
        ] do
      assert {:error, :refused_url} = SafeHTTP.get(url, @opts), url
    end
  end

  test "refuses a public URL that redirects to a private one" do
    assert {:error, {:blocked_address, "10.0.0.7"}} =
             SafeHTTP.get("https://site.test/to-private", @opts)

    assert {:error, {:blocked_address, "127.0.0.1"}} =
             SafeHTTP.get("https://site.test/to-loopback", @opts)

    assert_received {:requested, "site.test", "/to-private", _}
    refute_received {:requested, "internal.site.test", _, _}
  end

  test "follows at most three redirects" do
    assert {:ok, %{url: "https://site.test/hop3", body: "landed"}} =
             SafeHTTP.get("https://site.test/hop0", @opts)

    assert {:error, :too_many_redirects} = SafeHTTP.get("https://site.test/loop", @opts)
  end

  test "a host that does not resolve is refused" do
    assert {:error, :nxdomain} = SafeHTTP.get("https://unknown.example.org/", @opts)
  end

  test "truncates or refuses a body over the limit" do
    assert {:ok, %{body: body}} = SafeHTTP.get("https://site.test/big", @opts)
    assert byte_size(body) == 1_000

    assert {:error, :too_large} =
             SafeHTTP.get("https://site.test/big", Keyword.put(@opts, :over_limit, :refuse))
  end

  test "a final status other than 2xx is an error" do
    assert {:error, {:status, 404}} = SafeHTTP.get("https://site.test/missing", @opts)
  end

  defp redirect(conn, location) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(302, "")
  end
end
