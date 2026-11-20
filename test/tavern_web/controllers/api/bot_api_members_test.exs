defmodule TavernWeb.API.BotApiMembersTest do
  @moduledoc """
  What a bot learns about people: whom a message mentions (on every serialized message) and which
  roles a member holds (`GET /members/:user_id`).
  """
  use TavernWeb.ConnCase

  import Ecto.Query

  import Tavern.ChatFixtures

  alias Tavern.Bots
  alias Tavern.Chat.PermissionBits

  @speaker [:view_channel, :send_messages]

  setup do
    owner = owner_fixture(%{email: "mem-owner@example.com", username: "mem_owner"})
    speaker = role_fixture(%{permissions: PermissionBits.combine(@speaker)})
    channel = channel_fixture(%{name: "Mentions", slug: unique_slug()})
    bot = bot_fixture(owner, %{"role_ids" => [speaker.id]})

    {:ok, %{token: token}} =
      Bots.create_bot_token(scope_for(owner), bot.id, %{"label" => "mentions"})

    %{owner: owner, channel: channel, token: token}
  end

  describe "mentions on messages" do
    test "a message with no mention has empty lists", ctx do
      message_fixture(ctx.channel, ctx.owner, %{body: "plain"})

      assert %{"user_ids" => [], "role_ids" => [], "everyone" => false} = listed_mentions(ctx)
    end

    test "a mentioned user is listed by id", ctx do
      alice = user_fixture(%{username: "mem_alice", email: "mem-alice@example.com"})
      message_fixture(ctx.channel, ctx.owner, %{body: "hi @mem_alice"})

      assert %{"user_ids" => [id], "role_ids" => [], "everyone" => false} = listed_mentions(ctx)
      assert id == alice.id
    end

    test "a mentioned role is listed by id", ctx do
      role = role_fixture(%{name: "Wranglers", mentionable: true})
      message_fixture(ctx.channel, ctx.owner, %{body: "ping @Wranglers"})

      assert %{"user_ids" => [], "role_ids" => [id], "everyone" => false} = listed_mentions(ctx)
      assert id == role.id
    end

    test "@everyone sets everyone and is not a role id", ctx do
      default_role()
      message_fixture(ctx.channel, ctx.owner, %{body: "hey @everyone"})

      assert %{"user_ids" => [], "role_ids" => [], "everyone" => true} = listed_mentions(ctx)
    end

    test "a message from the write path (an event payload) carries the mentions too", ctx do
      bob = user_fixture(%{username: "mem_bob", email: "mem-bob@example.com"})
      message = message_fixture(ctx.channel, ctx.owner, %{body: "yo @mem_bob"})

      assert %{user_ids: [id], role_ids: [], everyone: false} =
               Bots.serialize_message(message).mentions

      assert id == bob.id
    end
  end

  describe "GET /members/:user_id" do
    test "answers the member's names and role ids, default role included", ctx do
      default = default_role()
      role = role_fixture(%{name: "Regulars"})
      member = user_fixture(%{username: "mem_carol", email: "mem-carol@example.com"})
      member_role_fixture(member, role)

      conn = ctx.token |> api() |> get(~p"/api/v1/members/#{member.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == member.id
      assert data["username"] == "mem_carol"
      assert data["display_name"] == member.display_name
      assert Enum.sort(data["role_ids"]) == Enum.sort([role.id, default.id])
    end

    test "a user who is not a member is not found", ctx do
      stranger = user_fixture(%{username: "mem_dave", email: "mem-dave@example.com"})

      Tavern.Repo.update_all(from(m in Tavern.Chat.Membership, where: m.user_id == ^stranger.id),
        set: [deactivated_at: DateTime.utc_now()]
      )

      conn = ctx.token |> api() |> get(~p"/api/v1/members/#{stranger.id}")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

      conn = ctx.token |> api() |> get(~p"/api/v1/members/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)

      conn = ctx.token |> api() |> get(~p"/api/v1/members/not-a-uuid")
      assert json_response(conn, 404)
    end

    test "needs a bot token", ctx do
      conn = Phoenix.ConnTest.build_conn() |> get(~p"/api/v1/members/#{ctx.owner.id}")
      assert json_response(conn, 401)
    end
  end

  defp listed_mentions(ctx) do
    conn = ctx.token |> api() |> get(~p"/api/v1/channels/#{ctx.channel.id}/messages")
    %{"data" => [message]} = json_response(conn, 200)
    message["mentions"]
  end

  defp api(token) do
    Phoenix.ConnTest.build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
