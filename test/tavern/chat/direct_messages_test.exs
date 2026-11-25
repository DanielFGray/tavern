defmodule Tavern.Chat.DirectMessagesTest do
  @moduledoc """
  A direct message is visible to its two participants only, whatever bits anyone holds
  (docs/design/direct-messages.md). The leak tests read a DM as the owner, an administrator and a
  third member through every list and read the chat offers.
  """
  use Tavern.DataCase, async: true

  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat.Alerts
  alias Tavern.Chat
  alias Tavern.Chat.Channel
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility

  setup do
    Bootstrap.ensure_seed_data!()
    ada = user_fixture()
    bo = user_fixture()
    {:ok, dm} = Chat.open_direct_message(scope_for(ada), bo.id)
    %{ada: ada, bo: bo, dm: dm}
  end

  describe "open_direct_message/2" do
    test "returns the one DM of the pair, from either side, with the peer set", ctx do
      assert %Channel{kind: :direct, name: nil} = ctx.dm
      assert ctx.dm.peer.id == ctx.bo.id

      assert {:ok, again} = Chat.open_direct_message(scope_for(ctx.bo), ctx.ada.id)
      assert again.id == ctx.dm.id
      assert again.peer.id == ctx.ada.id
    end

    test "announces a new DM on both participants' user topics only", ctx do
      cy = user_fixture()
      Topics.subscribe_user(cy.id)
      Phoenix.PubSub.subscribe(Tavern.PubSub, "chat:server")

      {:ok, dm} = Chat.open_direct_message(scope_for(ctx.ada), cy.id)

      assert_receive {:direct_message_opened, %Channel{id: id}}
      assert id == dm.id
      refute_received {:channel_created, _}
    end

    test "refuses itself, unknown ids, a blocked pair and a member who turned off new contacts",
         ctx do
      cy = user_fixture()
      dee = user_fixture()
      :ok = Chat.block_user(scope_for(cy), ctx.ada.id)
      {:ok, _} = Chat.set_direct_messages_from_new_contacts(scope_for(dee), false)

      for target <- [ctx.ada.id, Ecto.UUID.generate(), "nope", cy.id, dee.id] do
        assert {:error, :not_available} = Chat.open_direct_message(scope_for(ctx.ada), target)
      end
    end

    test "a member who turned off new contacts still gets their existing DMs", ctx do
      {:ok, _} = Chat.set_direct_messages_from_new_contacts(scope_for(ctx.bo), false)
      assert {:ok, %Channel{id: id}} = Chat.open_direct_message(scope_for(ctx.ada), ctx.bo.id)
      assert id == ctx.dm.id
    end

    test "an Unverified member cannot start a DM" do
      newcomer = unverified_user_fixture()

      assert {:error, :not_available} =
               Chat.open_direct_message(scope_for(newcomer), user_fixture().id)
    end
  end

  describe "who may act in a DM" do
    test "the participants send and read; nobody else views it", ctx do
      assert {:ok, message} =
               Chat.create_message(scope_for(ctx.ada), ctx.dm.id, %{"body" => "hi bo"})

      assert {:ok, _} = Chat.create_message(scope_for(ctx.bo), ctx.dm.id, %{"body" => "hi ada"})
      assert [_] = Chat.get_messages(scope_for(ctx.bo), [message.id])

      for outsider <- outsiders() do
        scope = scope_for(outsider)
        refute Visibility.can?(scope, :view_channel, ctx.dm)
        assert Chat.get_channel(scope, ctx.dm.id) == nil
        assert Chat.get_messages(scope, [message.id]) == []
        assert {:error, _} = Chat.create_message(scope, ctx.dm.id, %{"body" => "let me in"})
      end
    end

    test "no list, tree or search shows a DM to anyone but its participants", ctx do
      {:ok, _} = Chat.create_message(scope_for(ctx.ada), ctx.dm.id, %{"body" => "secret okapi"})

      for outsider <- outsiders() do
        scope = scope_for(outsider)
        refute ctx.dm.id in Enum.map(Chat.list_channels(scope), & &1.id)
        assert Chat.list_direct_messages(scope) == []
        assert {:ok, %{messages: []}} = Chat.search_messages(scope, "okapi")
      end

      refute ctx.dm.id in Enum.map(Chat.list_channels(scope_for(ctx.ada)), & &1.id)
      assert [%Channel{id: id}] = Chat.list_direct_messages(scope_for(ctx.bo))
      assert id == ctx.dm.id
      assert {:ok, %{messages: [hit]}} = Chat.search_messages(scope_for(ctx.bo), "okapi")
      assert hit.channel.id == ctx.dm.id
    end

    test "a DM refuses @everyone, and a mention alerts nobody outside it", ctx do
      outsider = user_fixture()
      scope = scope_for(ctx.ada)

      assert {:error, %Ecto.Changeset{}} =
               Chat.create_message(scope, ctx.dm.id, %{"body" => "@everyone look"})

      {:ok, message} =
        Chat.create_message(scope, ctx.dm.id, %{"body" => "ask @#{outsider.username}"})

      recipients = Enum.map(Alerts.recipients(message), & &1.user_id)
      refute outsider.id in recipients
      refute ctx.ada.id in recipients
    end

    test "a participant with manage_messages cannot delete the peer's message or pin", ctx do
      admin = admin_fixture()
      {:ok, dm} = Chat.open_direct_message(scope_for(admin), ctx.bo.id)
      {:ok, message} = Chat.create_message(scope_for(ctx.bo), dm.id, %{"body" => "mine"})

      refute Visibility.can?(scope_for(admin), :delete_message, message)
      refute Visibility.can?(scope_for(admin), :pin_message, message)
      refute Visibility.can?(scope_for(admin), :create_public_threads, message)
      assert Visibility.can?(scope_for(ctx.bo), :delete_message, message)
    end

    test "a block stops sends both ways but keeps the history readable", ctx do
      {:ok, message} = Chat.create_message(scope_for(ctx.ada), ctx.dm.id, %{"body" => "before"})
      :ok = Chat.block_user(scope_for(ctx.bo), ctx.ada.id)

      for user <- [ctx.ada, ctx.bo] do
        refute Visibility.can?(scope_for(user), :send_messages, ctx.dm)
        assert [_] = Chat.get_messages(scope_for(user), [message.id])
      end

      :ok = Chat.unblock_user(scope_for(ctx.bo), ctx.ada.id)
      assert Visibility.can?(scope_for(ctx.ada), :send_messages, ctx.dm)
    end

    test "a timed-out participant cannot send", ctx do
      moderator = owner_fixture()
      {:ok, _subject, _case} = Chat.timeout_member(scope_for(moderator), ctx.ada.id, 10)
      refute Visibility.can?(scope_for(ctx.ada), :send_messages, ctx.dm)
      assert Visibility.can?(scope_for(ctx.ada), :view_channel, ctx.dm)
    end

    test "nobody can send to a peer who left the server", ctx do
      moderator = owner_fixture()
      {:ok, _subject, _case} = Chat.kick_member(scope_for(moderator), ctx.bo.id)
      refute Visibility.can?(scope_for(ctx.ada), :send_messages, ctx.dm)
    end
  end

  describe "alerts" do
    test "every DM message alerts the peer as a direct mention, unless the peer mutes the DM",
         ctx do
      {:ok, message} = Chat.create_message(scope_for(ctx.ada), ctx.dm.id, %{"body" => "psst"})
      assert [%{user_id: user_id, mentioned?: true}] = Alerts.recipients(message)
      assert user_id == ctx.bo.id

      {:ok, _} =
        Chat.update_channel_membership_notification(scope_for(ctx.bo), ctx.dm.id, %{
          notification_level: :nothing
        })

      {:ok, muted} = Chat.create_message(scope_for(ctx.ada), ctx.dm.id, %{"body" => "again"})
      assert Alerts.recipients(muted) == []
    end

    test "the alert names the sender and links the message in the DM", ctx do
      Topics.subscribe_user(ctx.bo.id)
      {:ok, message} = Chat.create_message(scope_for(ctx.ada), ctx.dm.id, %{"body" => "psst"})

      assert_receive {:alert, alert}
      assert alert.title == "#{ctx.ada.display_name} sent you a message"
      assert alert.path == "/?" <> URI.encode_query(dm: ctx.dm.id, message: message.id)
    end
  end

  describe "list_direct_messages/1" do
    test "lists an empty DM for its starter only, then for both once it holds a message", ctx do
      assert [_] = Chat.list_direct_messages(scope_for(ctx.ada))
      assert Chat.list_direct_messages(scope_for(ctx.bo)) == []

      {:ok, _} = Chat.create_message(scope_for(ctx.ada), ctx.dm.id, %{"body" => "knock"})
      assert [%Channel{peer: peer}] = Chat.list_direct_messages(scope_for(ctx.bo))
      assert peer.id == ctx.ada.id
    end
  end

  describe "blocks" do
    test "lists the accounts the scope blocks", ctx do
      :ok = Chat.block_user(scope_for(ctx.ada), ctx.bo.id)
      :ok = Chat.block_user(scope_for(ctx.ada), ctx.bo.id)
      assert [blocked] = Chat.list_blocked_users(scope_for(ctx.ada))
      assert blocked.id == ctx.bo.id
      assert Chat.list_blocked_users(scope_for(ctx.bo)) == []
      assert {:error, :not_found} = Chat.block_user(scope_for(ctx.ada), ctx.ada.id)
    end
  end

  # The owner, an administrator and a member with every channel bit: none is a participant.
  defp outsiders do
    [owner_fixture(), admin_fixture(), user_fixture()]
  end

  defp admin_fixture do
    role = role_fixture(%{permissions: PermissionBits.combine([:administrator])})
    user = user_fixture()
    member_role_fixture(user, role)
    user
  end
end
