defmodule TavernWeb.ServerLive.MessageSearch do
  @moduledoc """
  The message search drawer. `:message_search` is nil while the drawer is closed, or
  `%{query, form, results, next}`: `results` are the messages `Chat.search_messages/3` found,
  newest first, and `next` the cursor of the page after them, nil on the last page.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_patch: 2]

  alias Tavern.Chat
  alias TavernWeb.ServerLive.MessageJump

  def open(socket), do: search(socket, "")

  def close(socket), do: assign(socket, :message_search, nil)

  @doc "Runs `query` from its first page. A blank query shows no results."
  def search(socket, query) do
    {results, next} =
      case Chat.search_messages(socket.assigns.current_scope, query) do
        {:ok, %{messages: messages, next: next}} -> {messages, next}
      end

    assign(socket, :message_search, %{
      query: query,
      form: to_form(%{"query" => query}, as: :message_search),
      results: results,
      next: next
    })
  end

  @doc "Appends the next page of the open search."
  def load_more(socket) do
    with %{next: next, query: query} = search when not is_nil(next) <-
           socket.assigns.message_search,
         {:ok, page} <- Chat.search_messages(socket.assigns.current_scope, query, after: next) do
      assign(socket, :message_search, %{
        search
        | results: search.results ++ page.messages,
          next: page.next
      })
    else
      _ -> socket
    end
  end

  @doc """
  Closes the drawer and opens result `message_id` in place (`MessageJump`). An id the drawer did
  not list does nothing.
  """
  def open_result(socket, message_id) do
    with %{results: results} <- socket.assigns.message_search,
         %{channel: channel} <- Enum.find(results, &(&1.id == message_id)),
         path when is_binary(path) <- MessageJump.message_path(socket, channel, message_id) do
      socket |> close() |> push_patch(to: path)
    else
      _ -> socket
    end
  end
end
