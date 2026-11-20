defmodule TavernWeb.Plugs.ClientIp do
  @moduledoc """
  Sets `conn.remote_ip` to the client address that the platform proxy wrote into the header
  named by `TRUSTED_PROXY_HEADER`.

  The header must hold one address that the proxy sets itself and never takes from the client:
  on a public route Traefik writes `X-Real-Ip` from the socket and drops a client-sent value
  (roamancer `tools/alchemy/platform/ingress/README.md:10`), so the cartridge sets
  `TRUSTED_PROXY_HEADER=x-real-ip`. A list header such as `X-Forwarded-For` is unsafe here: a
  client can write its leading entries. See docs/design/accounts.md, "Client address".
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    %{conn | remote_ip: client_ip(conn.remote_ip, conn.req_headers)}
  end

  @doc """
  The client address for a request: the address in the header that TRUSTED_PROXY_HEADER names,
  or the peer address when the header is unset, missing or not an address. `headers` are
  `{name, value}` pairs with lowercase names, as Plug and Phoenix connect_info give them.
  """
  def client_ip(peer_ip, headers) do
    case Application.get_env(:tavern, :trusted_proxy_header) do
      nil -> peer_ip
      header -> forwarded_ip(peer_ip, headers, String.downcase(header))
    end
  end

  @doc """
  The client address of a LiveView socket, by the same rule as `client_ip/2`. Call it from
  `mount/3`: connect info is readable only there. Returns nil when the socket has no peer.
  """
  def socket_client_ip(socket) do
    peer_data = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
    client_ip(peer_data && peer_data.address, headers)
  end

  defp forwarded_ip(peer_ip, headers, trusted_header) do
    with {_name, value} <- List.keyfind(headers, trusted_header, 0),
         {:ok, ip_address} <-
           value |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      ip_address
    else
      _ -> peer_ip
    end
  end
end
