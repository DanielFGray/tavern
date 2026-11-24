defmodule TavernWeb.ServerLive do
  use TavernWeb, :live_view

  import Phoenix.LiveView, only: [connected?: 1, stream: 4]

  alias Tavern.Chat
  alias Tavern.Chat.Topics
  alias Tavern.Chat.UserNotificationSetting
  alias TavernWeb.ServerLive.Attachments
  alias TavernWeb.ServerLive.ChannelEditor
  alias TavernWeb.ServerLive.Events
  alias TavernWeb.ServerLive.Pane
  alias TavernWeb.ServerLive.State
  alias TavernWeb.ServerLive.Voice
  alias TavernWeb.Live.SharedHelpers

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    if connected?(socket) do
      Topics.subscribe_server()
    end

    server_settings = Chat.get_server_settings()

    socket =
      socket
      |> assign(:server_settings, server_settings)
      |> assign(:server_name, server_settings.name)
      |> assign(:current_server, server_settings)
      |> assign(:page_title, server_settings.name)
      |> assign(:current_user, current_user)
      |> assign(:channels, [])
      |> assign(:subscribed_channel_ids, MapSet.new())
      |> assign(:channel_sections, [])
      |> assign(:custom_emojis, [])
      |> assign(:custom_emojis_json, emoji_entries_json_for_picker([]))
      |> assign(:member_presence, [])
      |> assign(:notification_setting, %UserNotificationSetting{user_id: current_user.id})
      |> assign(:composer_mentions_json, "[]")
      |> assign(:composer_commands_json, "[]")
      |> assign(:unread_counts, %{})
      |> assign(:unread_mentions, %{})
      # Until the client reports, the view counts as seen (first render, LiveView tests).
      |> assign(:tab_visible?, true)
      |> assign(:navigation_ready?, false)
      |> assign(:members_ready?, false)
      |> assign(:mobile_sidebar_open?, false)
      |> assign(:mobile_members_open?, false)
      |> assign(:members_collapsed?, false)
      |> assign(:user_menu_open?, false)
      |> assign(:profile_card, nil)
      |> assign(:reaction_picker_message_id, nil)
      |> assign(:active_message_controls_id, nil)
      |> assign(:message_action_menu_id, nil)
      |> assign(:delete_confirmation_message_id, nil)
      |> assign(:active_channel, nil)
      |> assign(:channel_pane, Pane.new(:channel))
      |> assign(:thread_pane, Pane.new(:thread))
      |> assign(:forum, nil)
      |> assign(:reply_to_message, nil)
      |> assign(:poll_form, nil)
      |> assign(:editing_message_id, nil)
      |> assign(:editing_form, nil)
      |> assign(:thread_summaries, %{})
      |> assign(:typing_tokens, %{})
      |> assign(:typing_token_seq, 0)
      |> assign(:active_thread, nil)
      |> assign(:thread_following?, false)
      |> assign(:followed_threads, [])
      |> assign(:thread_browser, nil)
      |> assign(:message_search, nil)
      |> Voice.init()
      |> ChannelEditor.init()
      |> Attachments.init()
      |> stream(:messages, [], reset: true)
      |> stream(:thread_messages, [], reset: true)

    {:ok, State.queue_initial_hydration(socket)}
  end

  @impl true
  def handle_params(params, uri, socket),
    do: params |> Events.handle_params(uri, socket) |> Attachments.follow_composer(socket)

  @impl true
  def handle_info(message, socket),
    do: message |> Events.handle_info(socket) |> Attachments.follow_composer(socket)

  @impl true
  def handle_event(event, params, socket),
    do: event |> Events.handle_event(params, socket) |> Attachments.follow_composer(socket)

  @impl true
  def terminate(reason, socket) do
    Voice.terminate(reason, socket)
  end

  defp emoji_entries_json_for_picker(entries) do
    Jason.encode!(%{
      custom: entries,
      branding: SharedHelpers.server_branding()
    })
  end
end
