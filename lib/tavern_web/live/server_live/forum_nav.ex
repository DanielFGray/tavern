defmodule TavernWeb.ServerLive.ForumNav do
  @moduledoc """
  The post list of the open forum (docs/design/forums.md).

  `:forum` is nil unless the open channel is a forum. Then it is `%{channel, view, query,
  search_form, entries, next, post_form}`: `view` is the member's remembered `%{sort, layout}`,
  `query` the search (each `#tag` an exact tag, other words title words), `entries` the loaded
  pages of `Chat.list_forum_posts/3`, and `post_form` the New post form, or nil while it is
  closed.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  alias Tavern.Chat
  alias Tavern.Chat.Channel

  @doc "Loads the post list when `channel` is a forum, and clears it otherwise."
  def load(socket, %Channel{kind: :forum} = channel) do
    view = Chat.forum_post_view(socket.assigns.current_scope, channel.id)

    socket
    |> assign(:forum, %{
      channel: channel,
      view: view,
      query: "",
      search_form: search_form(""),
      entries: [],
      next: nil,
      post_form: nil
    })
    |> list_first_page()
  end

  def load(socket, _channel), do: assign(socket, :forum, nil)

  @doc """
  Reloads the first page of the open forum, after a post was created, changed or replied to. Does
  nothing outside a forum.
  """
  def reload(socket) do
    if socket.assigns.forum, do: list_first_page(socket), else: socket
  end

  @doc "Reloads the open forum when `channel` is one of its posts."
  def reload_for_post(socket, %Channel{parent_channel_id: parent_id}) do
    case socket.assigns.forum do
      %{channel: %{id: ^parent_id}} -> list_first_page(socket)
      _ -> socket
    end
  end

  def reload_for_post(socket, _channel), do: socket

  @doc "Sets the search and reloads."
  def search(socket, query) when is_binary(query) do
    socket
    |> update_forum(&%{&1 | query: query, search_form: search_form(query)})
    |> list_first_page()
  end

  @doc "Searches for exactly one tag, as clicking its chip does."
  def filter_tag(socket, tag), do: search(socket, "#" <> tag)

  @doc "Remembers a new sort or layout for the member, then reloads."
  def set_view(socket, attrs) do
    with %{channel: channel} <- socket.assigns.forum,
         {:ok, view} <- Chat.set_forum_post_view(socket.assigns.current_scope, channel.id, attrs) do
      socket
      |> update_forum(&%{&1 | view: view})
      |> list_first_page()
    else
      _ -> socket
    end
  end

  @doc "Appends the next page."
  def load_more(socket) do
    with %{next: next} = forum when not is_nil(next) <- socket.assigns.forum,
         {:ok, page} <- list(socket, forum, after: next) do
      update_forum(socket, &%{&1 | entries: &1.entries ++ page.entries, next: page.next})
    else
      _ -> socket
    end
  end

  def open_post_form(socket),
    do: update_forum(socket, &%{&1 | post_form: post_form(%{})})

  def close_post_form(socket), do: update_forum(socket, &%{&1 | post_form: nil})

  @doc "Shows the New post form's errors for `params` as the member types."
  def validate_post(socket, params),
    do: update_forum(socket, &%{&1 | post_form: post_form(params, :validate)})

  @doc """
  Creates a post from the New post form. Returns `{:ok, thread, socket}` with the form closed, or
  `{:error, reason, socket}` with the form showing the changeset's errors.
  """
  def create_post(socket, params) do
    %{channel: channel} = socket.assigns.forum

    case Chat.create_forum_post(socket.assigns.current_scope, channel.id, params) do
      {:ok, thread} ->
        {:ok, thread, socket |> close_post_form() |> list_first_page()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, :invalid,
         update_forum(socket, &%{&1 | post_form: to_form(changeset, as: :post)})}

      {:error, reason} ->
        {:error, reason, socket}
    end
  end

  defp list_first_page(socket) do
    forum = socket.assigns.forum

    case list(socket, forum, []) do
      {:ok, page} -> update_forum(socket, &%{&1 | entries: page.entries, next: page.next})
      {:error, :not_found} -> assign(socket, :forum, nil)
    end
  end

  defp list(socket, forum, opts) do
    Chat.list_forum_posts(
      socket.assigns.current_scope,
      forum.channel.id,
      [sort: forum.view.sort, query: forum.query] ++ opts
    )
  end

  defp update_forum(socket, fun) do
    case socket.assigns.forum do
      nil -> socket
      forum -> assign(socket, :forum, fun.(forum))
    end
  end

  defp search_form(query), do: to_form(%{"query" => query}, as: :forum_search)

  defp post_form(params, action \\ nil) do
    params
    |> Chat.change_forum_post()
    |> Map.put(:action, action)
    |> to_form(as: :post)
  end
end
