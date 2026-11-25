defmodule Tavern.Embeds.PinnedAdapter do
  @moduledoc """
  A `Req` adapter that sends one request (with its body, if any) over one new Mint connection to
  an address the caller already checked, then closes it. TLS still verifies the certificate for the URL's host name,
  which Mint uses for SNI, the certificate check and the Host header.

  Req's default adapter can pin an address only through a `connect_options: [hostname: ...]`
  pool, and it starts one pool per distinct option set. Link previews reach hosts users choose,
  so those pools would grow without bound.
  """

  @doc "Sets the checked address to connect to, and the `deadline` (monotonic milliseconds)."
  def pin(%Req.Request{} = request, address, deadline) do
    request
    |> Req.Request.put_private(:pinned_address, address)
    |> Req.Request.put_private(:pinned_deadline, deadline)
  end

  @doc """
  Runs `request` against its pinned address and returns `{request, response}` or `{request,
  exception}`. The body goes through the request's `into:` function, which may halt the read.
  The read stops at the pinned deadline.
  """
  def run(%Req.Request{url: %URI{} = uri} = request) do
    address = Req.Request.get_private(request, :pinned_address)
    deadline = Req.Request.get_private(request, :pinned_deadline)

    with {:ok, scheme} <- scheme(uri),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme, address, uri.port,
             hostname: uri.host,
             mode: :passive,
             protocols: [:http1],
             transport_opts: transport_opts(address, deadline)
           ) do
      {conn, result} =
        case Mint.HTTP.request(conn, method(request), path(uri), headers(request), request.body) do
          {:ok, conn, ref} ->
            receive_response(conn, ref, {request, Req.Response.new()}, deadline)

          {:error, conn, error} ->
            {conn, {request, error}}
        end

      Mint.HTTP.close(conn)
      result
    else
      {:error, error} -> {request, error}
    end
  end

  defp receive_response(conn, ref, {request, _response} = acc, deadline) do
    case remaining(deadline) do
      timeout when timeout <= 0 ->
        {conn, {request, %Mint.TransportError{reason: :timeout}}}

      timeout ->
        case Mint.HTTP.recv(conn, 0, timeout) do
          {:ok, conn, parts} ->
            case handle_parts(parts, ref, acc) do
              {:done, acc} -> {conn, acc}
              {:cont, acc} -> receive_response(conn, ref, acc, deadline)
            end

          {:error, conn, error, _parts} ->
            {conn, {request, error}}
        end
    end
  end

  defp handle_parts([], _ref, acc), do: {:cont, acc}

  defp handle_parts([part | rest], ref, {request, response} = acc) do
    case part do
      {:status, ^ref, status} ->
        handle_parts(rest, ref, {request, %{response | status: status}})

      {:headers, ^ref, headers} ->
        response = Enum.reduce(headers, response, &put_header/2)
        handle_parts(rest, ref, {request, response})

      {:data, ^ref, data} ->
        case request.into.({:data, data}, acc) do
          {:cont, acc} -> handle_parts(rest, ref, acc)
          {:halt, acc} -> {:done, acc}
        end

      {:done, ^ref} ->
        {:done, acc}

      _other ->
        handle_parts(rest, ref, acc)
    end
  end

  defp put_header({name, value}, response), do: Req.Response.put_header(response, name, value)

  defp scheme(%URI{scheme: "http"}), do: {:ok, :http}
  defp scheme(%URI{scheme: "https"}), do: {:ok, :https}
  defp scheme(_uri), do: {:error, %ArgumentError{message: "unsupported scheme"}}

  defp method(request), do: request.method |> to_string() |> String.upcase()

  defp path(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query, do: path <> "?" <> query, else: path
  end

  defp headers(request) do
    for {name, values} <- request.headers, value <- List.wrap(values), do: {name, value}
  end

  defp transport_opts(address, deadline) do
    timeout = [timeout: max(remaining(deadline), 1)]
    if tuple_size(address) == 8, do: [{:inet6, true} | timeout], else: timeout
  end

  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)
end
