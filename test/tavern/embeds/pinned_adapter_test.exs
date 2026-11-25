defmodule Tavern.Embeds.PinnedAdapterTest do
  @moduledoc """
  Drives the adapter against a loopback listener. The URL names a host that does not resolve,
  so a response proves the connection went to the pinned address and not to DNS.
  """
  use ExUnit.Case, async: true

  alias Tavern.Embeds.PinnedAdapter

  @behaviour Plug

  setup do
    server = start_supervised!({Bandit, plug: {__MODULE__, self()}, ip: :loopback, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://pinned.invalid:#{port}"}
  end

  test "connects to the pinned address and sends the URL's host", %{url: url} do
    {_request, response} = run(url <> "/hello?x=1", 2_000)

    assert response.status == 200
    assert response.body == "hello"
    assert_received {:served, "pinned.invalid", "/hello", "x=1"}
  end

  test "sends a POST's body and headers as given", %{url: url} do
    {_request, response} =
      run(url <> "/post", 2_000,
        method: :post,
        body: <<0, 1, 2, 255>>,
        headers: [{"content-encoding", "aes128gcm"}]
      )

    assert response.status == 201
    assert_received {:posted, "POST", "aes128gcm", <<0, 1, 2, 255>>}
  end

  test "stops reading when the into function halts", %{url: url} do
    into = fn {:data, chunk}, {request, response} ->
      {:halt, {request, %{response | body: response.body <> chunk}}}
    end

    {_request, response} = run(url <> "/stream", 2_000, into: into)

    assert response.body == "chunk-1"
  end

  test "gives up at the deadline", %{url: url} do
    assert {_request, %Mint.TransportError{reason: :timeout}} = run(url <> "/stall", 200)
  end

  @impl Plug
  def init(test_pid), do: test_pid

  @impl Plug
  def call(conn, test_pid) do
    send(test_pid, {:served, conn.host, conn.request_path, conn.query_string})

    case conn.request_path do
      "/post" ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [encoding] = Plug.Conn.get_req_header(conn, "content-encoding")
        send(test_pid, {:posted, conn.method, encoding, body})
        Plug.Conn.send_resp(conn, 201, "")

      "/stream" ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "chunk-1")
        {:ok, conn} = Plug.Conn.chunk(conn, "chunk-2")
        conn

      "/stall" ->
        receive do
          :never -> conn
        after
          1_000 -> Plug.Conn.send_resp(conn, 200, "late")
        end

      _path ->
        Plug.Conn.send_resp(conn, 200, "hello")
    end
  end

  defp run(url, budget_ms, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + budget_ms

    into =
      Keyword.get(opts, :into, fn {:data, chunk}, {request, response} ->
        {:cont, {request, %{response | body: response.body <> chunk}}}
      end)

    [url: url, into: into]
    |> Keyword.merge(Keyword.take(opts, [:method, :body, :headers]))
    |> Req.new()
    |> PinnedAdapter.pin({127, 0, 0, 1}, deadline)
    |> PinnedAdapter.run()
  end
end
