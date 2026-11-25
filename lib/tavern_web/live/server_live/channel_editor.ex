defmodule TavernWeb.ServerLive.ChannelEditor do
  @moduledoc """
  The sidebar's channel edit mode (docs/design/channel-management.md). A member with
  `manage_channels` turns it on with the pencil in the channel list's header. Each change saves at
  once through `Tavern.Chat`, which decides it; the broadcast it sends updates every open sidebar,
  this one included. Leaving the mode saves nothing.

  The ⚙ popover edits one channel's name, topic and age gate, and holds its permission overrides
  (`TavernWeb.ServerLive.ChannelPermissions`).
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias TavernWeb.Live.SharedHelpers
  alias TavernWeb.ServerLive.ChannelPermissions
  alias TavernWeb.ServerLive.Events.Navigation
  alias TavernWeb.ServerLive.State

  @events ~w(
    toggle_channel_edit
    rename_channel
    save_topic
    open_add_channel
    cancel_add_channel
    create_channel
    open_add_category
    cancel_add_category
    create_category
    place_channel
    delete_channel
    restore_channel
    open_channel_settings
    close_channel_settings
    save_channel_settings
  )

  # The kinds "+ add channel" offers. Voice and stage are not built.
  @new_channel_kinds [
    {"Text", "text"},
    {"Announcement", "announcement"},
    {"Forum", "forum"},
    {"Voice", "voice"}
  ]

  def events, do: @events ++ ChannelPermissions.events()
  def new_channel_kinds, do: @new_channel_kinds

  def init(socket) do
    socket
    |> assign(:can_manage_channels?, false)
    |> assign(:channel_edit_mode?, false)
    |> assign(:deleted_channels, [])
    |> assign(:new_channel_parent, nil)
    |> assign(:new_channel_form, new_channel_form())
    |> assign(:new_category_form, nil)
    |> assign(:channel_settings_id, nil)
    |> assign(:channel_settings_form, nil)
    |> ChannelPermissions.init()
  end

  @doc """
  Re-reads what the editor shows after the channel list changed: the right to manage channels,
  the deleted channels, and the popover's channel. A member who lost the right leaves edit mode,
  and a popover whose channel is gone closes.
  """
  def refresh(socket) do
    can_manage? = SharedHelpers.can_manage_channels?(socket.assigns.current_scope)
    socket = assign(socket, :can_manage_channels?, can_manage?)

    if can_manage? do
      socket
      |> assign(:deleted_channels, deleted_channels(socket))
      |> refresh_settings()
    else
      leave(socket)
    end
  end

  def handle_event(event, params, socket)
      when event in ["toggle_overwrite", "add_overwrite", "save_overwrite", "delete_overwrite"],
      do: ChannelPermissions.handle_event(event, params, socket)

  def handle_event("toggle_channel_edit", _params, socket) do
    cond do
      socket.assigns.channel_edit_mode? ->
        {:noreply, leave(socket)}

      socket.assigns.can_manage_channels? ->
        {:noreply,
         socket
         |> assign(:channel_edit_mode?, true)
         |> assign(:deleted_channels, Chat.list_deleted_channels(socket.assigns.current_scope))}

      true ->
        {:noreply, refusal(socket, :forbidden)}
    end
  end

  # Enter, blur and Esc all end an inline edit; only a changed value is saved.
  def handle_event("rename_channel", %{"id" => id, "value" => name}, socket) do
    update_if_changed(socket, id, :name, name)
  end

  def handle_event("save_topic", %{"id" => id, "value" => topic}, socket) do
    update_if_changed(socket, id, :topic, topic)
  end

  def handle_event("open_add_channel", %{"parent" => parent}, socket) do
    {:noreply,
     socket
     |> assign(:new_channel_parent, parent)
     |> assign(:new_channel_form, new_channel_form())}
  end

  def handle_event("cancel_add_channel", _params, socket) do
    {:noreply, assign(socket, :new_channel_parent, nil)}
  end

  def handle_event("create_channel", %{"new_channel" => params}, socket) do
    kind = Map.get(params, "kind")

    if kind in Enum.map(@new_channel_kinds, &elem(&1, 1)) do
      attrs = %{
        "name" => Map.get(params, "name", ""),
        "kind" => kind,
        "parent_channel_id" => socket.assigns.new_channel_parent
      }

      case Chat.create_channel(socket.assigns.current_scope, attrs) do
        {:ok, _channel} ->
          {:noreply, socket |> assign(:new_channel_parent, nil) |> State.refresh_channels()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_channel_form, to_form(changeset, as: :new_channel))}

        {:error, reason} ->
          {:noreply, refusal(socket, reason)}
      end
    else
      {:noreply, refusal(socket, :invalid_kind)}
    end
  end

  def handle_event("open_add_category", _params, socket) do
    {:noreply, assign(socket, :new_category_form, to_form(%{"name" => ""}, as: :new_category))}
  end

  def handle_event("cancel_add_category", _params, socket) do
    {:noreply, assign(socket, :new_category_form, nil)}
  end

  def handle_event("create_category", %{"new_category" => params}, socket) do
    attrs = %{"name" => Map.get(params, "name", ""), "kind" => "category"}

    case Chat.create_channel(socket.assigns.current_scope, attrs) do
      {:ok, _category} ->
        {:noreply, socket |> assign(:new_category_form, nil) |> State.refresh_channels()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :new_category_form, to_form(changeset, as: :new_category))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  # Sent by the drag hook: the channel lands in `parent_id` ("" is the top level) before
  # `before_id` ("" is last).
  def handle_event("place_channel", %{"id" => id} = params, socket) do
    case Chat.place_channel(
           socket.assigns.current_scope,
           id,
           Map.get(params, "parent_id"),
           Map.get(params, "before_id")
         ) do
      {:ok, _channel} -> {:noreply, State.refresh_channels(socket)}
      {:error, reason} -> {:noreply, socket |> State.refresh_channels() |> refusal(reason)}
    end
  end

  # The broadcast skips this process, so it runs the handler other sessions run: a member viewing
  # the deleted channel moves to the default one.
  def handle_event("delete_channel", %{"id" => id}, socket) do
    case Chat.delete_channel(socket.assigns.current_scope, id) do
      {:ok, channel} -> Navigation.handle_info({:channel_deleted, channel}, socket)
      {:error, reason} -> {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("restore_channel", %{"id" => id}, socket) do
    case Chat.restore_channel(socket.assigns.current_scope, id) do
      {:ok, _channel} -> {:noreply, State.refresh_channels(socket)}
      {:error, reason} -> {:noreply, socket |> State.refresh_channels() |> refusal(reason)}
    end
  end

  def handle_event("open_channel_settings", %{"id" => id}, socket) do
    if socket.assigns.channel_edit_mode? do
      {:noreply,
       socket
       |> assign(:channel_settings_id, id)
       |> assign(:open_overwrite_key, nil)
       |> refresh_settings()
       |> then(fn socket ->
         if socket.assigns.channel_settings_id, do: socket, else: refusal(socket, :not_found)
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_channel_settings", _params, socket) do
    {:noreply, close_settings(socket)}
  end

  def handle_event("save_channel_settings", %{"channel_settings" => params}, socket) do
    attrs = Map.take(params, ["name", "topic", "nsfw", "slowmode_seconds", "voice_member_limit"])

    case Chat.update_channel(
           socket.assigns.current_scope,
           socket.assigns.channel_settings_id,
           attrs
         ) do
      {:ok, _channel} ->
        {:noreply, socket |> State.refresh_channels() |> put_flash(:info, "Channel saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :channel_settings_form, to_form(changeset, as: :channel_settings))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  # --- Helpers -----------------------------------------------------------------------------------

  # Replies `saved: false` on a refusal, so the field puts back the stored value.
  defp update_if_changed(socket, id, field, value) do
    case Chat.get_channel(socket.assigns.current_scope, id) do
      nil ->
        {:reply, %{saved: false}, refusal(socket, :not_found)}

      channel ->
        if String.trim(value) == (Map.fetch!(channel, field) || "") do
          {:reply, %{saved: true}, socket}
        else
          case Chat.update_channel(socket.assigns.current_scope, channel.id, %{field => value}) do
            {:ok, _channel} -> {:reply, %{saved: true}, State.refresh_channels(socket)}
            {:error, reason} -> {:reply, %{saved: false}, refusal(socket, reason)}
          end
        end
    end
  end

  defp leave(socket) do
    socket
    |> assign(:channel_edit_mode?, false)
    |> assign(:new_channel_parent, nil)
    |> assign(:new_category_form, nil)
    |> close_settings()
  end

  defp close_settings(socket) do
    socket
    |> assign(:channel_settings_id, nil)
    |> assign(:channel_settings_form, nil)
    |> ChannelPermissions.refresh()
  end

  # The popover's form follows the stored channel, so an edit saved elsewhere shows here too.
  defp refresh_settings(%{assigns: %{channel_settings_id: nil}} = socket), do: socket

  defp refresh_settings(socket) do
    case Chat.get_channel(socket.assigns.current_scope, socket.assigns.channel_settings_id) do
      nil ->
        close_settings(socket)

      channel ->
        socket
        |> assign(:channel_settings_id, channel.id)
        |> assign(
          :channel_settings_form,
          to_form(Ecto.Changeset.change(channel), as: :channel_settings)
        )
        |> ChannelPermissions.refresh()
    end
  end

  defp deleted_channels(socket) do
    if socket.assigns.channel_edit_mode?,
      do: Chat.list_deleted_channels(socket.assigns.current_scope),
      else: []
  end

  defp new_channel_form, do: to_form(%{"name" => "", "kind" => "text"}, as: :new_channel)

  defp refusal(socket, :not_found),
    do: put_flash(socket, :error, "That channel no longer exists.")

  defp refusal(socket, :forbidden),
    do: put_flash(socket, :error, "You do not have permission to manage channels.")

  defp refusal(socket, _reason), do: put_flash(socket, :error, "That change could not be saved.")
end
