defmodule Tavern.TestDNS do
  @moduledoc """
  The test environment's resolver for `Tavern.Embeds.SafeHTTP`: a fixed table, so no test
  reaches real DNS. A host not in the table does not resolve, so a message link in any other
  test fetches nothing.
  """

  @hosts %{
    "site.test" => [{93, 184, 215, 14}],
    "www.site.test" => [{93, 184, 215, 14}],
    "images.site.test" => [{93, 184, 215, 15}],
    "www.youtube.com" => [{142, 250, 72, 110}],
    "i.ytimg.com" => [{142, 250, 72, 118}],
    "internal.site.test" => [{10, 0, 0, 7}],
    "mixed.site.test" => [{93, 184, 215, 14}, {192, 168, 1, 20}],
    "tailnet.site.test" => [{100, 101, 102, 103}],
    "mapped.site.test" => [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}]
  }

  def resolve(host, _timeout_ms) do
    case Map.fetch(@hosts, host) do
      {:ok, addresses} -> {:ok, addresses}
      :error -> {:error, :nxdomain}
    end
  end
end
