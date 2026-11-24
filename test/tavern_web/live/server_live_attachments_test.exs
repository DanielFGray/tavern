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
