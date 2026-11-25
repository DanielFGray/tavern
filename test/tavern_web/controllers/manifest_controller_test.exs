defmodule TavernWeb.ManifestControllerTest do
  use TavernWeb.ConnCase, async: false

  test "the manifest names the server and makes Tavern installable", %{conn: conn} do
    conn = get(conn, ~p"/manifest.webmanifest")

    assert response_content_type(conn, :json) =~ "application/manifest+json"
    manifest = Jason.decode!(response(conn, 200))

    assert manifest["display"] == "standalone"
    assert manifest["start_url"] == "/"
    assert is_binary(manifest["name"]) and manifest["name"] != ""
    assert Enum.any?(manifest["icons"], &(&1["sizes"] == "512x512"))
  end
end
