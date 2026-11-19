defmodule TavernWeb.API.BotApiMessageReadTest do
  @moduledoc """
  `GET /api/v1/messages/:message_id`: one message by id, through the bot's scope. A message the bot
  cannot view, a message in a deleted channel, and an unknown or malformed id all answer 404.
  """
  use TavernWeb.ConnCase

  import Tavern.ChatFixtures

  alias Tavern.Bots
  alias Tavern.Chat.PermissionBits

  setup do
    owner = owner_fixture(%{email: "read-owner@example.com", username: "read_owner"})

    role =
      role_fixture(%{
        permissions:
          PermissionBits.combine([
            :view_channel,
            :send_messages,
            :send_messages_in_threads,
            :create_public_threads
          ])
      })

    channel = channel_fixture(%{name: "Reads", slug: unique_slug()})
    bot = bot_fixture(owner, %{"role_ids" => [role.id]})
    {:ok, %{token: token}} = Bots.create_bot_token(scope_for(owner), bot.id, %{"label" => "read"})

    %{owner: owner, channel: channel, bot: bot, token: token}
  end

  test "reads a message in a channel the bot can view, with the serialized shape", ctx do
    message = message_fixture(ctx.channel, ctx.owner, %{body: "hello"})

    conn = ctx.token |> api() |> get(~p"/api/v1/messages/#{message.id}")

    assert %{"data" => data} = json_response(conn, 200)
    assert data["id"] == message.id
    assert data["channel_id"] == ctx.channel.id
    assert data["body"] == "hello"
    assert data["author_id"] == ctx.owner.id
    assert data["mentions"] == %{"user_ids" => [], "role_ids" => [], "everyone" => false}
  end

  test "a message in a channel the bot cannot view is not found", ctx do
    hidden = channel_fixture(%{name: "Hidden", slug: unique_slug()})
    message = message_fixture(hidden, ctx.owner, %{body: "secret"})

    channel_permission_overwrite_fixture(hidden, %{
      user_id: ctx.bot.id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    conn = ctx.token |> api() |> get(~p"/api/v1/messages/#{message.id}")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "a message in a deleted channel is not found", ctx do
    doomed = channel_fixture(%{name: "Doomed", slug: unique_slug()})
    message = message_fixture(doomed, ctx.owner, %{body: "gone"})
    {:ok, _} = Tavern.Chat.delete_channel(scope_for(ctx.owner), doomed.id)

    conn = ctx.token |> api() |> get(~p"/api/v1/messages/#{message.id}")
    assert json_response(conn, 404)
  end

  test "an unknown id and a malformed id are not found", ctx do
    conn = ctx.token |> api() |> get(~p"/api/v1/messages/#{Ecto.UUID.generate()}")
    assert json_response(conn, 404)

    conn = ctx.token |> api() |> get(~p"/api/v1/messages/not-a-uuid")
    assert json_response(conn, 404)
  end

  test "reads the starter message of a public thread by id", ctx do
    starter = message_fixture(ctx.channel, ctx.owner, %{body: "start here"})
    {:ok, bot_scope} = Bots.get_bot_scope_by_token(ctx.token)
    {:ok, _} = Bots.create_public_thread(bot_scope, starter.id, %{"name" => "Talk"})

    conn = ctx.token |> api() |> get(~p"/api/v1/messages/#{starter.id}")

    assert %{"data" => %{"id" => id, "channel_id" => channel_id}} = json_response(conn, 200)
    assert id == starter.id
    assert channel_id == ctx.channel.id
  end

  test "needs a bot token", ctx do
    message = message_fixture(ctx.channel, ctx.owner, %{body: "hi"})

    conn = Phoenix.ConnTest.build_conn() |> get(~p"/api/v1/messages/#{message.id}")
    assert json_response(conn, 401)
  end

  defp api(token) do
    Phoenix.ConnTest.build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
