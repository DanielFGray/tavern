defmodule TavernWeb.ServerLive.Attachments do
  @moduledoc """
  The files waiting in the composer before a send: one LiveView upload, `:attachments`
  (docs/design/attachments.md).

  Files belong to the composer they were added in. The view shows one composer at a time, the
  open thread's or else the open channel's, so when that target changes the waiting files are
  dropped (`follow_composer/2`). A send reads the files while they stay waiting (`pending/1`),
  and only a send that succeeds drops them (`clear/1`), so a refused send keeps them.
  """

  import Phoenix.LiveView,
    only: [allow_upload: 3, cancel_upload: 3, consume_uploaded_entries: 3]

  alias Tavern.Chat.Attachments

  @upload :attachments
  @events ~w(validate_attachments cancel_attachment)

  def events, do: @events

  @doc "Declares the upload on a mounting view."
  def init(socket) do
    allow_upload(socket, @upload,
      accept: :any,
      max_entries: Attachments.max_count(),
      max_file_size: Attachments.max_bytes(),
      auto_upload: true
    )
  end

  # Upload validation runs on the composer form's change event; the limits are in `init/1`, and
  # the composer renders their errors.
  def handle_event("validate_attachments", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_attachment", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, @upload, ref)}

  @doc """
  The finished uploads as `%{path:, client_name:}` for `Tavern.Chat.create_message/4`. They stay
  waiting, and their temporary files stay on disk, until `clear/1`.
  """
  def pending(socket) do
    consume_uploaded_entries(socket, @upload, fn %{path: path}, entry ->
      {:postpone, %{path: path, client_name: entry.client_name}}
    end)
  end

  @doc "Drops the waiting files after a send that used them."
  def clear(socket) do
    _ = consume_uploaded_entries(socket, @upload, fn _meta, _entry -> {:ok, nil} end)
    socket
  end

  @doc """
  Drops the waiting files when the event that turned `before` into the result changed which
  conversation the composer writes to. Wraps a callback's `{:noreply, socket}` or
  `{:reply, map, socket}`.
  """
  def follow_composer({:noreply, socket}, before), do: {:noreply, follow(socket, before)}

  def follow_composer({:reply, reply, socket}, before),
    do: {:reply, reply, follow(socket, before)}

  def follow_composer(other, _before), do: other

  @doc "The text of a refused send that names an attachment rule."
  def refusal(:attach_files_forbidden), do: "You do not have permission to attach files here."

  def refusal(:too_many_attachments),
    do: "A message can carry up to #{Attachments.max_count()} files."

  def refusal(:attachment_too_large),
    do: "Each file can be up to #{div(Attachments.max_bytes(), 1_000_000)} MB."

  def refusal(_reason), do: nil

  @doc "The text of an upload error the composer shows on a waiting file."
  def error_text(:too_large), do: refusal(:attachment_too_large)
  def error_text(:too_many_files), do: refusal(:too_many_attachments)
  def error_text(:not_accepted), do: "That file cannot be attached."
  def error_text(_error), do: "That file could not be uploaded."

  defp follow(socket, before) do
    if composer_target(socket) == composer_target(before), do: socket, else: drop_all(socket)
  end

  defp drop_all(%{assigns: %{uploads: %{@upload => config}}} = socket) do
    Enum.reduce(config.entries, socket, &cancel_upload(&2, @upload, &1.ref))
  end

  defp drop_all(socket), do: socket

  defp composer_target(%{assigns: assigns}) do
    case assigns do
      %{active_thread: %{id: id}} -> {:thread, id}
      %{active_channel: %{id: id}} -> {:channel, id}
      _ -> nil
    end
  end
end
