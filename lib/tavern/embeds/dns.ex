defmodule Tavern.Embeds.DNS do
  @moduledoc """
  Resolves a host name to every IPv4 and IPv6 address it has, so `Tavern.Embeds.SafeHTTP` can
  check all of them before it connects to one.
  """

  @doc "The host's addresses as `{:ok, [ip_tuple]}`, or `{:error, :nxdomain}` when it has none."
  def resolve(host, timeout_ms) when is_binary(host) do
    name = String.to_charlist(host)

    addresses =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(name, family, timeout_ms) do
          {:ok, addresses} -> addresses
          {:error, _reason} -> []
        end
      end)

    if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
  end
end
