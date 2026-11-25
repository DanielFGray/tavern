defmodule TavernWeb.API.BotApiDirectMessagesTest do
  @moduledoc """
  A bot's direct messages (docs/design/direct-messages.md, Bot API): it opens and lists them,
  sends and reads in them through the channel endpoints, is refused by blocks and the opt-out
  like a member, and its event stream announces a new DM and carries the DM's messages.
  """
  use TavernWeb.ConnCase

  import Tavern.ChatFixtures

  alias Tavern.Bots
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias TavernWeb.API.BotController
  alias TavernWeb.TestStreamAdapter

  setup do
    Tavern.Bootstrap.ensure_seed_data!()
    owner = owner_fixture(%{email: "dm-bot-owner@example.com", username: "dm_bot_owner"})
    role = role_fixture(%{permissions: PermissionBits.combine([:view_channel, :send_messages])})
    bot = bot_fixture(owner, %{"role_ids" => [role.id]})
    {:ok, %{token: token}} = Bots.create_bot_token(scope_for(owner), bot.id, %{"label" => "dm"})
    %{owner: owner, bot: bot, token: token, member: user_fixture()}
  end

  test "a bot opens a DM, sends in it, and lists it", ctx do
    conn = ctx.token |> api() |> post(~p"/api/v1/direct_messages", %{user_id: ctx.member.id})

    assert %{"data" => %{"id" => dm_id, "kind" => "direct", "peer" => peer}} =
             json_response(conn, 200)

    assert peer["id"] == ctx.member.id

    again = ctx.token |> api() |> post(~p"/api/v1/direct_messages", %{user_id: ctx.member.id})
    assert %{"data" => %{"id" => ^dm_id}} = json_response(again, 200)

    sent =
      ctx.token
      |> api()
      |> post(~p"/api/v1/channels/#{dm_id}/messages", %{message: %{body: "hello human"}})

    assert %{"data" => %{"channel_id" => ^dm_id}} = json_response(sent, 201)

    listed = ctx.token |> api() |> get(~p"/api/v1/direct_messages")
    assert %{"data" => [%{"id" => ^dm_id}]} = json_response(listed, 200)

    read = ctx.token |> api() |> get(~p"/api/v1/channels/#{dm_id}/messages")
    assert %{"data" => [%{"body" => "hello human"}]} = json_response(read, 200)
  end

  test "a block, the opt-out and an unknown id get the same refusal", ctx do
    blocker = user_fixture()
    :ok = Chat.block_user(scope_for(blocker), ctx.bot.id)
    closed = user_fixture()
    {:ok, _} = Chat.set_direct_messages_from_new_contacts(scope_for(closed), false)

    for user_id <- [blocker.id, closed.id, Ecto.UUID.generate(), "nope"] do
      conn = ctx.token |> api() |> post(~p"/api/v1/direct_messages", %{user_id: user_id})
      assert %{"error" => %{"code" => "not_available"}} = json_response(conn, 404)
    end

    conn = ctx.token |> api() |> post(~p"/api/v1/direct_messages", %{})
    assert json_response(conn, 422)
  end

  test "a bot cannot read a DM it is not in", ctx do
    {:ok, dm} = Chat.open_direct_message(scope_for(ctx.owner), ctx.member.id)
    {:ok, _} = Chat.create_message(scope_for(ctx.owner), dm.id, %{"body" => "private"})

    conn = ctx.token |> api() |> get(~p"/api/v1/channels/#{dm.id}/messages")
    assert json_response(conn, 404)

    assert %{"data" => []} =
             ctx.token |> api() |> get(~p"/api/v1/direct_messages") |> json_response(200)
  end

  test "the stream announces a DM a member opens, then carries its messages", ctx do
    {:ok, scope} = Bots.get_bot_scope_by_token(ctx.token)
    {conn, ref} = Phoenix.ConnTest.build_conn() |> TestStreamAdapter.wrap()
    conn = assign(conn, :current_bot_scope, scope)
    task = Task.async(fn -> catch_exit(BotController.events(conn, %{})) end)

    assert_receive {:plug_conn, :sent}
    assert_receive {^ref, :chunk, _ready}

    {:ok, dm} = Chat.open_direct_message(scope_for(ctx.member), ctx.bot.id)
    assert_receive {^ref, :chunk, opened}
    assert opened =~ "event: direct_message.opened"
    assert opened =~ ~s("channel_id":"#{dm.id}")
    assert opened =~ ~s("user_id":"#{ctx.member.id}")

    {:ok, message} = Chat.create_message(scope_for(ctx.member), dm.id, %{"body" => "hi bot"})
    assert_receive {^ref, :chunk, created}
    Task.shutdown(task, :brutal_kill)

    assert created =~ "event: message.created"
    assert created =~ ~s("id":"#{message.id}")
  end

  defp api(token) do
    Phoenix.ConnTest.build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
