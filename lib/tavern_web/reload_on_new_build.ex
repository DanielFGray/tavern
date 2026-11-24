defmodule TavernWeb.ReloadOnNewBuild do
  @moduledoc """
  Tells a tab to reload when it runs JS or CSS from an earlier build.

  After a deploy an open tab reconnects its socket to the new server but keeps running the old
  `app.js`. The root layout marks the bundles with `phx-track-static`, so the client sends their
  URLs on join and `static_changed?/1` compares them with the server's digest manifest. When they
  differ this pushes `static_changed`, and `app.js` reloads the page. Composer drafts live in
  `localStorage`, so the reload keeps them.

  It runs from each `live_session` in the router, because `static_changed?/1` works only in a
  routed (root) LiveView, and only those run the session hooks.
  """

  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket =
      if static_changed?(socket), do: push_event(socket, "static_changed", %{}), else: socket

    {:cont, socket}
  end
end
