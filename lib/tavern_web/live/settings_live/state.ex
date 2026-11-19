defmodule TavernWeb.SettingsLive.State do
  @moduledoc false

  import Ecto.Query, warn: false
  import Phoenix.Component, only: [assign: 3, to_form: 2]

  alias Tavern.Accounts
  alias Tavern.Bots
  alias Tavern.Chat
  alias Tavern.Chat.ChannelMembership
  alias Tavern.Chat.ServerSettings
  alias Tavern.Chat.UserNotificationSetting
  alias Tavern.Repo
  alias TavernWeb.Live.SharedHelpers

  def init(socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels(socket.assigns.current_scope)
    :ok = Chat.ensure_channel_memberships(socket.assigns.current_scope, channels)

    can_manage_emojis? = SharedHelpers.can_manage_emojis?(socket.assigns.current_scope)
    can_moderate_members? = SharedHelpers.can_moderate_members?(socket.assigns.current_scope)
    can_view_audit_log? = SharedHelpers.can_view_audit_log?(socket.assigns.current_scope)
    can_manage_bots? = Bots.can_manage_bots?(socket.assigns.current_scope)
    server_settings = Chat.get_server_settings()

    socket
    |> assign(:current_user, current_user)
    |> assign(:server_settings, server_settings)
    |> assign(:current_server, server_settings)
    |> assign(:page_title, server_settings.name)
    |> assign(:active_tab, "profile")
    |> assign(:can_manage_emojis?, can_manage_emojis?)
    |> assign(:can_moderate_members?, can_moderate_members?)
    |> assign(:can_view_audit_log?, can_view_audit_log?)
    |> assign(
      :can_manage_server?,
      SharedHelpers.can_manage_server?(socket.assigns.current_scope)
    )
    |> assign(:can_manage_bots?, can_manage_bots?)
    |> assign(:notification_setting, Chat.get_user_notification_setting(current_user))
    |> assign(:channels, channels)
    |> assign(:channel_memberships, channel_memberships_map(current_user, channels))
    |> assign(:channel_sections, Chat.list_channel_tree(socket.assigns.current_scope))
    |> assign(:custom_emojis, SharedHelpers.emoji_entries_for_picker(current_user))
    |> assign(:bot_users, [])
    |> assign(:manageable_roles, [])
    |> assign(:bot_form, to_form(bot_form_defaults(), as: :bot))
    |> assign(:bot_token_forms, %{})
    |> refresh_bot_assigns()
    |> assign(:revealed_bot_tokens, %{})
    |> assign(:invites, [])
    |> assign(:invite_form, to_form(Chat.change_invite(), as: :invite))
    |> maybe_load_invites()
    |> assign(:manage_emojis_open?, false)
    |> refresh_member_presence()
    |> assign(:member_action_user_id, nil)
    |> assign(:member_action_form, to_form(Chat.change_moderation_action(%{}), as: :moderation))
    |> assign(:moderation_cases, [])
    |> assign(:profile_form, to_form(Accounts.change_profile_user(current_user), as: :user))
    |> assign(:email_form, to_form(Accounts.change_user_email(current_user), as: :email_change))
    |> assign(:server_settings_form, server_settings_form(server_settings))
    |> assign_notification_form()
    |> assign(:emoji_form, to_form(Chat.change_emoji(%Chat.Emoji{}, %{}), as: :emoji))
  end

  def assign_notification_form(socket) do
    form =
      socket.assigns.notification_setting
      |> UserNotificationSetting.changeset(%{})
      |> to_form(as: :notification)

    assign(socket, :notification_form, form)
  end

  def server_settings_form(%ServerSettings{} = server_settings) do
    server_settings
    |> Chat.change_server_settings(%{
      "name" => server_settings.name || Chat.default_server_name(),
      "registration_mode" => Atom.to_string(server_settings.registration_mode)
    })
    |> to_form(as: :server_settings)
  end

  def maybe_load_invites(socket) do
    case Chat.list_invites(socket.assigns.current_user) do
      {:error, :forbidden} -> assign(socket, :invites, [])
      invites -> assign(socket, :invites, invites)
    end
  end

  def invite_attrs(socket, attrs) do
    attrs = Map.put(attrs, "channel_id", default_invite_channel_id(socket.assigns.channels))

    case Integer.parse(attrs["expires_in_days"] || "") do
      {days, ""} when days > 0 ->
        Map.put(attrs, "expires_at", DateTime.add(DateTime.utc_now(), days * 86_400, :second))

      _ ->
        Map.delete(attrs, "expires_at")
    end
    |> Map.delete("expires_in_days")
  end

  defp default_invite_channel_id(channels) do
    case Enum.find(channels, &(&1.slug == "general")) || List.first(channels) do
      nil -> nil
      channel -> channel.id
    end
  end

  def maybe_attach_server_icon_upload(socket, attrs) do
    case SharedHelpers.uploaded_entry(socket, :server_icon) do
      nil ->
        attrs

      _entry ->
        result =
          Phoenix.LiveView.consume_uploaded_entries(socket, :server_icon, fn %{path: path},
                                                                             entry ->
            {:ok,
             %{
               path: path,
               client_name: entry.client_name,
               client_type: entry.client_type
             }}
          end)

        case result do
          [upload] -> Map.put(attrs, "icon_upload", upload)
          _ -> attrs
        end
    end
  end

  def channel_memberships_map(current_user, channels) do
    channel_ids = Enum.map(channels, & &1.id)

    ChannelMembership
    |> where(
      [membership],
      membership.user_id == ^current_user.id and membership.channel_id in ^channel_ids
    )
    |> Repo.all()
    |> Map.new(&{&1.channel_id, &1})
  end

  def refresh_channels(socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels(socket.assigns.current_scope)

    socket
    |> assign(:channels, channels)
    |> assign(:channel_sections, Chat.list_channel_tree(socket.assigns.current_scope))
    |> assign(:channel_memberships, channel_memberships_map(current_user, channels))
  end

  # Who is in the server, who is banned and whose deletion is scheduled change together, so one
  # refresh reads all three. `:bans` and `:scheduled_deletions` are nil for a scope that may not
  # list them, which hides their panels.
  def refresh_member_presence(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:member_presence, Accounts.list_members(scope))
    |> assign(:bans, permitted_list(Chat.list_bans(scope)))
    |> assign(:scheduled_deletions, permitted_list(Chat.list_scheduled_deletions(scope)))
  end

  defp permitted_list({:ok, entries}), do: entries
  defp permitted_list({:error, :forbidden}), do: nil

  def save_emoji(socket, emoji_params) do
    SharedHelpers.save_emoji(socket, emoji_params, &refresh_custom_emojis/1)
  end

  def refresh_custom_emojis(socket) do
    current_user = socket.assigns.current_user
    assign(socket, :custom_emojis, SharedHelpers.emoji_entries_for_picker(current_user))
  end

  def run_member_moderation(scope, subject_id, params),
    do: SharedHelpers.run_member_moderation(scope, subject_id, params)

  def refresh_bot_assigns(socket) do
    if socket.assigns.can_manage_bots? do
      bot_users = Bots.list_controllable_bot_users(socket.assigns.current_user)

      bot_token_forms =
        Enum.reduce(bot_users, %{}, fn bot_user, acc ->
          Map.put_new(acc, bot_user.id, bot_token_form(bot_user.id))
        end)

      socket
      |> assign(:bot_users, bot_users)
      |> assign(:manageable_roles, Bots.grantable_roles(socket.assigns.current_user))
      |> assign(
        :bot_token_forms,
        Map.merge(bot_token_forms, socket.assigns.bot_token_forms || %{})
      )
    else
      socket
    end
  end

  @doc """
  The token form for one bot card. Each card renders its own form, so the form id carries the
  bot id and its input ids stay unique on the page.
  """
  def bot_token_form(bot_id, source \\ %{"label" => "", "expires_in_days" => ""}) do
    to_form(source, as: :token, id: "bot-token-#{bot_id}")
  end

  def bot_form_defaults do
    %{"display_name" => "", "username" => "", "email" => "", "bio" => "", "role_ids" => []}
  end

  def truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  def truthy?(_value), do: false

  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value
end
