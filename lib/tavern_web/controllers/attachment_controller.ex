defmodule TavernWeb.AttachmentController do
  @moduledoc """
  Serves a message attachment to a signed-in member who may view its message
  (`Tavern.Chat.Attachments.fetch/2`). Anyone else gets 404, so a URL tells an outsider nothing.

  An image is shown inline; any other file is sent as a download under its own name. The type
  sent is the one the server read from the bytes when the file was attached.
  """
  use TavernWeb, :controller

  alias Tavern.Chat.Attachments

  # The bytes under one attachment never change. `private` keeps shared caches from serving a file
  # to someone the app would refuse.
  @cache_control "private, max-age=31536000, immutable"

  # Even a file a browser renders as a document anyway runs no script and loads nothing.
  @content_security_policy "default-src 'none'; sandbox"

  def show(conn, %{"id" => id}) do
    case Attachments.fetch(conn.assigns.current_scope, id) do
      {:ok, attachment, body} ->
        conn
        |> put_resp_content_type(attachment.asset.content_type, nil)
        |> put_resp_header("content-disposition", disposition(attachment))
        |> put_resp_header("cache-control", @cache_control)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", @content_security_policy)
        |> send_resp(200, body)

      {:error, :not_found} ->
        send_resp(conn, 404, "not found")

      {:error, _reason} ->
        send_resp(conn, 502, "attachment unavailable")
    end
  end

  defp disposition(attachment) do
    type = if attachment.kind == :image, do: "inline", else: "attachment"
    name = Attachments.filename(attachment.asset)
    ascii = String.replace(name, ~r/[^\x20-\x7e]|["\\]/u, "_")

    ~s(#{type}; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
  end
end
