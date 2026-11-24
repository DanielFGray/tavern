defmodule TavernWeb.Plugs.ContentSecurityPolicyTest do
  @moduledoc """
  Pages run scripts only from this origin or with the request's nonce, the root layout's inline
  theme script carries that nonce, and images load only from this origin.
  """
  use TavernWeb.ConnCase, async: true

  test "the inline theme script carries the nonce the policy allows", %{conn: conn} do
    conn = get(conn, ~p"/login")
    nonce = policy_nonce(conn)

    assert nonce

    assert conn
           |> html_response(200)
           |> LazyHTML.from_document()
           |> LazyHTML.query("head script:not([src])")
           |> LazyHTML.attribute("nonce") == [nonce]
  end

  test "frames come from this origin and the YouTube no-cookie player, images from this origin",
       %{conn: conn} do
    [policy] = conn |> get(~p"/login") |> get_resp_header("content-security-policy")

    assert policy =~ "frame-src 'self' https://www.youtube-nocookie.com;"
    assert policy =~ "frame-ancestors 'self';"
    assert policy =~ "img-src 'self' data: blob:;"
  end

  test "each response has its own nonce", %{conn: conn} do
    refute policy_nonce(get(conn, ~p"/login")) == policy_nonce(get(build_conn(), ~p"/login"))
  end

  defp policy_nonce(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "script-src 'self' 'nonce-"

    case Regex.run(~r/'nonce-([^']+)'/, policy) do
      [_, nonce] -> nonce
      nil -> nil
    end
  end
end
