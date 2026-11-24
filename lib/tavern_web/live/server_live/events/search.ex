defmodule TavernWeb.ServerLive.Events.Search do
  @moduledoc false

  alias TavernWeb.ServerLive.MessageSearch

  @events ~w(
    open_message_search
    close_message_search
    message_search
    message_search_more
    open_search_result
  )

  def events, do: @events

  def handle_event("open_message_search", _params, socket),
    do: {:noreply, MessageSearch.open(socket)}

  def handle_event("close_message_search", _params, socket),
    do: {:noreply, MessageSearch.close(socket)}

  def handle_event("message_search", %{"message_search" => %{"query" => query}}, socket)
      when is_binary(query),
      do: {:noreply, MessageSearch.search(socket, query)}

  def handle_event("message_search_more", _params, socket),
    do: {:noreply, MessageSearch.load_more(socket)}

  def handle_event("open_search_result", %{"id" => message_id}, socket),
    do: {:noreply, MessageSearch.open_result(socket, message_id)}
end
