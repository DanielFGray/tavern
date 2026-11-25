defmodule TavernWeb.ServerLive.Events.Messages do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3]

  alias Tavern.Accounts
  alias Tavern.Chat
  alias TavernWeb.ServerComponents.Composer
  alias TavernWeb.ServerLive.Attachments
  alias TavernWeb.ServerComponents.Helpers, as: RowHelpers
  alias TavernWeb.ServerLive.Events.Helpers
  alias TavernWeb.ServerLive.Events.Navigation
  alias TavernWeb.ServerLive.MessageJump
  alias TavernWeb.ServerLive.Pane
  alias TavernWeb.ServerLive.Pins
  alias TavernWeb.ServerLive.State
  alias TavernWeb.ServerLive.ThreadNav

  # Each composer sends its own event names (`data-composer-target` picks them in
  # `RichComposerHook`), so the name says which pane the event acts on.
  @send_events %{"send_message" => :channel, "send_thread_message" => :thread}
  @typing_ping_events %{"typing_ping" => :channel, "typing_ping_thread" => :thread}
  @typing_stop_events %{"typing_stop" => :channel, "typing_stop_thread" => :thread}

  @events ~w(
    toggle_message_controls
    toggle_message_action_menu
    close_message_action_menu
    confirm_delete_message
    cancel_delete_message
    reply_message
    cancel_reply
    edit_message
    cancel_edit
    save_edit
    delete_message
    suppress_embeds
    load_older_messages
    load_newer_messages
    open_message
    jump_to_present
  )

  @panes %{"channel" => :channel, "thread" => :thread}

  def events do
    @events ++
      Map.keys(@send_events) ++ Map.keys(@typing_ping_events) ++ Map.keys(@typing_stop_events)
  end

  def handle_info({:message_created, message}, socket) do
    socket =
      socket
      |> State.insert_message(message)
      |> list_direct_message(message)
      |> update_unread_state(message)

    {:noreply, socket}
  end

  def handle_info({type, channel_id, user_id}, socket)
      when type in [:typing_started, :typing_stopped] do
    case State.pane_showing(socket, channel_id) do
      nil -> {:noreply, socket}
      kind -> {:noreply, update_typing(socket, kind, type, user_id)}
    end
  end

  # A typist who stops pinging without a stop (a bot, a crashed browser) leaves the list when the
  # timer of their last ping fires. A timer of an earlier ping finds a newer token and does nothing.
  def handle_info({:typing_expired, kind, user_id, token}, socket) do
    if socket.assigns.typing_tokens[{kind, user_id}] == token do
      {:noreply, drop_typist(socket, kind, user_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({event, message}, socket) when event in [:message_updated, :message_deleted] do
    {:noreply,
     socket
     |> State.stream_update_message(message)
     |> Pins.refresh(message)}
  end

  def handle_event("load_older_messages", %{"pane" => pane}, socket) do
    case Map.fetch(@panes, pane) do
      {:ok, kind} -> {:noreply, State.load_older_messages(socket, kind)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("load_newer_messages", %{"pane" => pane}, socket) do
    case Map.fetch(@panes, pane) do
      {:ok, kind} -> {:noreply, State.load_newer_messages(socket, kind)}
      :error -> {:noreply, socket}
    end
  end

  # A pinned message or the message a reply answers.
  def handle_event("open_message", %{"id" => message_id}, socket),
    do: {:noreply, socket |> Pins.close() |> MessageJump.open(message_id)}

  def handle_event("jump_to_present", %{"pane" => pane}, socket) do
    case Map.fetch(@panes, pane) do
      {:ok, kind} -> {:noreply, MessageJump.present(socket, kind)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("toggle_message_controls", %{"id" => message_id}, socket) do
    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         true <- RowHelpers.can_open_message_controls?(socket.assigns, message) do
      previous_controls_id = socket.assigns.active_message_controls_id
      previous_menu_id = socket.assigns.message_action_menu_id
      previous_delete_id = socket.assigns.delete_confirmation_message_id
      previous_picker_id = socket.assigns.reaction_picker_message_id

      next_message_id =
        if previous_controls_id == message_id and is_nil(previous_menu_id) and
             is_nil(previous_delete_id),
           do: nil,
           else: message_id

      {:noreply,
       socket
       |> assign(:mobile_sidebar_open?, false)
       |> assign(:mobile_members_open?, false)
       |> assign(:reaction_picker_message_id, nil)
       |> assign(:message_action_menu_id, nil)
       |> assign(:delete_confirmation_message_id, nil)
       |> assign(:active_message_controls_id, next_message_id)
       |> State.rerender_messages([
         previous_controls_id,
         previous_menu_id,
         previous_delete_id,
         previous_picker_id,
         next_message_id
       ])}
    else
      _closed -> {:noreply, socket}
    end
  end

  def handle_event("toggle_message_action_menu", %{"id" => message_id}, socket) do
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id
    previous_picker_id = socket.assigns.reaction_picker_message_id
    next_menu_id = if previous_menu_id == message_id, do: nil, else: message_id

    {:noreply,
     socket
     |> assign(:reaction_picker_message_id, nil)
     |> assign(
       :active_message_controls_id,
       if(next_menu_id, do: message_id, else: previous_controls_id)
     )
     |> assign(:message_action_menu_id, next_menu_id)
     |> assign(:delete_confirmation_message_id, nil)
     |> State.rerender_messages([
       previous_controls_id,
       previous_menu_id,
       previous_delete_id,
       previous_picker_id,
       message_id,
       next_menu_id
     ])}
  end

  def handle_event("close_message_action_menu", _params, socket) do
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    {:noreply,
     socket
     |> assign(:message_action_menu_id, nil)
     |> assign(:delete_confirmation_message_id, nil)
     |> State.rerender_messages([previous_controls_id, previous_menu_id, previous_delete_id])}
  end

  def handle_event("confirm_delete_message", %{"id" => message_id}, socket) do
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    {:noreply,
     socket
     |> assign(:active_message_controls_id, message_id)
     |> assign(:message_action_menu_id, message_id)
     |> assign(:delete_confirmation_message_id, message_id)
     |> State.rerender_messages([
       previous_controls_id,
       previous_menu_id,
       previous_delete_id,
       message_id
     ])}
  end

  def handle_event("cancel_delete_message", _params, socket) do
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    {:noreply,
     socket
     |> assign(:delete_confirmation_message_id, nil)
     |> State.rerender_messages([previous_delete_id, socket.assigns.message_action_menu_id])}
  end

  def handle_event(event, %{"message" => message_params}, socket)
      when is_map_key(@send_events, event),
      do: {:noreply, send_message(socket, @send_events[event], message_params)}

  def handle_event(event, _params, socket) when is_map_key(@typing_ping_events, event) do
    case State.conversation(socket, @typing_ping_events[event]) do
      %{id: id} -> _ = Chat.announce_typing(socket.assigns.current_scope, id)
      nil -> :ok
    end

    {:noreply, socket}
  end

  def handle_event(event, _params, socket) when is_map_key(@typing_stop_events, event) do
    kind = @typing_stop_events[event]

    case State.conversation(socket, kind) do
      %{id: id} ->
        _ = Chat.clear_typing(socket.assigns.current_scope, id)
        {:noreply, State.refresh_typing_users(socket, kind)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("reply_message", %{"id" => message_id}, socket) do
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    case State.fetch_open_message(socket, message_id) do
      {:ok, message} ->
        # The reply goes through the one composer on screen. A channel message's reply needs the
        # channel composer, which an open thread hides, so the thread closes first.
        socket =
          if RowHelpers.message_rights(socket.assigns, message).thread? or
               is_nil(socket.assigns.active_thread),
             do: socket,
             else: State.leave_thread(socket)

        {:noreply,
         socket
         |> assign(:reply_to_message, message)
         |> State.close_message_ui()
         |> State.rerender_messages([
           message_id,
           previous_controls_id,
           previous_menu_id,
           previous_delete_id
         ])}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, socket |> State.clear_reply_to_message() |> State.rerender_active_thread_panel()}
  end

  def handle_event("edit_message", %{"id" => message_id}, socket) do
    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         true <- message.author_id == socket.assigns.current_user.id do
      form = message |> Chat.change_message(%{body: message.body}) |> to_form(as: :message)
      previous_controls_id = socket.assigns.active_message_controls_id
      previous_menu_id = socket.assigns.message_action_menu_id
      previous_delete_id = socket.assigns.delete_confirmation_message_id

      {:noreply,
       socket
       |> State.close_message_ui()
       |> assign(:editing_message_id, message.id)
       |> assign(:editing_form, form)
       |> State.rerender_messages([
         message.id,
         previous_controls_id,
         previous_menu_id,
         previous_delete_id
       ])}
    else
      :error -> {:noreply, socket}
      false -> {:noreply, put_flash(socket, :error, "You can only edit your own messages.")}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_message_id, nil)
     |> assign(:editing_form, nil)
     |> State.rerender_messages([socket.assigns.editing_message_id])}
  end

  def handle_event("save_edit", %{"message" => %{"id" => message_id, "body" => body}}, socket) do
    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         {:ok, updated_message} <-
           Chat.update_message(socket.assigns.current_scope, message.id, %{body: body}) do
      {:noreply,
       socket
       |> assign(:editing_message_id, nil)
       |> assign(:editing_form, nil)
       |> State.stream_update_message(updated_message)}
    else
      :error ->
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, socket}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to edit that message.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :editing_form, to_form(changeset, as: :message))}
    end
  end

  def handle_event("delete_message", %{"id" => message_id}, socket) do
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         {:ok, deleted_message} <- Chat.delete_message(socket.assigns.current_scope, message.id) do
      socket =
        socket
        |> State.close_message_ui()
        |> assign(:editing_message_id, nil)
        |> assign(:editing_form, nil)
        |> State.rerender_messages([
          message_id,
          previous_controls_id,
          previous_menu_id,
          previous_delete_id
        ])
        |> State.stream_update_message(deleted_message)

      # Deleting a starter retitles its thread. The deleter's own view hears no broadcast, so it
      # runs the handler of `{:channel_updated, _}` itself, as every other session does.
      starter_id = deleted_message.id

      case socket.assigns.thread_summaries do
        %{^starter_id => %{thread: thread}} ->
          Navigation.handle_info({:channel_updated, thread}, socket)

        _ ->
          {:noreply, socket}
      end
    else
      :error ->
        {:noreply, socket}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to delete that message.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete that message.")}
    end
  end

  def handle_event("suppress_embeds", %{"id" => message_id}, socket) do
    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         {:ok, updated_message} <- Chat.suppress_embeds(socket.assigns.current_scope, message.id) do
      {:noreply,
       socket
       |> State.stream_update_message(updated_message)}
    else
      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to remove those embeds.")}

      _missing ->
        {:noreply, socket}
    end
  end

  # A DM the peer opened is listed from its first message on.
  defp list_direct_message(socket, message) do
    if MapSet.member?(socket.assigns.direct_message_ids, message.channel_id) and
         not Enum.any?(socket.assigns.direct_messages, &(&1.id == message.channel_id)),
       do: State.refresh_direct_messages(socket),
       else: socket
  end

  defp update_unread_state(socket, message) do
    socket
    |> maybe_increment_unread_count(message)
    |> maybe_increment_unread_mentions(message)
  end

  defp maybe_increment_unread_count(socket, message) do
    if increment_unread_count?(socket, message) do
      assign(
        socket,
        :unread_counts,
        Map.update(socket.assigns.unread_counts || %{}, message.channel_id, 1, &(&1 + 1))
      )
    else
      socket
    end
  end

  defp maybe_increment_unread_mentions(socket, message) do
    if increment_unread_mentions?(socket, message) do
      assign(
        socket,
        :unread_mentions,
        Map.update(socket.assigns.unread_mentions || %{}, message.channel_id, 1, &(&1 + 1))
      )
    else
      socket
    end
  end

  defp increment_unread_count?(socket, message) do
    current_user = socket.assigns.current_user
    active_channel = socket.assigns.active_channel

    message.author_id != current_user.id and
      (is_nil(active_channel) or active_channel.id != message.channel_id)
  end

  defp increment_unread_mentions?(socket, message) do
    current_user = socket.assigns.current_user
    active_channel = socket.assigns.active_channel

    message.author_id != current_user.id and
      (is_nil(active_channel) or active_channel.id != message.channel_id) and
      Chat.message_mentions_user?(message, current_user, socket.assigns.notification_setting)
  end

  # The sender hears none of its own broadcasts, so this view applies what they tell the others:
  # the new message, and the follow a reply in a thread adds.
  defp send_message(socket, kind, message_params) do
    noun = Pane.noun(kind)

    case State.conversation(socket, kind) do
      nil ->
        refuse_send(socket, kind, "Open a #{noun} before sending a message.")

      conversation ->
        if Pane.can_send?(State.pane(socket, kind)) do
          sent =
            with {:ok, uploads} <- Attachments.pending(socket) do
              Chat.create_message(
                socket.assigns.current_scope,
                conversation.id,
                State.maybe_put_reply(socket, message_params),
                uploads
              )
            end

          case sent do
            {:ok, message} ->
              socket
              |> Attachments.clear()
              |> push_event("composer:clear", %{
                draft_key: Composer.draft_key(socket.assigns.current_user, conversation)
              })
              |> State.clear_reply_to_message()
              |> State.reset_form(kind)
              |> State.refresh_typing_users(kind)
              |> State.insert_message(message)
              |> MessageJump.present(kind)
              |> ThreadNav.refresh_followed_threads()

            {:error, {:slowmode, seconds_left}} ->
              put_flash(socket, :error, Helpers.slowmode_message(seconds_left))

            {:error, {:rate_limited, seconds_left}} ->
              put_flash(socket, :error, Helpers.send_limit_message(seconds_left))

            {:error, :forbidden} ->
              refuse_send(socket, kind, no_send_permission(noun))

            {:error, :not_found} ->
              refuse_send(socket, kind, "That #{noun} is no longer available.")

            # The text and the files stay in the composer.
            {:error, reason}
            when reason in [
                   :attach_files_forbidden,
                   :too_many_attachments,
                   :attachment_too_large,
                   :attachments_uploading,
                   :attachments_rejected
                 ] ->
              put_flash(socket, :error, Attachments.refusal(reason))

            # The composer shows no field errors, so the reason is flashed. The draft stays in
            # the composer.
            {:error, changeset} ->
              put_flash(socket, :error, refusal_text(changeset))
          end
        else
          refuse_send(socket, kind, no_send_permission(noun))
        end
    end
  end

  defp no_send_permission(noun),
    do: "You do not have permission to send messages in this #{noun}."

  defp refuse_send(socket, kind, text),
    do: socket |> put_flash(:error, text) |> State.reset_form(kind)

  # Metadata errors are worded for the bot API, and the browser always sends JSON it built, so
  # the only one it can cause is the size bound, which a person reaches with many mentions.
  # Body errors read after "Message".
  defp refusal_text(changeset) do
    if Keyword.has_key?(changeset.errors, :metadata) do
      "This message has too many mentions to send. Remove some and send it again."
    else
      changeset
      |> Ecto.Changeset.traverse_errors(&TavernWeb.CoreComponents.translate_error/1)
      |> Enum.flat_map(fn {_field, texts} -> texts end)
      |> Enum.map_join(" ", &"Message #{&1}.")
    end
  end

  defp update_typing(socket, kind, :typing_started, user_id) do
    # The typer is decided by `Chat.start_typing`, and this socket subscribes only to channels it
    # may view. A typer who is not an active member has no member row to show.
    if user_id == socket.assigns.current_user.id do
      socket
    else
      case Accounts.get_member(socket.assigns.current_scope, user_id) do
        nil ->
          socket

        user ->
          socket
          |> State.update_pane(
            kind,
            &%{&1 | typing_users: merge_typing_user(&1.typing_users, user)}
          )
          |> expire_typist_later(kind, user_id)
      end
    end
  end

  defp update_typing(socket, kind, :typing_stopped, user_id),
    do: drop_typist(socket, kind, user_id)

  defp drop_typist(socket, kind, user_id) do
    socket
    |> State.update_pane(kind, fn pane ->
      %{pane | typing_users: Enum.reject(pane.typing_users, &(&1.id == user_id))}
    end)
    |> assign(:typing_tokens, Map.delete(socket.assigns.typing_tokens, {kind, user_id}))
  end

  # Typing lasts `Ephemeral.typing_ttl/0` seconds after the last ping. Each ping takes a new token
  # and starts a timer carrying it, so only the last ping's timer removes the typist.
  defp expire_typist_later(socket, kind, user_id) do
    token = socket.assigns.typing_token_seq + 1
    ttl_ms = Tavern.Ephemeral.typing_ttl() * 1000
    Process.send_after(self(), {:typing_expired, kind, user_id, token}, ttl_ms)

    socket
    |> assign(:typing_token_seq, token)
    |> assign(:typing_tokens, Map.put(socket.assigns.typing_tokens, {kind, user_id}, token))
  end

  defp merge_typing_user(users, user) do
    users
    |> Enum.reject(&(&1.id == user.id))
    |> Kernel.++([user])
    |> Enum.sort_by(&{&1.display_name, &1.username})
  end
end
