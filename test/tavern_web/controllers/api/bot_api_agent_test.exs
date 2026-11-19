defmodule TavernWeb.API.BotApiAgentTest do
  use TavernWeb.ConnCase

  import Tavern.ChatFixtures

  alias Tavern.Bots
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Topics
  alias TavernWeb.API.BotController
  alias TavernWeb.TestStreamAdapter

  @speaker [:view_channel, :send_messages, :send_messages_in_threads, :create_public_threads]

  setup do
    owner = owner_fixture(%{email: "agent-owner@example.com", username: "agent_owner"})
    role = role_fixture(%{permissions: PermissionBits.combine(@speaker)})
    channel = channel_fixture(%{name: "Agent Channel", slug: unique_slug()})
    bot = bot_fixture(owner, %{"role_ids" => [role.id]})
    {:ok, %{token: token}} = Bots.create_bot_token(bot, %{"label" => "agent"}, owner)

    %{owner: owner, channel: channel, bot: bot, token: token, role: role}
  end

  defp api(token) do
    Phoenix.ConnTest.build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end

  defp ids(conn, status \\ 200),
    do: conn |> json_response(status) |> Map.fetch!("data") |> Enum.map(& &1["id"])

  describe "PATCH /channels/:channel_id/messages/:message_id" do
    test "the author edits its own message", %{channel: channel, bot: bot, token: token} do
      message = message_fixture(channel, bot, %{body: "draft"})

      conn =
        token
        |> api()
        |> patch(~p"/api/v1/channels/#{channel.id}/messages/#{message.id}", %{body: "final"})

      assert %{"data" => %{"id" => id, "body" => "final", "edited_at" => edited_at}} =
               json_response(conn, 200)

      assert id == message.id
      assert edited_at
    end

    test "a message by someone else is forbidden", ctx do
      %{channel: channel, owner: owner, token: token} = ctx
      message = message_fixture(channel, owner, %{body: "mine"})

      conn =
        token
        |> api()
        |> patch(~p"/api/v1/channels/#{channel.id}/messages/#{message.id}", %{body: "stolen"})

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end

    test "a message in another channel is not found", ctx do
      %{channel: channel, bot: bot, token: token} = ctx
      other = channel_fixture(%{name: "Other", slug: unique_slug()})
      message = message_fixture(other, bot, %{body: "elsewhere"})

      conn =
        token
        |> api()
        |> patch(~p"/api/v1/channels/#{channel.id}/messages/#{message.id}", %{body: "x"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "a locked thread refuses the edit", %{channel: channel, bot: bot, owner: owner} = ctx do
      starter = message_fixture(channel, owner, %{body: "starter"})
      thread = thread_fixture(channel, starter, owner)
      message = message_fixture(thread, bot, %{body: "in thread"})
      {:ok, _} = Chat.lock_thread(scope_for(owner), thread.id)

      conn =
        ctx.token
        |> api()
        |> patch(~p"/api/v1/channels/#{thread.id}/messages/#{message.id}", %{body: "late"})

      assert json_response(conn, 403)
    end

    test "edits past the cap answer 429 with Retry-After", ctx do
      %{channel: channel, bot: bot, token: token} = ctx
      message = message_fixture(channel, bot, %{body: "streaming"})
      limit = Application.fetch_env!(:tavern, Tavern.Bots)[:message_edits_per_second]

      edit = fn n ->
        token
        |> api()
        |> patch(~p"/api/v1/channels/#{channel.id}/messages/#{message.id}", %{body: "v#{n}"})
      end

      for n <- 1..limit, do: assert(json_response(edit.(n), 200))

      conn = edit.(limit + 1)

      assert %{"error" => %{"code" => "rate_limited", "retry_after" => 1}} =
               json_response(conn, 429)

      assert get_resp_header(conn, "retry-after") == ["1"]
    end

    test "a refused edit by another author spends none of the author's budget", ctx do
      %{channel: channel, owner: owner} = ctx
      message = message_fixture(channel, owner, %{body: "owners"})
      other = bot_fixture(owner, %{"role_ids" => [ctx.role.id]})
      {:ok, %{token: other_token}} = Bots.create_bot_token(other, %{"label" => "o"}, owner)
      limit = Application.fetch_env!(:tavern, Tavern.Bots)[:message_edits_per_second]

      for _ <- 1..(limit + 2) do
        conn =
          other_token
          |> api()
          |> patch(~p"/api/v1/channels/#{channel.id}/messages/#{message.id}", %{body: "x"})

        assert json_response(conn, 403)
      end
    end

    test "a body is required", %{channel: channel, bot: bot, token: token} do
      message = message_fixture(channel, bot)

      conn =
        token
        |> api()
        |> patch(~p"/api/v1/channels/#{channel.id}/messages/#{message.id}", %{})

      assert %{"error" => %{"code" => "invalid_params"}} = json_response(conn, 422)
    end
  end

  describe "POST /channels/:channel_id/typing" do
    test "shows the bot typing in a channel", %{channel: channel, bot: bot, token: token} do
      watch(channel.id)
      conn = token |> api() |> post(~p"/api/v1/channels/#{channel.id}/typing")

      assert response(conn, 204)
      assert_receive {:seen, {:typing_started, channel_id, user_id}}
      assert {channel_id, user_id} == {channel.id, bot.id}
    end

    test "shows the bot typing in a thread", ctx do
      %{channel: channel, owner: owner, bot: bot, token: token} = ctx
      starter = message_fixture(channel, owner, %{body: "starter"})
      thread = thread_fixture(channel, starter, owner)
      watch(thread.id)

      conn = token |> api() |> post(~p"/api/v1/channels/#{thread.id}/typing")

      assert response(conn, 204)
      assert_receive {:seen, {:typing_started, thread_id, user_id}}
      assert {thread_id, user_id} == {thread.id, bot.id}
    end

    test "a bot that may view but not send is forbidden", %{owner: owner, channel: channel} do
      viewer = role_fixture(%{permissions: PermissionBits.combine([:view_channel])})
      bot = bot_fixture(owner, %{"role_ids" => [viewer.id]})
      {:ok, %{token: token}} = Bots.create_bot_token(bot, %{"label" => "v"}, owner)

      conn = token |> api() |> post(~p"/api/v1/channels/#{channel.id}/typing")

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end

    test "an unknown channel is not found", %{token: token} do
      conn = token |> api() |> post(~p"/api/v1/channels/#{Ecto.UUID.generate()}/typing")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /channels/:channel_id/messages paging" do
    setup %{channel: channel, owner: owner} do
      all = for n <- 1..7, do: message_fixture(channel, owner, %{body: "m#{n}"}).id
      %{all: all}
    end

    test "after reads oldest first across a page boundary", ctx do
      %{channel: channel, token: token, all: all} = ctx
      first = Enum.at(all, 1)

      page = fn cursor ->
        token
        |> api()
        |> get(~p"/api/v1/channels/#{channel.id}/messages", %{after: cursor, limit: 3})
        |> ids()
      end

      page_one = page.(first)
      page_two = page.(List.last(page_one))
      page_three = page.(List.last(page_two))

      assert page_one ++ page_two == Enum.drop(all, 2)
      assert length(page_one) == 3
      assert page_three == []
    end

    test "before reads the page that ends at the cursor, oldest first", ctx do
      %{channel: channel, token: token, all: all} = ctx

      page = fn cursor ->
        token
        |> api()
        |> get(~p"/api/v1/channels/#{channel.id}/messages", %{before: cursor, limit: 3})
        |> ids()
      end

      newest = page.(List.last(all))
      older = page.(hd(newest))
      oldest = page.(hd(older))

      assert newest == Enum.slice(all, 3, 3)
      assert older == Enum.slice(all, 0, 3)
      assert oldest == []
    end

    test "a thread channel pages like a channel", %{channel: channel, owner: owner, token: token} do
      starter = message_fixture(channel, owner, %{body: "starter"})
      thread = thread_fixture(channel, starter, owner)
      posts = for n <- 1..4, do: message_fixture(thread, owner, %{body: "p#{n}"}).id

      conn =
        token
        |> api()
        |> get(~p"/api/v1/channels/#{thread.id}/messages", %{after: hd(posts), limit: 2})

      assert ids(conn) == Enum.slice(posts, 1, 2)
    end

    test "a deleted message is not listed", ctx do
      %{channel: channel, owner: owner, token: token, all: all} = ctx
      {:ok, _} = Chat.delete_message(scope_for(owner), Enum.at(all, 2))

      conn = token |> api() |> get(~p"/api/v1/channels/#{channel.id}/messages")

      assert ids(conn) == List.delete_at(all, 2)
    end

    test "a deleted message still works as a cursor", ctx do
      %{channel: channel, owner: owner, token: token, all: all} = ctx
      {:ok, _} = Chat.delete_message(scope_for(owner), Enum.at(all, 2))

      conn =
        token
        |> api()
        |> get(~p"/api/v1/channels/#{channel.id}/messages", %{after: Enum.at(all, 2)})

      assert ids(conn) == Enum.drop(all, 3)
    end

    test "a cursor from another channel, a malformed one, or both cursors is refused", ctx do
      %{channel: channel, owner: owner, token: token, all: all} = ctx
      other = channel_fixture(%{name: "Other", slug: unique_slug()})
      foreign = message_fixture(other, owner, %{body: "foreign"})
      path = ~p"/api/v1/channels/#{channel.id}/messages"

      for params <- [
            %{after: foreign.id},
            %{before: Ecto.UUID.generate()},
            %{after: "nope"},
            %{after: hd(all), before: List.last(all)}
          ] do
        assert json_response(token |> api() |> get(path, params), 422)
      end
    end

    test "a channel the bot cannot view is not found", %{owner: owner} do
      hidden = channel_fixture(%{name: "Hidden", slug: unique_slug()})
      deny = role_fixture(%{permissions: 0})
      bot = bot_fixture(owner, %{"role_ids" => [deny.id]})
      {:ok, %{token: token}} = Bots.create_bot_token(bot, %{"label" => "n"}, owner)
      conn = token |> api() |> get(~p"/api/v1/channels/#{hidden.id}/messages", %{})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "events" do
    test "thread messages arrive with the thread's parent and the author's bot flag", ctx do
      %{channel: channel, owner: owner, bot: bot} = ctx
      starter = message_fixture(channel, owner, %{body: "a post"})
      thread = thread_fixture(channel, starter, owner)

      {conn, ref} = Phoenix.ConnTest.build_conn() |> TestStreamAdapter.wrap()
      conn = assign(conn, :current_bot_scope, bot_scope(bot, owner))

      task = Task.async(fn -> catch_exit(BotController.events(conn, %{})) end)
      assert_receive {:plug_conn, :sent}
      assert_receive {^ref, :chunk, _ready}

      {:ok, posted} = Chat.create_message(scope_for(owner), thread.id, %{body: "in the post"})
      assert_receive {^ref, :chunk, created_chunk}
      {:ok, _} = Chat.update_message(scope_for(owner), posted.id, %{body: "edited post"})
      assert_receive {^ref, :chunk, updated_chunk}
      Task.shutdown(task, :brutal_kill)

      for {chunk, name} <- [{created_chunk, "created"}, {updated_chunk, "updated"}] do
        assert chunk =~ "event: message.#{name}\n"
        [_, json] = Regex.run(~r/data: (.*)\n\n/, chunk)
        payload = Jason.decode!(json)

        assert payload["id"] == posted.id
        assert payload["channel_id"] == thread.id
        assert payload["channel"]["parent_channel_id"] == channel.id
        assert payload["author"]["bot"] == false
      end
    end

    test "a bot's own message carries bot: true", ctx do
      %{channel: channel, owner: owner, bot: bot} = ctx
      {conn, ref} = Phoenix.ConnTest.build_conn() |> TestStreamAdapter.wrap()
      conn = assign(conn, :current_bot_scope, bot_scope(bot, owner))

      task = Task.async(fn -> catch_exit(BotController.events(conn, %{})) end)
      assert_receive {:plug_conn, :sent}
      assert_receive {^ref, :chunk, _ready}

      message_fixture(channel, bot, %{body: "mine"})
      assert_receive {^ref, :chunk, chunk}
      Task.shutdown(task, :brutal_kill)

      assert chunk =~ ~s("author":{"id":"#{bot.id}")
      assert chunk =~ ~s("bot":true)
    end
  end

  describe "BotController.dispatch/1" do
    test "message events become emits" do
      message = %Tavern.Chat.Message{id: Ecto.UUID.generate(), kind: :user, body: "x"}

      for {event, name} <- [
            message_created: "message.created",
            message_updated: "message.updated",
            message_deleted: "message.deleted"
          ] do
        assert {:emit, ^name, %{id: id}} = BotController.dispatch({event, message})
        assert id == message.id
      end
    end

    test "a public thread is a thread_created action, other channels resync" do
      thread = %Tavern.Chat.Channel{kind: :thread_public}
      assert BotController.dispatch({:channel_created, thread}) == {:thread_created, thread}

      text = %Tavern.Chat.Channel{kind: :text}
      assert BotController.dispatch({:channel_created, text}) == :resync
      assert BotController.dispatch({:channel_updated, text}) == :resync
      assert BotController.dispatch({:channel_deleted, text}) == :resync
      assert BotController.dispatch(:roles_changed) == :resync
    end

    test "reauthorize and unknown messages" do
      assert BotController.dispatch(:reauthorize) == :reauthorize
      assert BotController.dispatch({:typing_started, "c", "u"}) == :ignore
      assert BotController.dispatch(:anything_else) == :ignore
    end
  end

  # The request runs in the test process, and a broadcast skips its sender, so a second process listens.
  defp watch(channel_id) do
    test = self()

    {:ok, _pid} =
      Task.start_link(fn ->
        Topics.sync_channel_subscriptions(MapSet.new(), MapSet.new([channel_id]))
        send(test, :watching)

        receive do
          event -> send(test, {:seen, event})
        end
      end)

    assert_receive :watching
  end

  defp bot_scope(bot, actor) do
    {:ok, %{token: token}} = Bots.create_bot_token(bot, %{"label" => "scope"}, actor)
    {:ok, scope} = Bots.get_bot_scope_by_token(token)
    scope
  end
end
