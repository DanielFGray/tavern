defmodule TavernWeb.ServerLive.MessageSearch do
  @moduledoc """
  The message search drawer. `:message_search` is nil while the drawer is closed, or
  `%{query, form, results, next}`: `results` are the messages `Chat.search_messages/3` found,
  newest first, and `next` the cursor of the page after them, nil on the last page.
  """

  use TavernWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_patch: 2]

  alias Tavern.Chat
  alias Tavern.Chat.Channel

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
  Closes the drawer and opens the conversation that holds result `message_id`: its channel, or
  its thread under the thread's parent. An id the drawer did not list does nothing.
  """
  def open_result(socket, message_id) do
    with %{results: results} <- socket.assigns.message_search,
         %{channel: channel} <- Enum.find(results, &(&1.id == message_id)),
         path when is_binary(path) <- conversation_path(socket, channel) do
      socket |> close() |> push_patch(to: path)
    else
      _ -> socket
    end
  end

  defp conversation_path(socket, %Channel{} = channel) do
    if Channel.thread?(channel) do
      parent = Enum.find(socket.assigns.channels, &(&1.id == channel.parent_channel_id))

      parent && ~p"/?channel=#{parent.slug}&thread=#{channel.id}"
    else
      ~p"/?channel=#{channel.slug}"
    end
  end
end
