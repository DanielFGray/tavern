defmodule TavernWeb.ServerLive.Events do
  @moduledoc false

  alias TavernWeb.ServerLive.ChannelEditor
  alias TavernWeb.ServerLive.Events.Forums
  alias TavernWeb.ServerLive.Events.Hydration
  alias TavernWeb.ServerLive.Events.Messages
  alias TavernWeb.ServerLive.Events.Mobile
  alias TavernWeb.ServerLive.Events.Navigation
  alias TavernWeb.ServerLive.Events.Notifications
  alias TavernWeb.ServerLive.Events.Polls
  alias TavernWeb.ServerLive.Events.Reactions
  alias TavernWeb.ServerLive.Events.Threads

  @channel_editor_events ChannelEditor.events()

  def handle_params(params, uri, socket) do
    socket = Phoenix.Component.assign(socket, :url_params, params)
    Navigation.handle_params(params, uri, socket)
  end

  def handle_info({:typing_expired, _key, _user_id, _token} = message, socket),
    do: Messages.handle_info(message, socket)

  def handle_info(message, socket)
      when (is_tuple(message) and tuple_size(message) == 2 and
              elem(message, 0) in [:message_created, :message_updated, :message_deleted]) or
             (is_tuple(message) and tuple_size(message) == 3 and
                elem(message, 0) in [:typing_started, :typing_stopped]) do
    Messages.handle_info(message, socket)
  end

  def handle_info(message, socket)
      when message in [:hydrate_navigation, :hydrate_members, :hydrate_unread_state] do
    Hydration.handle_info(message, socket)
  end

  def handle_info(message, socket)
      when message in [:channels_reordered, :roles_changed] or
             (is_tuple(message) and tuple_size(message) == 2 and
                elem(message, 0) in [:channel_created, :channel_updated, :channel_deleted]) do
    Navigation.handle_info(message, socket)
  end

  def handle_info(message, socket)
      when (is_tuple(message) and tuple_size(message) == 2 and
              elem(message, 0) in [:thread_message_created, :thread_message_deleted]) or
             (is_tuple(message) and tuple_size(message) == 3 and
                elem(message, 0) == :thread_followers_changed) do
    Threads.handle_info(message, socket)
  end

  def handle_info(message, socket)
      when is_tuple(message) and tuple_size(message) == 3 and
             elem(message, 0) in [:poll_voted, :poll_closed] do
    Polls.handle_info(message, socket)
  end

  # Only the bot stream reads these; views re-render from the `:message_updated` sent with them.
  def handle_info({event, _message, _reaction}, socket)
      when event in [:reaction_added, :reaction_removed],
      do: {:noreply, socket}

  def handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @channel_editor_events do
    ChannelEditor.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "toggle_mobile_sidebar",
             "close_mobile_sidebar",
             "toggle_mobile_members",
             "close_mobile_members",
             "toggle_user_menu",
             "close_user_menu"
           ] do
    Mobile.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in ["enable_desktop_mentions", "disable_desktop_mentions"] do
    Notifications.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "toggle_message_controls",
             "toggle_message_action_menu",
             "close_message_action_menu",
             "confirm_delete_message",
             "cancel_delete_message",
             "send_message",
             "typing_ping",
             "typing_stop",
             "reply_message",
             "cancel_reply",
             "edit_message",
             "cancel_edit",
             "save_edit",
             "delete_message",
             "suppress_embeds"
           ] do
    Messages.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "create_thread",
             "open_thread",
             "close_thread",
             "archive_thread",
             "unarchive_thread",
             "lock_thread",
             "unlock_thread",
             "follow_thread",
             "unfollow_thread",
             "open_thread_browser",
             "close_thread_browser",
             "thread_browser_tab",
             "thread_browser_search",
             "thread_browser_more",
             "open_browsed_thread",
             "send_thread_message",
             "typing_ping_thread",
             "typing_stop_thread"
           ] do
    if event in ["typing_ping_thread", "typing_stop_thread"] do
      Messages.handle_event(event, params, socket)
    else
      Threads.handle_event(event, params, socket)
    end
  end

  def handle_event(event, params, socket)
      when event in [
             "forum_search",
             "forum_tag",
             "forum_view",
             "forum_tab",
             "forum_more",
             "new_forum_post",
             "cancel_forum_post",
             "validate_forum_post",
             "create_forum_post"
           ] do
    Forums.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "toggle_reaction",
             "toggle_custom_reaction",
             "toggle_reaction_picker",
             "close_reaction_picker"
           ] do
    Reactions.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "open_poll",
             "cancel_poll",
             "validate_poll",
             "add_poll_option",
             "remove_poll_option",
             "create_poll",
             "vote_poll",
             "vote_poll_other",
             "withdraw_poll_vote",
             "close_poll"
           ] do
    Polls.handle_event(event, params, socket)
  end
end
