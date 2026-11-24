defmodule TavernWeb.ServerLiveAttachmentsTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias Tavern.UploadFixtures

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")
    %{conn: conn, view: view}
  end

  test "a picked image waits in the composer and goes with the send", %{view: view} = ctx do
    png = UploadFixtures.unique_png()
    upload = pick(view, [%{name: "cat.png", content: png, type: "image/png"}])

    assert render_upload(upload, "cat.png") =~ "cat.png"
    assert has_element?(view, "#composer-attachments [data-pending-attachment]")

    # No text: the files alone are the message.
    view |> form("#message-form", %{message: %{body: ""}}) |> render_submit()

    [message] = latest_messages(ctx.conn)
    assert [attachment] = message.attachments
    assert has_element?(view, "#attachment-#{attachment.id} img[src^='/attachments/']")
    refute has_element?(view, "#composer-attachments")
    assert UploadFixtures.stored?(png)

    # Previews of a message with no text name what it holds.
    view |> element("#quick-reply-message-#{message.id}") |> render_click()
    assert view |> element("#replying-to-banner") |> render() =~ "Attachment"
  end

  test "a file that is not an image shows as a download card", %{view: view} = ctx do
    upload = pick(view, [%{name: "notes.txt", content: "words", type: "text/plain"}])
    render_upload(upload, "notes.txt")

    view |> form("#message-form", %{message: %{body: "notes attached"}}) |> render_submit()

    [%{attachments: [attachment]}] = latest_messages(ctx.conn)
    assert has_element?(view, "#attachment-#{attachment.id}[download='notes.txt']")
  end

  test "a waiting file can be removed before sending", %{view: view} do
    upload =
      pick(view, [%{name: "cat.png", content: UploadFixtures.unique_png(), type: "image/png"}])

    render_upload(upload, "cat.png")
    [ref] = pending_refs(view)

    view |> element("#cancel-attachment-#{ref}") |> render_click()
    refute has_element?(view, "#composer-attachments")
  end

  test "switching channel drops the waiting files", %{view: view} do
    channel_fixture(%{name: "Elsewhere", slug: "elsewhere"})

    upload =
      pick(view, [%{name: "cat.png", content: UploadFixtures.unique_png(), type: "image/png"}])

    render_upload(upload, "cat.png")

    render_patch(view, ~p"/?channel=elsewhere")
    refute has_element?(view, "#composer-attachments")
  end

  test "without attach_files the composer offers no attach control", %{conn: conn} do
    general = channel_by_slug!("general")

    {:ok, _} =
      Chat.put_overwrite(
        scope_for(owner_fixture()),
        general.id,
        {:role, default_role().id},
        0,
        PermissionBits.combine([:attach_files])
      )

    {:ok, view, _html} = live_hydrated(conn, ~p"/")
    assert has_element?(view, "#composer-attach-button[disabled]")
    refute has_element?(view, "#message-form [data-attach-control]")
  end

  test "a send waits while a file is still uploading, and keeps it", %{view: view} = ctx do
    upload =
      pick(view, [%{name: "cat.png", content: UploadFixtures.unique_png(), type: "image/png"}])

    render_upload(upload, "cat.png", 50)
    view |> form("#message-form", %{message: %{body: "too soon"}}) |> render_submit()

    assert render(view) =~ "Wait for your files to finish uploading."
    assert has_element?(view, "#composer-attachments [data-pending-attachment]")
    refute Enum.any?(latest_messages(ctx.conn), &(&1.body == "too soon"))
  end

  test "a send waits while a refused file is still listed", %{view: view} = ctx do
    big = :binary.copy("x", Tavern.Chat.Attachments.max_bytes() + 1)

    pick(view, [%{name: "huge.bin", content: big, type: "application/octet-stream"}])
    |> render_upload("huge.bin")

    view |> form("#message-form", %{message: %{body: "with the big one"}}) |> render_submit()

    assert render(view) =~ "Remove the files that cannot be attached"
    refute Enum.any?(latest_messages(ctx.conn), &(&1.body == "with the big one"))
  end

  test "a files-only message can start a thread, and the thread composer attaches too",
       %{view: view} = ctx do
    upload =
      pick(view, [%{name: "cat.png", content: UploadFixtures.unique_png(), type: "image/png"}])

    render_upload(upload, "cat.png")
    view |> form("#message-form", %{message: %{body: ""}}) |> render_submit()
    [starter] = latest_messages(ctx.conn)

    view |> element("#create-thread-#{starter.id}") |> render_click()
    _ = :sys.get_state(view.pid)
    view |> element("#open-thread-#{starter.id}") |> render_click()
    assert has_element?(view, "#thread-message-form")

    upload =
      file_input(view, "#thread-message-form", :attachments, [
        %{name: "reply.txt", content: "reply words", type: "text/plain"}
      ])

    render_upload(upload, "reply.txt")
    assert has_element?(view, "#thread-composer-attachments [data-pending-attachment]")

    view |> form("#thread-message-form", %{message: %{body: ""}}) |> render_submit()

    scope = scope_for(current_user_from_conn(ctx.conn))
    thread = Chat.get_thread_for_starter_message(scope, starter.id)

    [reply] =
      thread.id |> messages_in() |> Enum.map(& &1.id) |> then(&Chat.get_messages(scope, &1))

    assert [attachment] = reply.attachments
    assert has_element?(view, "#attachment-#{attachment.id}[download='reply.txt']")
  end

  defp pick(view, files), do: file_input(view, "#message-form", :attachments, files)

  defp pending_refs(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-pending-attachment]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "pending-attachment-", ""))
  end

  defp latest_messages(conn) do
    ids =
      "general"
      |> channel_by_slug!()
      |> Map.fetch!(:id)
      |> messages_in()
      |> List.last()
      |> List.wrap()
      |> Enum.map(& &1.id)

    Chat.get_messages(scope_for(current_user_from_conn(conn)), ids)
  end
end
