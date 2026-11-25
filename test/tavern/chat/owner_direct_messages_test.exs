defmodule Tavern.Chat.OwnerDirectMessagesTest do
  @moduledoc """
  The owner's audited DM reader (docs/design/direct-messages.md, Owner reading). It works only
  on an `owner_can_read` server and only for the owner, writes an audit entry for every page,
  and grants no visibility.

  Not async: the privacy setting is cached in `:persistent_term`, which every test shares.
  """
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.AuditLogLine
  alias Tavern.Chat.ChannelMembership
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.ServerSettings
  alias Tavern.Chat.Visibility

  setup do
    Bootstrap.ensure_seed_data!()
    on_exit(&Chat.reset_server_settings_cache/0)
    owner = owner_fixture()
    ada = user_fixture()
    bo = user_fixture()
    {:ok, dm} = Chat.open_direct_message(scope_for(ada), bo.id)
    {:ok, message} = Chat.create_message(scope_for(ada), dm.id, %{"body" => "secret okapi"})
    %{owner: owner, ada: ada, bo: bo, dm: dm, message: message}
  end

  test "a private server refuses the owner and writes no entry", ctx do
    scope = scope_for(ctx.owner)

    refute Chat.owner_reader?(scope)
    assert {:error, :forbidden} = Chat.list_direct_messages_for_owner(scope)
    assert {:error, :forbidden} = Chat.read_direct_message_for_owner(scope, ctx.dm.id)
    assert reading_entries() == []
  end

  test "only the owner reads, not an administrator", ctx do
    allow_owner_reading()
    admin = user_fixture()

    member_role_fixture(
      admin,
      role_fixture(%{permissions: PermissionBits.combine([:administrator])})
    )

    refute Chat.owner_reader?(scope_for(admin))
    assert {:error, :forbidden} = Chat.read_direct_message_for_owner(scope_for(admin), ctx.dm.id)
    assert Chat.owner_reader?(scope_for(ctx.owner))
  end

  test "the list names both participants and reads no message", ctx do
    allow_owner_reading()

    assert {:ok, [row]} = Chat.list_direct_messages_for_owner(scope_for(ctx.owner))
    assert row.dm.id == ctx.dm.id
    assert Enum.sort(Enum.map(row.participants, & &1.id)) == Enum.sort([ctx.ada.id, ctx.bo.id])
    assert reading_entries() == []
  end

  test "a read writes an entry naming both participants, and grants no visibility", ctx do
    allow_owner_reading()
    {:ok, gone} = Chat.create_message(scope_for(ctx.bo), ctx.dm.id, %{"body" => "oops"})
    {:ok, _} = Chat.delete_message(scope_for(ctx.bo), gone.id)
    scope = scope_for(ctx.owner)

    assert {:ok, %{messages: [shown], next_cursor: nil}} =
             Chat.read_direct_message_for_owner(scope, ctx.dm.id)

    assert shown.id == ctx.message.id

    assert [entry] = reading_entries()
    assert entry.actor_user_id == ctx.owner.id
    assert entry.target_id == ctx.dm.id

    assert Enum.sort(entry.metadata["participant_ids"]) ==
             Enum.sort([ctx.ada.id, ctx.bo.id])

    assert AuditLogLine.format(Repo.preload(entry, [:actor_user, :subject_user, :channel])) =~
             "read the direct messages between @"

    refute Visibility.can?(scope, :view_channel, ctx.dm)
    assert Chat.list_direct_messages(scope) == []
    assert {:ok, %{messages: []}} = Chat.search_messages(scope, "okapi")

    refute Repo.exists?(
             from(m in ChannelMembership,
               where: m.channel_id == ^ctx.dm.id and m.user_id == ^ctx.owner.id
             )
           )
  end

  test "every page writes its own entry", ctx do
    allow_owner_reading()

    for n <- 1..50,
        do: {:ok, _} = Chat.create_message(scope_for(ctx.bo), ctx.dm.id, %{"body" => "n#{n}"})

    scope = scope_for(ctx.owner)

    assert {:ok, %{messages: newest, next_cursor: cursor}} =
             Chat.read_direct_message_for_owner(scope, ctx.dm.id)

    assert length(newest) == 50
    assert List.last(newest).body == "n50"

    assert {:ok, %{messages: [oldest], next_cursor: nil}} =
             Chat.read_direct_message_for_owner(scope, ctx.dm.id, cursor)

    assert oldest.id == ctx.message.id
    assert length(reading_entries()) == 2
  end

  test "an id that is not a live DM is not found and writes no entry", ctx do
    allow_owner_reading()
    scope = scope_for(ctx.owner)
    channel = channel_fixture(%{name: "Lobby", slug: unique_slug()})

    for id <- [channel.id, Ecto.UUID.generate(), "nope"] do
      assert {:error, :not_found} = Chat.read_direct_message_for_owner(scope, id)
    end

    assert reading_entries() == []
  end

  defp allow_owner_reading do
    Repo.update_all(ServerSettings, set: [direct_message_privacy: :owner_can_read])
    Chat.reset_server_settings_cache()
  end

  defp reading_entries do
    Repo.all(from(e in AuditLogEntry, where: e.action_type == "view_direct_message"))
  end
end
