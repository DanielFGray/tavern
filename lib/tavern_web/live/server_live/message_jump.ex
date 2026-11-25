defmodule TavernWeb.ServerLive.MessageJump do
  @moduledoc """
  Opens a message in place. The URL's `message` param names it, beside the `channel` and
  `thread` params of its conversation. That conversation's pane loads the window of messages
  around it, and the transcript scrolls to it and flashes it. In a text channel a thread renders
  inside its starter's row, so a message in a thread also loads the channel pane around the
  starter.

  A pane loads the window for the URL's message when it opens (`target/3`), and `follow/1`
  loads it again when the URL names another message. A URL without a message leaves the window
  in place, so opening or closing a thread does not lose the reader's place. The reader returns
  to the newest page with "Jump to present" or by sending a message (`present/2`).

  Search results, pinned messages and reply previews link to `message_path/3`; an alert builds
  the same URL (`Tavern.Chat.Alerts`).
  """

  use TavernWeb, :verified_routes

  import Phoenix.LiveView, only: [push_event: 3, push_patch: 2, put_flash: 3]

  alias Tavern.Chat
  alias Tavern.Chat.Channel
  alias TavernWeb.ServerLive.Pane
  alias TavernWeb.ServerLive.State

  @doc """
  The message the URL asks the pane of `kind` to show, for `conversation`:
  `{:message, id}` for the `message` param in its own conversation, `{:host, id}` for the
  starter of the URL's thread in a text channel, or nil for the newest page.
  """
  def target(socket, kind, conversation) do
    case {kind, socket.assigns.url_params} do
      {:thread, %{"thread" => id, "message" => message_id}} when id == conversation.id ->
        {:message, message_id}

      {:channel, %{"thread" => thread_id, "message" => _}} ->
        thread_host(socket, conversation, thread_id)

      {:channel, %{"dm" => id, "message" => message_id}} when id == conversation.id ->
        {:message, message_id}

      {:channel, %{"channel" => slug, "message" => message_id}} when slug == conversation.slug ->
        {:message, message_id}

      _ ->
        nil
    end
  end

  @doc """
  Loads each open pane for the message the URL names, unless it already holds that window, then
  scrolls to it. Runs after every URL change, once the URL's channel and thread are open, so
  following the same link twice only scrolls.
  """
  def follow(socket) do
    Enum.reduce(Pane.kinds(), socket, fn kind, socket ->
      with %{} = conversation <- State.conversation(socket, kind),
           {_reason, _id} = target <- target(socket, kind, conversation) do
        socket =
          if State.pane(socket, kind).jump == target,
            do: socket,
            else: State.reload_pane(socket, kind, target)

        focus(socket, kind, target)
      else
        _ -> socket
      end
    end)
  end

  @doc """
  Returns the pane of `kind` to its conversation's newest page and the channel transcript to its
  bottom, when the pane holds a window around an older message, and drops the `message` param
  from the URL, so a reload of the page shows the present too.
  """
  def present(socket, kind) do
    socket =
      if State.pane(socket, kind).newer_cursor,
        do: socket |> State.reload_pane(kind, nil) |> scroll_to_bottom(kind),
        else: socket

    case socket.assigns.url_params do
      %{"message" => _} = params -> push_patch(socket, to: ~p"/?#{Map.delete(params, "message")}")
      _ -> socket
    end
  end

  @doc """
  Says that the URL's message is not shown, once, when the pane loading it cannot list it: the
  same words for a deleted message and a hidden one. A thread's starter that cannot be listed
  is not the reader's message, so it says nothing.
  """
  def refuse(socket, {:message, _id}),
    do: put_flash(socket, :error, "That message is not available.")

  def refuse(socket, {:host, _id}), do: socket

  @doc """
  The URL that opens message `message_id` in place, in `channel`: a channel, a direct message,
  or a thread under its parent. A thread whose parent the member cannot see has no URL.
  """
  def message_path(socket, %Channel{} = channel, message_id) do
    cond do
      Channel.direct?(channel) ->
        ~p"/?dm=#{channel.id}&message=#{message_id}"

      Channel.thread?(channel) ->
        parent = Enum.find(socket.assigns.channels, &(&1.id == channel.parent_channel_id))
        parent && ~p"/?channel=#{parent.slug}&thread=#{channel.id}&message=#{message_id}"

      true ->
        ~p"/?channel=#{channel.slug}&message=#{message_id}"
    end
  end

  @doc """
  Opens message `message_id` in place, when the member can see it. An id that names no message
  the member can see does nothing.
  """
  def open(socket, message_id) do
    with [message] <- Chat.get_messages(socket.assigns.current_scope, [message_id]),
         path when is_binary(path) <- message_path(socket, message.channel, message.id) do
      push_patch(socket, to: path)
    else
      _ -> socket
    end
  end

  # A message in a thread of a text channel needs its thread's starter on screen, because the
  # thread renders inside the starter's row. A forum lists its posts, not a transcript.
  defp thread_host(socket, %Channel{} = channel, thread_id) do
    with false <- Channel.forum?(channel),
         %Channel{starter_message_id: starter_id, parent_channel_id: parent_id}
         when parent_id == channel.id <- Chat.get_thread(socket.assigns.current_scope, thread_id) do
      {:host, starter_id}
    else
      _ -> nil
    end
  end

  # Only the channel list is a scroll box; a thread's newest reply is already under its composer.
  defp scroll_to_bottom(socket, :channel), do: push_event(socket, "message:focus", %{id: nil})
  defp scroll_to_bottom(socket, :thread), do: socket

  # The row's DOM id is the stream's name and the message id (`Pane.stream_name/1`). Only the
  # URL's own message flashes.
  defp focus(socket, kind, {reason, message_id}) do
    push_event(socket, "message:focus", %{
      id: "#{Pane.stream_name(kind)}-#{message_id}",
      highlight: reason == :message
    })
  end
end
