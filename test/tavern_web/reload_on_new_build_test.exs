defmodule TavernWeb.ReloadOnNewBuildTest do
  @moduledoc """
  A tab that joins with bundles from an earlier build is told to reload (`TavernWeb.ReloadOnNewBuild`).
  Dev and test serve no digest manifest, so each test puts one in the endpoint's config the way a
  release does at boot.
  """
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @latest %{
    "assets/js/app.js" => "assets/js/app-new.js",
    "assets/css/app.css" => "assets/css/app-new.css"
  }

  setup do
    previous = TavernWeb.Endpoint.config(:cache_static_manifest_latest)
    Phoenix.Config.put(TavernWeb.Endpoint, :cache_static_manifest_latest, @latest)

    on_exit(fn ->
      Phoenix.Config.put(TavernWeb.Endpoint, :cache_static_manifest_latest, previous)
    end)
  end

  test "a tab running an earlier build is told to reload", %{conn: conn} do
    {:ok, view, _html} = conn |> track_static("app-old") |> live(~p"/login")

    assert_push_event(view, "static_changed", %{})
  end

  test "a tab running the current build is left alone", %{conn: conn} do
    {:ok, view, _html} = conn |> track_static("app-new") |> live(~p"/login")

    refute_push_event(view, "static_changed", _payload)
  end

  defp track_static(conn, name) do
    put_connect_params(conn, %{
      "_track_static" => [
        "http://localhost/assets/js/#{name}.js?vsn=d",
        "http://localhost/assets/css/#{name}.css?vsn=d"
      ]
    })
  end
end
