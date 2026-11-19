defmodule TavernWeb.Live.SharedHelpers do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias Tavern.Chat.Visibility

  # Each button's visibility is one decision, made when the view renders. Nothing is stored
  # on the socket, so a role change applies at the next render.
  def can_manage_channels?(nil), do: false
  def can_manage_channels?(scope), do: Visibility.can?(scope, :manage_channels, :server)

  def can_manage_emojis?(nil), do: false

  def can_manage_emojis?(scope),
    do: Visibility.can?(scope, :manage_emojis_and_stickers, :server)

  def can_manage_server?(nil), do: false
  def can_manage_server?(scope), do: Visibility.can?(scope, :manage_server, :server)

  def can_view_audit_log?(nil), do: false
  def can_view_audit_log?(scope), do: Visibility.can?(scope, :view_audit_log, :server)

  def can_moderate_members?(nil), do: false

  def can_moderate_members?(scope) do
    Enum.any?(
      [:moderate_members, :kick_members, :ban_members],
      &Visibility.can?(scope, &1, :server)
    )
  end

  def save_emoji(socket, emoji_params, refresh_fun) when is_function(refresh_fun, 1) do
    upload = uploaded_entry(socket, :emoji_image)

    if is_nil(upload) do
      {:noreply, put_flash(socket, :error, "Choose an image before saving the emoji.")}
    else
      case consume_emoji_upload(socket, emoji_params) do
        {:ok, _emoji, socket} ->
          {:noreply,
           socket
           |> refresh_fun.()
           |> assign(:emoji_form, to_form(Chat.change_emoji(%Chat.Emoji{}, %{}), as: :emoji))
           |> put_flash(:info, "Emoji added.")}

        {:error, :invalid_upload_type, socket} ->
          {:noreply, put_flash(socket, :error, "Emoji uploads must be png, jpg, gif, or webp.")}

        {:error, changeset, socket} ->
          {:noreply, assign(socket, :emoji_form, to_form(changeset, as: :emoji))}
      end
    end
  end

  def consume_emoji_upload(socket, emoji_params) do
    result =
      Phoenix.LiveView.consume_uploaded_entries(socket, :emoji_image, fn %{path: path}, entry ->
        {:ok,
         Chat.create_custom_emoji_from_upload(emoji_params, socket.assigns.current_user, %{
           path: path,
           client_name: entry.client_name,
           client_type: entry.client_type
         })}
      end)

    case result do
      [{:ok, emoji}] -> {:ok, emoji, socket}
      [{:error, reason}] -> {:error, reason, socket}
      [] -> {:error, :invalid_upload_type, socket}
    end
  end

  def uploaded_entry(socket, name) do
    socket.assigns.uploads[name].entries |> List.first()
  end

  def run_member_moderation(scope, subject_id, %{
        "action" => "timeout",
        "duration_minutes" => minutes,
        "reason" => reason
      }) do
    case Integer.parse(to_string(minutes || "")) do
      {duration_minutes, ""} when duration_minutes > 0 ->
        case Chat.timeout_member(scope, subject_id, duration_minutes, blank_to_nil(reason)) do
          {:ok, updated_subject, moderation_case} ->
            {:ok, updated_subject, moderation_case, "Member timed out."}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :invalid_duration}
    end
  end

  def run_member_moderation(scope, subject_id, %{"action" => "kick", "reason" => reason}) do
    case Chat.kick_member(scope, subject_id, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        {:ok, updated_subject, moderation_case, "Member kicked."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_member_moderation(scope, subject_id, %{
        "action" => "kick_schedule_deletion",
        "reason" => reason
      }) do
    case Chat.kick_member_and_schedule_deletion(scope, subject_id, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        date = Calendar.strftime(updated_subject.membership.deletion_scheduled_at, "%b %-d, %Y")

        {:ok, updated_subject, moderation_case,
         "Member kicked. Their account will be deleted on #{date} unless they rejoin."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_member_moderation(scope, subject_id, %{"action" => "ban", "reason" => reason}) do
    case Chat.ban_member(scope, subject_id, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        {:ok, updated_subject, moderation_case, "Member banned."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_member_moderation(scope, subject_id, %{"action" => "unban", "reason" => reason}) do
    case Chat.unban_member(scope, subject_id, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        {:ok, updated_subject, moderation_case, "Member unbanned."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_member_moderation(_scope, _subject_id, _params), do: {:error, :invalid_action}

  def emoji_entries_for_picker(current_user) do
    Chat.list_available_emojis(current_user)
    |> Enum.map(fn emoji ->
      %{
        id: emoji.id,
        name: emoji.name,
        shortcode: emoji.shortcode,
        url: Chat.asset_url(emoji.asset)
      }
    end)
  end

  def server_branding do
    settings = Chat.get_server_settings()

    %{
      name: settings.name,
      icon_url: Chat.server_icon_url(settings)
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
