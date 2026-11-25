defmodule Tavern.Chat do
  @moduledoc """
  Chat domain for the single-server tavern deployment model. The web layer's single entry: most
  functions delegate to the module that owns the concept (`Tavern.Chat.Messages`,
  `Tavern.Chat.Moderation`, `Tavern.Chat.Channels`, ...).
  """

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.AuditLog
  alias Tavern.Chat.Channel
  alias Tavern.Chat.ChannelOverwrites
  alias Tavern.Chat.Channels
  alias Tavern.Chat.Emojis
  alias Tavern.Chat.Forums
  alias Tavern.Chat.Ids
  alias Tavern.Chat.InviteRequests
  alias Tavern.Chat.InviteTree
  alias Tavern.Chat.Invites
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.Mentions
  alias Tavern.Chat.Messages
  alias Tavern.Chat.Moderation
  alias Tavern.Chat.Notifications
  alias Tavern.Chat.Questions
  alias Tavern.Chat.Roles
  alias Tavern.Chat.ServerConfig
  alias Tavern.Chat.ThreadFollows
  alias Tavern.Chat.Threads
  alias Tavern.Chat.Typing
  alias Tavern.Chat.Visibility

  @default_reaction_emojis ["👍", "🔥", "❤️"]

  def default_reaction_emojis, do: @default_reaction_emojis
  defdelegate asset_url(asset), to: MediaAssets
  defdelegate get_server_settings(), to: ServerConfig
  defdelegate reset_server_settings_cache(), to: ServerConfig
  defdelegate change_server_settings(server_settings, attrs \\ %{}), to: ServerConfig
  defdelegate update_server_settings(scope, attrs), to: ServerConfig
  defdelegate remove_server_icon(scope), to: ServerConfig
  defdelegate server_icon_url(settings), to: ServerConfig
  defdelegate default_server_name(), to: ServerConfig

  defdelegate list_channels(scope), to: Channels

  defdelegate list_roles(scope), to: Roles
  defdelegate role_controls(scope), to: Roles
  defdelegate member_roles(scope, user_id), to: Roles
  defdelegate member_with_roles(scope, user_id), to: Roles
  defdelegate change_role(role, attrs \\ %{}), to: Roles
  defdelegate create_role(scope, attrs), to: Roles
  defdelegate update_role(scope, role_id, attrs), to: Roles
  defdelegate delete_role(scope, role_id), to: Roles
  defdelegate move_role(scope, role_id, direction), to: Roles
  defdelegate add_member_role(scope, user_id, role_id), to: Roles
  defdelegate remove_member_role(scope, user_id, role_id), to: Roles
  defdelegate list_overwrites(scope, channel_id), to: ChannelOverwrites
  defdelegate overwrite_controls(scope, channel_id), to: ChannelOverwrites
  defdelegate put_overwrite(scope, channel_id, target, allow, deny), to: ChannelOverwrites
  defdelegate delete_overwrite(scope, channel_id, target), to: ChannelOverwrites

  defdelegate list_channel_tree(scope), to: Channels

  defdelegate composer_mentions(scope), to: Mentions, as: :composer_candidates

  def composer_slash_commands do
    [
      %{id: "shrug", label: "shrug", description: "Insert ¯\\_(ツ)_/¯"},
      %{id: "tableflip", label: "tableflip", description: "Insert (╯°□°）╯︵ ┻━┻"},
      %{id: "code", label: "code", description: "Insert fenced code block"},
      %{id: "giphy", label: "giphy", description: "Insert a GIF-style embed request"}
    ]
  end

  defdelegate list_available_emojis(scope), to: Emojis
  defdelegate change_emoji(emoji, attrs \\ %{}), to: Emojis
  defdelegate create_custom_emoji(scope, upload, attrs), to: Emojis
  defdelegate delete_custom_emoji(scope, emoji_id), to: Emojis

  defdelegate build_channel_tree(channels), to: Channels
  defdelegate ensure_channel_memberships(scope, channels), to: Channels
  defdelegate get_channel(scope, id), to: Channels
  defdelegate get_channel_by_slug(scope, slug), to: Channels
  defdelegate create_channel(scope, attrs), to: Channels
  defdelegate update_channel(scope, channel_id, attrs), to: Channels
  defdelegate place_channel(scope, channel_id, parent_id, before_id), to: Channels
  defdelegate delete_channel(scope, channel_id), to: Channels
  defdelegate list_deleted_channels(scope), to: Channels
  defdelegate restore_channel(scope, channel_id), to: Channels
  defdelegate get_user_notification_setting(scope), to: Notifications
  defdelegate update_user_notification_setting(scope, attrs), to: Notifications
  defdelegate channel_memberships(scope, channel_ids), to: Notifications
  defdelegate update_channel_membership_notification(scope, channel_id, attrs), to: Notifications
  defdelegate unread_counts(scope, channel_ids), to: Notifications
  defdelegate unread_mentions(scope, channel_ids), to: Notifications

  defdelegate create_invite(scope, attrs), to: Invites
  defdelegate list_invites(scope), to: Invites
  defdelegate revoke_invite(scope, invite_id), to: Invites
  defdelegate invite_tree_children(scope, parent), to: InviteTree, as: :children
  defdelegate invite_tree_path_to(scope, user_id), to: InviteTree, as: :path_to
  defdelegate invite_tree_search(scope, query), to: InviteTree, as: :search
  defdelegate change_invite(), to: Invites, as: :new_invite_changeset

  defdelegate accepting_invite_requests?(), to: InviteRequests, as: :accepting_requests?
  defdelegate change_invite_request(attrs \\ %{}), to: InviteRequests
  defdelegate request_invite(attrs, ip_address), to: InviteRequests
  defdelegate list_invite_requests(scope, status), to: InviteRequests
  defdelegate approve_invite_request(scope, request_id), to: InviteRequests
  defdelegate deny_invite_request(scope, request_id), to: InviteRequests
  defdelegate deny_invite_requests_from_ip(scope, ip_address), to: InviteRequests
  defdelegate resend_invite(scope, request_id), to: InviteRequests

  @doc "True when registration requires an invite code."
  def registration_invite_only?, do: get_server_settings().registration_mode == :invite_only

  defdelegate announce_typing(scope, channel_id), to: Typing, as: :announce
  defdelegate clear_typing(scope, channel_id), to: Typing, as: :clear
  defdelegate list_typing_users(scope, channel_id), to: Typing, as: :list_users

  defdelegate list_messages(scope, channel_id, opts \\ []), to: Messages
  defdelegate search_messages(scope, query, opts \\ []), to: Messages
  defdelegate pin_message(scope, message_id), to: Tavern.Chat.Pins
  defdelegate unpin_message(scope, message_id), to: Tavern.Chat.Pins
  defdelegate list_pins(scope, channel_id), to: Tavern.Chat.Pins
  defdelegate get_message(scope, message_id), to: Messages
  defdelegate get_messages(scope, message_ids), to: Messages
  defdelegate message_count(scope, channel_id), to: Messages
  defdelegate change_message(message, attrs \\ %{}), to: Messages
  defdelegate create_message(scope, channel_id, attrs, uploads \\ []), to: Messages
  defdelegate update_message(scope, message_id, attrs), to: Messages
  defdelegate suppress_embeds(scope, message_id), to: Messages
  defdelegate delete_message(scope, message_id), to: Messages
  defdelegate toggle_reaction(scope, message_id, emoji), to: Messages

  defdelegate thread_summaries_for_channel(scope, channel_id), to: Threads
  defdelegate get_thread_for_starter_message(scope, starter_message_id), to: Threads
  defdelegate get_thread(scope, thread_id), to: Threads
  defdelegate thread_reply_count(scope, thread_id), to: Threads, as: :reply_count

  defdelegate create_public_thread(scope, starter_message_id, attrs \\ %{}), to: Threads
  defdelegate archive_thread(scope, thread_id), to: Threads
  defdelegate unarchive_thread(scope, thread_id), to: Threads
  defdelegate rename_thread(scope, thread_id, name), to: Threads
  defdelegate lock_thread(scope, thread_id), to: Threads
  defdelegate unlock_thread(scope, thread_id), to: Threads
  defdelegate delete_thread(scope, thread_id), to: Channels
  defdelegate followed_threads(scope), to: Threads
  defdelegate browse_threads(scope, channel_id, opts \\ []), to: Threads
  defdelegate change_forum_post(attrs \\ %{}), to: Forums, as: :change_post
  defdelegate create_forum_post(scope, forum_id, attrs), to: Forums, as: :create_post
  defdelegate list_forum_posts(scope, forum_id, opts \\ []), to: Forums, as: :list_posts
  defdelegate forum_post_view(scope, forum_id), to: Forums, as: :post_view
  defdelegate set_forum_post_view(scope, forum_id, attrs), to: Forums, as: :set_post_view
  defdelegate follow_thread(scope, thread_id), to: ThreadFollows, as: :follow
  defdelegate unfollow_thread(scope, thread_id), to: ThreadFollows, as: :unfollow
  defdelegate following_thread?(scope, thread_id), to: ThreadFollows, as: :following?
  defdelegate change_question(attrs \\ %{}), to: Questions
  defdelegate create_question(scope, channel_id, attrs), to: Questions
  defdelegate answer_question(scope, message_id, choice), to: Questions, as: :answer
  defdelegate close_question(scope, message_id), to: Questions
  defdelegate question_results(question, viewer_id), to: Questions, as: :results

  defdelegate change_moderation_action(attrs \\ %{}), to: Moderation
  defdelegate list_moderation_cases(scope, subject_user_id), to: Moderation

  defdelegate timeout_member(scope, subject_user_id, duration_minutes, reason \\ nil),
    to: Moderation

  defdelegate kick_member(scope, subject_user_id, reason \\ nil), to: Moderation

  defdelegate kick_member_and_schedule_deletion(scope, subject_user_id, reason \\ nil),
    to: Moderation

  defdelegate list_scheduled_deletions(scope), to: Moderation
  defdelegate cancel_account_deletion(scope, subject_user_id), to: Moderation
  defdelegate ban_member(scope, subject_user_id, reason \\ nil), to: Moderation
  defdelegate list_bans(scope), to: Moderation
  defdelegate unban_member(scope, subject_user_id, reason \\ nil), to: Moderation
  defdelegate rejoin_with_invite(scope, code), to: Moderation

  defdelegate list_audit_entries(scope, filters \\ %{}, cursor \\ nil),
    to: AuditLog,
    as: :list_entries

  defdelegate list_audit_actors(scope), to: AuditLog, as: :list_actors

  defdelegate message_mentions_user?(message, user, setting), to: Notifications
  defdelegate mark_channel_read(scope, channel_id, message \\ nil), to: Notifications

  @doc """
  What the scope may do in channel or thread `channel_id`, decided from one permission load: a
  map from action (`:send_messages`, `:add_reactions`, `:archive_thread`, ...) to boolean. See
  `Tavern.Chat.Visibility.abilities/2`. A channel the scope cannot view, or an id that names no
  channel, answers `no_channel_abilities/0`.
  """
  def channel_abilities(%Scope{} = scope, channel_id) do
    case Ids.cast(channel_id) do
      {:ok, channel_id} -> Visibility.abilities(scope, channel_id)
      {:error, _reason} -> no_channel_abilities()
    end
  end

  defdelegate no_channel_abilities, to: Visibility, as: :no_abilities

  defdelegate thread_channel?(channel), to: Channel, as: :thread?
end
