defmodule TavernWeb.SettingsLive do
  use TavernWeb, :live_view

  alias Tavern.Accounts
  alias Tavern.Accounts.LoginRateLimiter
  alias Tavern.Bots
  alias Tavern.Chat
  alias TavernWeb.Live.SharedHelpers
  alias TavernWeb.Plugs.ClientIp
  alias Tavern.Chat.Topics
  alias TavernWeb.SettingsLive.Audit
  alias TavernWeb.SettingsLive.InviteRequests
  alias TavernWeb.SettingsLive.InviteTree
  alias TavernWeb.SettingsLive.Roles
  alias TavernWeb.SettingsLive.State

  @tabs [
    "profile",
    "notifications",
    "channel_notifications",
    "theme",
    "server",
    "emoji",
    "members",
    "invites",
    "bots",
    "roles",
    "audit"
  ]
  @role_events Roles.events()
  @audit_events Audit.events()
  @invite_request_events InviteRequests.events()
  @invite_tree_events InviteTree.events()

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:client_ip, ClientIp.socket_client_ip(socket))
      |> allow_upload(:server_icon,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 1_000_000
      )
      |> allow_upload(:emoji_image,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 512_000
      )
      |> State.init()
      |> Roles.init()
      |> Audit.init()
      |> InviteRequests.init()
      |> InviteTree.init()

    if connected?(socket), do: Topics.subscribe_server()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket) do
    if tab_allowed?(socket, tab) do
      socket = assign(socket, :active_tab, tab)
      {:noreply, load_tab(socket, tab)}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    if tab_allowed?(socket, tab),
      do: {:noreply, push_patch(socket, to: ~p"/settings?tab=#{tab}")},
      else: {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in @role_events do
    Roles.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @audit_events do
    if tab_allowed?(socket, "audit"),
      do: Audit.handle_event(event, params, socket),
      else: {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in @invite_tree_events do
    InviteTree.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @invite_request_events do
    InviteRequests.handle_event(event, params, socket)
  end

  @impl true
  def handle_event("save_profile", %{"user" => user_params}, socket) do
    case Accounts.update_profile_user(socket.assigns.current_user, user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:profile_form, to_form(Accounts.change_profile_user(user), as: :user))
         |> put_flash(:info, "Profile updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: :user))}
    end
  end

  @impl true
  def handle_event("save_email", %{"email_change" => email_params}, socket) do
    user = socket.assigns.current_user
    ip_address = socket.assigns.client_ip

    case LoginRateLimiter.check_attempt(ip_address, user.email) do
      {:error, retry_after_seconds} ->
        {:noreply,
         socket
         |> put_flash(:error, "Too many attempts. Try again in #{retry_after_seconds} seconds.")}

      :ok ->
        case Accounts.update_user_email(user, Map.get(email_params, "password"), email_params) do
          {:ok, :confirmation_sent} ->
            :ok = LoginRateLimiter.clear_attempts(ip_address, user.email)

            {:noreply,
             socket
             |> assign(:email_form, to_form(Accounts.change_user_email(user), as: :email_change))
             |> put_flash(
               :info,
               "We sent a link to #{email_params["email"]}. Your email changes when you open it."
             )}

          {:ok, updated_user} ->
            :ok = LoginRateLimiter.clear_attempts(ip_address, user.email)

            {:noreply,
             socket
             |> assign(:current_user, updated_user)
             |> assign(
               :email_form,
               to_form(Accounts.change_user_email(updated_user), as: :email_change)
             )
             |> put_flash(:info, "Email updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :email_form, to_form(changeset, as: :email_change))}
        end
    end
  end

  @impl true
  def handle_event("save_notifications", %{"notification" => attrs}, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_scope, attrs) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:notification_setting, setting)
         |> State.assign_notification_form()
         |> put_flash(:info, "Notification preferences updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :notification_form, to_form(changeset, as: :notification))}
    end
  end

  @impl true
  def handle_event("enable_desktop_mentions", _params, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_scope, %{
           desktop_enabled: true,
           notify_on_mentions: true
         }) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:notification_setting, setting)
         |> State.assign_notification_form()
         |> push_event("notifications:request-permission", %{})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not enable mention alerts.")}
    end
  end

  @impl true
  def handle_event("disable_desktop_mentions", _params, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_scope, %{
           desktop_enabled: false
         }) do
      {:ok, setting} ->
        {:noreply,
         socket |> assign(:notification_setting, setting) |> State.assign_notification_form()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not disable mention alerts.")}
    end
  end

  @impl true
  def handle_event("save_channel_notification", %{"channel_notification" => attrs}, socket) do
    channel_id = Map.get(attrs, "channel_id")

    membership_attrs = %{
      notification_level: State.blank_to_nil(Map.get(attrs, "notification_level")) || :default,
      is_favorite: State.truthy?(Map.get(attrs, "is_favorite"))
    }

    scope = socket.assigns.current_scope

    case Chat.update_channel_membership_notification(scope, channel_id, membership_attrs) do
      {:ok, _membership} ->
        channels = Chat.list_channels(scope)

        {:noreply,
         socket
         |> assign(:channels, channels)
         |> assign(:channel_memberships, State.channel_memberships(scope, channels))
         |> put_flash(:info, "Channel preference saved.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update that channel preference.")}
    end
  end

  @impl true
  def handle_event("remove_server_icon", _params, socket) do
    case Chat.remove_server_icon(socket.assigns.current_scope) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:server_settings, settings)
         |> assign(:current_server, settings)
         |> assign(:page_title, settings.name)
         |> assign(:server_settings_form, State.server_settings_form(settings))
         |> put_flash(:info, "Server icon removed.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You cannot change server branding.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove the server icon.")}
    end
  end

  # A live file upload reaches the server only from a form that binds phx-change: the client
  # registers the chosen file with that event. The handler keeps what was typed.
  @impl true
  def handle_event("change_server_settings", %{"server_settings" => attrs}, socket) do
    form =
      socket.assigns.server_settings
      |> Chat.change_server_settings(attrs)
      |> to_form(as: :server_settings)

    {:noreply, assign(socket, :server_settings_form, form)}
  end

  @impl true
  def handle_event("save_server_settings", %{"server_settings" => attrs}, socket) do
    attrs = State.maybe_attach_server_icon_upload(socket, attrs)

    case Chat.update_server_settings(socket.assigns.current_scope, attrs) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:server_settings, settings)
         |> assign(:current_server, settings)
         |> assign(:page_title, settings.name)
         |> assign(:server_settings_form, State.server_settings_form(settings))
         |> put_flash(:info, "Server settings updated.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You cannot change server branding.")}

      {:error, :invalid_upload_type} ->
        {:noreply, put_flash(socket, :error, "Server icon must be png, jpg, gif, or webp.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :server_settings_form, to_form(changeset, as: :server_settings))}
    end
  end

  @impl true
  def handle_event("create_invite", %{"invite" => attrs}, socket) do
    case Chat.create_invite(socket.assigns.current_scope, State.invite_attrs(socket, attrs)) do
      {:ok, _invite} ->
        {:noreply,
         socket
         |> State.maybe_load_invites()
         |> assign(:invite_form, to_form(Chat.change_invite(), as: :invite))
         |> put_flash(:info, "Invite created.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You cannot manage invites.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :invite_form, to_form(changeset, as: :invite))}
    end
  end

  @impl true
  def handle_event("revoke_invite", %{"id" => invite_id}, socket) do
    case Chat.revoke_invite(socket.assigns.current_scope, invite_id) do
      {:ok, _invite} ->
        {:noreply, socket |> State.maybe_load_invites() |> put_flash(:info, "Invite revoked.")}

      {:error, :not_found} ->
        {:noreply, socket |> State.maybe_load_invites() |> put_flash(:error, "Invite not found.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You cannot manage invites.")}
    end
  end

  @impl true
  def handle_event("create_bot", %{"bot" => bot_params}, socket) do
    role_ids = List.wrap(Map.get(bot_params, "role_ids", []))
    bot_params = Map.put(bot_params, "role_ids", Enum.reject(role_ids, &(&1 == "")))

    case Bots.create_bot(socket.assigns.current_scope, bot_params) do
      {:ok, _bot} ->
        {:noreply,
         socket
         |> State.refresh_bot_assigns()
         |> assign(:bot_form, to_form(State.bot_form_defaults(), as: :bot))
         |> put_flash(:info, "Bot created.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :bot_form, to_form(changeset, as: :bot))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to create that bot.")}
    end
  end

  @impl true
  def handle_event("create_bot_token", %{"id" => bot_id, "token" => token_params}, socket) do
    case Bots.create_bot_token(socket.assigns.current_scope, bot_id, token_params) do
      {:ok, token_info} ->
        {:noreply,
         socket
         |> State.refresh_bot_assigns()
         |> assign(
           :revealed_bot_tokens,
           Map.put(socket.assigns.revealed_bot_tokens, bot_id, token_info.token)
         )
         |> put_flash(:info, "Bot token created. Copy it now; it will not be shown again.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You cannot mint tokens for this bot.")}

      {:error, :not_found} ->
        {:noreply, socket |> State.refresh_bot_assigns() |> put_flash(:error, "Bot not found.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        token_forms =
          Map.put(socket.assigns.bot_token_forms, bot_id, State.bot_token_form(bot_id, changeset))

        {:noreply, assign(socket, :bot_token_forms, token_forms)}
    end
  end

  @impl true
  def handle_event("revoke_bot_token", %{"id" => token_id}, socket) do
    case Bots.revoke_bot_token(socket.assigns.current_scope, token_id) do
      {:ok, _revoked} ->
        {:noreply,
         socket |> State.refresh_bot_assigns() |> put_flash(:info, "Bot token revoked.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You cannot revoke tokens for this bot.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Bot token not found.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not revoke bot token.")}
    end
  end

  @impl true
  def handle_event("change_emoji", %{"emoji" => emoji_params}, socket) do
    form = to_form(Chat.change_emoji(%Chat.Emoji{}, emoji_params), as: :emoji)
    {:noreply, assign(socket, :emoji_form, form)}
  end

  @impl true
  def handle_event("save_emoji", %{"emoji" => emoji_params}, socket) do
    State.save_emoji(socket, emoji_params)
  end

  @impl true
  def handle_event("delete_emoji", %{"id" => emoji_id}, socket) do
    case Chat.delete_custom_emoji(socket.assigns.current_scope, emoji_id) do
      {:ok, _emoji} ->
        {:noreply,
         socket
         |> State.refresh_custom_emojis()
         |> put_flash(:info, "Emoji deleted.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to manage emojis.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete that emoji.")}
    end
  end

  @impl true
  def handle_event("toggle_member_actions", %{"id" => user_id}, socket) do
    if socket.assigns.can_moderate_members? do
      next_user_id = if socket.assigns.member_action_user_id == user_id, do: nil, else: user_id

      moderation_cases =
        if next_user_id, do: moderation_cases(socket.assigns.current_scope, user_id), else: []

      {:noreply,
       socket
       |> assign(:member_action_user_id, next_user_id)
       |> assign(:moderation_cases, moderation_cases)
       |> assign(
         :member_action_form,
         to_form(Chat.change_moderation_action(%{}), as: :moderation)
       )}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to moderate members.")}
    end
  end

  @impl true
  def handle_event("close_member_actions", _params, socket) do
    {:noreply,
     socket
     |> assign(:member_action_user_id, nil)
     |> assign(:moderation_cases, [])
     |> assign(:member_action_form, to_form(Chat.change_moderation_action(%{}), as: :moderation))}
  end

  @impl true
  def handle_event("promote_to_owner", %{"id" => user_id}, socket) do
    scope = socket.assigns.current_scope

    case Accounts.get_member(scope, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Could not promote that user.")}

      subject ->
        case Accounts.promote_to_owner(scope, user_id) do
          {:ok, _membership} ->
            {:noreply,
             socket
             |> State.refresh_member_presence()
             |> put_flash(:info, "#{subject.display_name} is now an owner.")}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "Only owners can promote other users.")}

          {:error, :self} ->
            {:noreply, put_flash(socket, :error, "You cannot promote yourself.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not promote that user.")}
        end
    end
  end

  @impl true
  def handle_event("demote_from_owner", %{"id" => user_id}, socket) do
    scope = socket.assigns.current_scope

    case Accounts.get_member(scope, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Could not demote that user.")}

      subject ->
        case Accounts.demote_from_owner(scope, user_id) do
          {:ok, _membership} ->
            {:noreply,
             socket
             |> State.refresh_member_presence()
             |> put_flash(:info, "#{subject.display_name} is no longer an owner.")}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "Only owners can demote other owners.")}

          {:error, :self} ->
            {:noreply, put_flash(socket, :error, "You cannot demote yourself.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not demote that user.")}
        end
    end
  end

  @impl true
  def handle_event("moderate_member", %{"user_id" => user_id, "moderation" => params}, socket) do
    if socket.assigns.can_moderate_members? do
      scope = socket.assigns.current_scope

      case State.run_member_moderation(scope, user_id, params) do
        {:ok, _subject, _case, message} ->
          {:noreply,
           socket
           |> State.refresh_member_presence()
           |> assign(:moderation_cases, moderation_cases(scope, user_id))
           |> assign(
             :member_action_form,
             to_form(Chat.change_moderation_action(%{}), as: :moderation)
           )
           |> put_flash(:info, message)}

        {:error, :forbidden} ->
          {:noreply,
           put_flash(socket, :error, "You do not have permission to moderate that member.")}

        {:error, :invalid_duration} ->
          changeset =
            Chat.change_moderation_action(params)
            |> Ecto.Changeset.add_error(:duration_minutes, "must be greater than zero")

          {:noreply, assign(socket, :member_action_form, to_form(changeset, as: :moderation))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not complete that moderation action.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to moderate members.")}
    end
  end

  @impl true
  def handle_event("unban_member", %{"user_id" => user_id} = params, socket) do
    reason = Map.get(params, "reason", "")

    case State.run_member_moderation(socket.assigns.current_scope, user_id, %{
           "action" => "unban",
           "reason" => reason
         }) do
      {:ok, _subject, _case, message} ->
        {:noreply, socket |> State.refresh_member_presence() |> put_flash(:info, message)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to unban that member.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> State.refresh_member_presence()
         |> put_flash(:error, "That member is not banned.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not unban that member.")}
    end
  end

  @impl true
  def handle_event("cancel_account_deletion", %{"user_id" => user_id}, socket) do
    case Chat.cancel_account_deletion(socket.assigns.current_scope, user_id) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> State.refresh_member_presence()
         |> put_flash(:info, "Deletion canceled. The member stays kicked.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to cancel deletions.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> State.refresh_member_presence()
         |> put_flash(:error, "That account has no scheduled deletion.")}
    end
  end

  # Server events: a role change can change what this member may manage and which channels they
  # see; a channel change re-reads the channel lists. Other server events change nothing here.
  @impl true
  def handle_info(:roles_changed, socket) do
    socket =
      socket
      |> Roles.refresh()
      |> State.assign_management_flags()
      |> State.refresh_bot_assigns()

    socket =
      if tab_allowed?(socket, socket.assigns.active_tab),
        do: socket,
        else: push_patch(socket, to: ~p"/settings?tab=profile")

    {:noreply,
     socket
     |> State.refresh_channels()
     |> State.refresh_member_presence()}
  end

  def handle_info({event, _channel}, socket)
      when event in [:channel_created, :channel_updated, :channel_deleted],
      do: {:noreply, State.refresh_channels(socket)}

  def handle_info(:channels_reordered, socket), do: {:noreply, State.refresh_channels(socket)}

  def handle_info(_event, socket), do: {:noreply, socket}

  # A server tab shows only to a member who holds a permission it needs. The Invites tab shows to
  # everyone: its tree is scoped by `Chat`, and its link and request panels check their own flags.
  defp tab_allowed?(socket, "server"), do: socket.assigns.can_manage_server?
  defp tab_allowed?(socket, "emoji"), do: socket.assigns.can_manage_emojis?
  defp tab_allowed?(socket, "bots"), do: socket.assigns.can_manage_bots?

  defp tab_allowed?(socket, "members"),
    do: socket.assigns.can_moderate_members? or socket.assigns.role_controls.manage_roles?

  defp tab_allowed?(socket, "roles"), do: socket.assigns.role_controls.manage_roles?

  defp tab_allowed?(socket, "audit"),
    do: SharedHelpers.can_view_audit_log?(socket.assigns.current_scope)

  defp tab_allowed?(_socket, tab), do: tab in @tabs

  defp load_tab(socket, "audit"), do: Audit.load(socket)
  defp load_tab(socket, "invites"), do: InviteTree.load(socket)
  defp load_tab(socket, _tab), do: socket

  # A scope without `view_audit_log` reads no cases, and so does a malformed id.
  defp moderation_cases(scope, user_id) do
    case Chat.list_moderation_cases(scope, user_id) do
      {:ok, moderation_cases} -> moderation_cases
      {:error, _reason} -> []
    end
  end
end
