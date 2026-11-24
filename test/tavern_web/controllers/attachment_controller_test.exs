defmodule TavernWeb.AttachmentControllerTest do
  use TavernWeb.ConnCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.Attachments
  alias Tavern.Chat.PermissionBits
  alias Tavern.UploadFixtures

  setup do
    Tavern.Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    channel = channel_fixture(%{name: "Lobby"})
    member = user_fixture()

    image = UploadFixtures.png_upload("cat.png")
    file = UploadFixtures.upload("report é.pdf", "application/pdf", "%PDF-1.7 not really")

    {:ok, message} =
      Chat.create_message(scope_for(member), channel.id, %{"body" => "files"}, [image, file])

    [image_attachment, file_attachment] = Enum.sort_by(message.attachments, & &1.position)

    %{
      owner: owner,
      member: member,
      channel: channel,
      image: {image_attachment, image.body},
      download: {file_attachment, file.body}
    }
  end

  test "shows an image inline to a member who may view it", ctx do
    {attachment, body} = ctx.image
    conn = ctx.owner |> signed_in() |> get(Attachments.url(attachment))

    assert response(conn, 200) == body
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert ["inline; " <> _] = get_resp_header(conn, "content-disposition")
    assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "sends any other file as a download under its name", ctx do
    {attachment, body} = ctx.download
    conn = ctx.owner |> signed_in() |> get(Attachments.url(attachment))

    assert response(conn, 200) == body
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="report _.pdf"; filename*=UTF-8''report%20%C3%A9.pdf)
           ]
  end

  test "answers 404 to a member who may not view the channel", ctx do
    outsider = user_fixture()

    {:ok, _} =
      Chat.put_overwrite(
        scope_for(ctx.owner),
        ctx.channel.id,
        {:user, outsider.id},
        0,
        PermissionBits.combine([:view_channel])
      )

    {attachment, _body} = ctx.image
    assert outsider |> signed_in() |> get(Attachments.url(attachment)) |> response(404)
  end

  test "sends a visitor who is not signed in to the login page", ctx do
    {attachment, _body} = ctx.image
    conn = get(build_conn(), Attachments.url(attachment))
    assert redirected_to(conn) =~ "/login"
  end

  defp signed_in(user) do
    build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Tavern.Accounts.generate_user_session_token(user))
  end
end
