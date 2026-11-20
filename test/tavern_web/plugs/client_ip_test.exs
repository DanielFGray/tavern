defmodule TavernWeb.Plugs.ClientIpTest do
  use ExUnit.Case, async: false

  alias TavernWeb.Plugs.ClientIp

  @peer {127, 0, 0, 1}
  @client {203, 0, 113, 7}

  setup do
    previous = Application.get_env(:tavern, :trusted_proxy_header)
    Application.put_env(:tavern, :trusted_proxy_header, "x-real-ip")
    on_exit(fn -> Application.put_env(:tavern, :trusted_proxy_header, previous) end)
    :ok
  end

  test "uses the address in the trusted header" do
    assert ClientIp.client_ip(@peer, [{"x-real-ip", "203.0.113.7"}]) == @client
  end

  test "sets remote_ip on the conn" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-real-ip", "203.0.113.7")
      |> ClientIp.call([])

    assert conn.remote_ip == @client
  end

  test "a client-sent X-Forwarded-For has no effect" do
    headers = [{"x-forwarded-for", "198.51.100.99, 198.51.100.98"}, {"x-real-ip", "203.0.113.7"}]
    assert ClientIp.client_ip(@peer, headers) == @client
    assert ClientIp.client_ip(@peer, [{"x-forwarded-for", "198.51.100.99"}]) == @peer

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.99")
      |> Plug.Conn.put_req_header("x-real-ip", "203.0.113.7")
      |> ClientIp.call([])

    assert conn.remote_ip == @client
  end

  test "falls back to the peer address for a missing or malformed header" do
    assert ClientIp.client_ip(@peer, []) == @peer
    assert ClientIp.client_ip(@peer, [{"x-real-ip", "not-an-ip"}]) == @peer
    assert ClientIp.client_ip(@peer, [{"x-real-ip", ""}]) == @peer
    assert ClientIp.client_ip(@peer, [{"x-real-ip", "203.0.113.7, 198.51.100.9"}]) == @peer
  end

  test "leaves remote_ip unchanged when the header is not configured" do
    Application.delete_env(:tavern, :trusted_proxy_header)

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-real-ip", "203.0.113.7")
      |> ClientIp.call([])

    assert conn.remote_ip == {127, 0, 0, 1}
  end

  test "matches a configured header name written in any case" do
    Application.put_env(:tavern, :trusted_proxy_header, "X-Real-Ip")
    assert ClientIp.client_ip(@peer, [{"x-real-ip", "203.0.113.7"}]) == @client
  end

  test "parses IPv6 addresses" do
    assert ClientIp.client_ip(@peer, [{"x-real-ip", "2001:db8::1"}]) ==
             {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
  end

  describe "socket_client_ip/1" do
    test "uses the trusted header and ignores a client-sent X-Forwarded-For" do
      socket =
        socket_with(%{address: @peer, port: 4000}, [
          {"x-forwarded-for", "198.51.100.99"},
          {"x-real-ip", "203.0.113.7"}
        ])

      assert ClientIp.socket_client_ip(socket) == @client
    end

    test "returns the peer address without the header, and nil without a peer" do
      forged = [{"x-forwarded-for", "198.51.100.99"}]

      assert ClientIp.socket_client_ip(socket_with(%{address: @peer, port: 4000}, forged)) ==
               @peer

      assert ClientIp.socket_client_ip(socket_with(nil, [])) == nil
    end
  end

  defp socket_with(peer_data, x_headers) do
    %Phoenix.LiveView.Socket{
      private: %{connect_info: %{peer_data: peer_data, x_headers: x_headers}}
    }
  end
end
