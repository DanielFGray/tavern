defmodule Tavern.Embeds.SafeHTTP do
  @moduledoc """
  Requests a URL that a member chose (a link in a message, a Web Push endpoint), without letting
  the member point the server at itself or its private network (server-side request forgery).

  Every hop, the first request and each redirect (at most three), is checked the same way:

    * the scheme is http or https, the port is 80 or 443, and the URL holds no user info;
    * the host resolves, and no address it resolves to is loopback, private, link-local,
      CGNAT (`100.64.0.0/10`, the tailnet), unique-local, multicast, reserved or unspecified.
      An IPv6 address that carries an IPv4 one (mapped, NAT64, 6to4) is judged by the IPv4 one;
    * the connection goes to the checked address (`Tavern.Embeds.PinnedAdapter`), so a second DNS
      answer cannot swap in another one.

  The whole fetch, all hops included, has five seconds. The body is read up to `:max_bytes`.

  Configuration under `config :tavern, Tavern.Embeds.SafeHTTP`:

    * `:resolver` - a module with `resolve(host, timeout_ms)`, default `Tavern.Embeds.DNS`.
    * `:req_options` - extra `Req` options. Tests set `plug:` here, which replaces the pinned
      adapter; every check above still runs.
  """

  import Bitwise

  alias Tavern.Embeds.PinnedAdapter

  @max_redirects 3
  @timeout_ms 5_000
  @user_agent "TavernBot (+link previews)"
  @redirect_statuses [301, 302, 303, 307, 308]
  @allowed_ports [80, 443]

  @blocked_v4 [
    # "This network", which holds the unspecified address 0.0.0.0.
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    # CGNAT. The tailnet's addresses live here.
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    # Multicast, then reserved and broadcast.
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @blocked_v6 [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    # Unique-local, link-local, the retired site-local, multicast.
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFEC0, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc """
  GETs `url`, following up to #{@max_redirects} redirects, and returns the final response as
  `{:ok, %{url: final_url, content_type: type_or_nil, body: body}}`. Any status other than 2xx
  at the end is `{:error, {:status, status}}`.

  Options:

    * `:max_bytes` (required) - how much of the body to read.
    * `:over_limit` - `:truncate` (default) keeps the first `:max_bytes`; `:refuse` answers
      `{:error, :too_large}`.
    * `:accept` - the Accept header, default `*/*`.
  """
  def get(url, opts) when is_binary(url) do
    deadline = System.monotonic_time(:millisecond) + @timeout_ms
    follow(url, opts, deadline, 0)
  end

  @doc """
  POSTs `body` to `url` once, with no redirect, and returns `{:ok, %{status: status, body: body}}`
  for any status, so the caller decides what each one means. Web Push posts to a URL a member's
  browser chose, so it takes the same checks as a GET.

  Options: `:headers` (a list of pairs), `:user_agent`, and `:max_bytes` for the answer body
  (default 4096).
  """
  def post(url, body, opts \\ []) when is_binary(url) and is_binary(body) do
    deadline = System.monotonic_time(:millisecond) + @timeout_ms
    opts = opts |> Keyword.put(:method, :post) |> Keyword.put(:body, body)
    opts = Keyword.put_new(opts, :max_bytes, 4096)

    with {:ok, uri} <- check_url(url),
         {:ok, address} <- resolve_public(uri.host, deadline),
         {:ok, response} <- request(uri, address, opts, deadline) do
      {:ok, %{status: response.status, body: response.body}}
    end
  end

  defp follow(url, opts, deadline, hops) do
    with {:ok, uri} <- check_url(url),
         {:ok, address} <- resolve_public(uri.host, deadline),
         {:ok, response} <- request(uri, address, opts, deadline) do
      cond do
        response.status in @redirect_statuses ->
          redirect(uri, response, opts, deadline, hops)

        response.status in 200..299 ->
          {:ok,
           %{
             url: URI.to_string(uri),
             content_type: response |> Req.Response.get_header("content-type") |> List.first(),
             body: response.body
           }}

        true ->
          {:error, {:status, response.status}}
      end
    end
  end

  defp redirect(_uri, _response, _opts, _deadline, hops) when hops >= @max_redirects,
    do: {:error, :too_many_redirects}

  defp redirect(uri, response, opts, deadline, hops) do
    with [location | _] <- Req.Response.get_header(response, "location"),
         {:ok, location} <- URI.new(location) do
      uri |> URI.merge(location) |> URI.to_string() |> follow(opts, deadline, hops + 1)
    else
      _ -> {:error, :bad_redirect}
    end
  end

  defp check_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             port in @allowed_ports ->
        {:ok, uri}

      _ ->
        {:error, :refused_url}
    end
  end

  # Every address must be public: a host that answers with one public and one private address
  # is refused, so DNS cannot steer the connection into the private network.
  defp resolve_public(host, deadline) do
    with {:ok, addresses} <- resolve(host, remaining(deadline)) do
      case Enum.find(addresses, &blocked?/1) do
        nil -> {:ok, hd(addresses)}
        blocked -> {:error, {:blocked_address, :inet.ntoa(blocked) |> to_string()}}
      end
    end
  end

  defp resolve(_host, timeout_ms) when timeout_ms <= 0, do: {:error, :timeout}

  defp resolve(host, timeout_ms) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, [address]}
      {:error, _not_literal} -> resolver().resolve(host, timeout_ms)
    end
  end

  defp request(uri, address, opts, deadline) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    over_limit = Keyword.get(opts, :over_limit, :truncate)

    [
      method: Keyword.get(opts, :method, :get),
      url: uri,
      body: Keyword.get(opts, :body),
      headers:
        [
          {"user-agent", Keyword.get(opts, :user_agent, @user_agent)},
          {"accept", Keyword.get(opts, :accept, "*/*")}
        ] ++ Keyword.get(opts, :headers, []),
      adapter: PinnedAdapter,
      into: &collect(&1, &2, max_bytes, over_limit),
      redirect: false,
      retry: false,
      decode_body: false,
      compressed: false,
      receive_timeout: max(remaining(deadline), 1)
    ]
    |> Keyword.merge(Keyword.get(config(), :req_options, []))
    |> Req.new()
    |> PinnedAdapter.pin(address, deadline)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{} = response} ->
        case Req.Response.get_private(response, :refused) do
          nil -> {:ok, response}
          reason -> {:error, reason}
        end

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  # Collects the body up to `max_bytes`. A chunk can arrive larger than the whole limit, so the
  # check is on the total after the chunk, not on the chunk count.
  defp collect({:data, chunk}, {request, response}, max_bytes, over_limit) do
    body = response.body <> chunk

    cond do
      byte_size(body) <= max_bytes ->
        {:cont, {request, %{response | body: body}}}

      over_limit == :truncate ->
        {:halt, {request, %{response | body: binary_part(body, 0, max_bytes)}}}

      true ->
        {:halt, {request, Req.Response.put_private(response, :refused, :too_large)}}
    end
  end

  defp blocked?({_, _, _, _} = address), do: in_any?(address, @blocked_v4, 32, 8)

  defp blocked?({_, _, _, _, _, _, _, _} = address) do
    case embedded_v4(address) do
      nil -> in_any?(address, @blocked_v6, 128, 16)
      v4 -> blocked?(v4)
    end
  end

  # IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible (::a.b.c.d, which holds :: and ::1), NAT64
  # (64:ff9b::a.b.c.d) and 6to4 (2002:aabb:ccdd::) addresses all reach an IPv4 host.
  defp embedded_v4({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: v4(high, low)
  defp embedded_v4({0, 0, 0, 0, 0, 0, high, low}), do: v4(high, low)
  defp embedded_v4({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: v4(high, low)
  defp embedded_v4({0x2002, high, low, _, _, _, _, _}), do: v4(high, low)
  defp embedded_v4(_address), do: nil

  defp v4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp in_any?(address, ranges, bits, part_bits) do
    value = to_integer(address, part_bits)

    Enum.any?(ranges, fn {network, prefix} ->
      shift = bits - prefix
      value >>> shift == to_integer(network, part_bits) >>> shift
    end)
  end

  defp to_integer(address, part_bits),
    do: address |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< part_bits ||| &1))

  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp resolver, do: Keyword.get(config(), :resolver, Tavern.Embeds.DNS)

  defp config, do: Application.get_env(:tavern, __MODULE__, [])
end
