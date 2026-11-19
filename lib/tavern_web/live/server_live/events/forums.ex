defmodule TavernWeb.ServerLive.Events.Forums do
  @moduledoc false

  use TavernWeb, :verified_routes

  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]

  alias TavernWeb.ServerLive.ForumNav

  def handle_event("forum_search", %{"forum_search" => %{"query" => query}}, socket),
    do: {:noreply, ForumNav.search(socket, query)}

  def handle_event("forum_tag", %{"tag" => tag}, socket),
    do: {:noreply, ForumNav.filter_tag(socket, tag)}

  def handle_event("forum_view", params, socket),
    do: {:noreply, ForumNav.set_view(socket, Map.take(params, ["sort", "layout"]))}

  def handle_event("forum_tab", %{"tab" => tab}, socket) when tab in ["active", "archived"],
    do: {:noreply, ForumNav.set_tab(socket, String.to_existing_atom(tab))}

  def handle_event("forum_more", _params, socket),
    do: {:noreply, ForumNav.load_more(socket)}

  def handle_event("new_forum_post", _params, socket),
    do: {:noreply, ForumNav.open_post_form(socket)}

  def handle_event("cancel_forum_post", _params, socket),
    do: {:noreply, ForumNav.close_post_form(socket)}

  def handle_event("validate_forum_post", %{"post" => params}, socket),
    do: {:noreply, ForumNav.validate_post(socket, params)}

  def handle_event("create_forum_post", %{"post" => params}, socket) do
    case ForumNav.create_post(socket, params) do
      {:ok, thread, socket} ->
        forum = socket.assigns.forum.channel
        {:noreply, push_patch(socket, to: ~p"/?channel=#{forum.slug}&thread=#{thread.id}")}

      {:error, :invalid, socket} ->
        {:noreply, socket}

      {:error, {:slowmode, seconds}, socket} ->
        {:noreply, put_flash(socket, :error, "Slowmode is on. Wait #{seconds}s to post again.")}

      {:error, _refusal, socket} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to post here.")}
    end
  end
end
