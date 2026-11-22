defmodule Tavern.Chat.ChannelManagementTest do
  @moduledoc "Channel create, rename, place, soft delete and restore (docs/design/channel-management.md)."
  use Tavern.DataCase, async: false

  alias Tavern.Bootstrap
  alias Tavern.Bots
  alias Tavern.Chat
  alias Tavern.Chat.Channel
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  import Tavern.ChatFixtures

  setup do
    %{default_role: default_role} = Bootstrap.ensure_seed_data!()
    %{manager: scope_for(channel_manager_fixture()), default_role: default_role}
  end

  describe "create_channel/2" do
    test "creates each offered kind with a slug from its name", %{manager: manager} do
      for kind <- ["text", "announcement", "forum", "category"] do
        name = "Kind #{kind} #{System.unique_integer([:positive])}"

        assert {:ok, %Channel{} = channel} =
                 Chat.create_channel(manager, %{"name" => name, "kind" => kind})

        assert channel.kind == String.to_existing_atom(kind)
        assert channel.slug == Channel.slugify(name)
      end
    end

    test "refuses kinds that are not built", %{manager: manager} do
      for kind <- ["stage"] do
        assert {:error, changeset} =
                 Chat.create_channel(manager, %{"name" => "No", "kind" => kind})

        assert "is invalid" in errors_on(changeset).kind
      end
    end

    test "a taken slug gets the next free suffix, and a new channel lands last in its category",
         %{manager: manager} do
      {:ok, category} = Chat.create_channel(manager, %{"name" => "Group", "kind" => "category"})
      name = "Dup #{System.unique_integer([:positive])}"
      attrs = %{"name" => name, "kind" => "text", "parent_channel_id" => category.id}

      {:ok, first} = Chat.create_channel(manager, attrs)
      {:ok, second} = Chat.create_channel(manager, attrs)
      {:ok, third} = Chat.create_channel(manager, attrs)

      assert second.slug == first.slug <> "-2"
      assert third.slug == first.slug <> "-3"
      assert [first.id, second.id, third.id] == ids_under(manager, category.id)
    end

    test "needs manage_channels" do
      assert {:error, :forbidden} =
               Chat.create_channel(scope_for(user_fixture()), %{"name" => "No", "kind" => "text"})
    end
  end

  describe "update_channel/3" do
    test "a rename keeps the slug, and the slug, kind and parent are not editable",
         %{manager: manager} do
      channel = channel_fixture(%{name: "Before"})
      category = channel_fixture(%{kind: :category})

      assert {:ok, renamed} =
               Chat.update_channel(manager, channel.id, %{
                 "name" => "After",
                 "slug" => "hijacked",
                 "kind" => "forum",
                 "parent_channel_id" => category.id
               })

      assert renamed.name == "After"
      assert renamed.slug == channel.slug
      assert renamed.kind == :text
      assert renamed.parent_channel_id == nil
    end

    test "a member without manage_channels is refused" do
      channel = channel_fixture()

      assert {:error, :forbidden} =
               Chat.update_channel(scope_for(user_fixture()), channel.id, %{"name" => "x"})
    end
  end

  describe "place_channel/4" do
    test "moves a channel into another category before an anchor, and back to the top level",
         %{manager: manager} do
      from = channel_fixture(%{kind: :category})
      to = channel_fixture(%{kind: :category})
      moving = channel_fixture(%{parent_channel_id: from.id})
      a = channel_fixture(%{parent_channel_id: to.id, position: 1})
      b = channel_fixture(%{parent_channel_id: to.id, position: 2})

      assert {:ok, placed} = Chat.place_channel(manager, moving.id, to.id, b.id)
      assert placed.parent_channel_id == to.id
      assert ids_under(manager, to.id) == [a.id, moving.id, b.id]
      assert ids_under(manager, from.id) == []

      assert {:ok, %Channel{parent_channel_id: nil}} =
               Chat.place_channel(manager, moving.id, "", "")
    end

    test "a category is placed only at the top level, and only under a category",
         %{manager: manager} do
      category = channel_fixture(%{kind: :category})
      other = channel_fixture(%{kind: :category})
      text = channel_fixture()
      child = channel_fixture()

      assert {:error, :invalid_parent} = Chat.place_channel(manager, category.id, other.id, nil)
      assert {:error, :invalid_parent} = Chat.place_channel(manager, child.id, text.id, nil)
      assert {:ok, _} = Chat.place_channel(manager, category.id, nil, other.id)
    end
  end

  describe "delete_channel/2" do
    test "hides the channel, its threads and messages from scoped reads and the bot API",
         %{manager: manager} do
      owner = owner_fixture()
      member = user_fixture()
      channel = channel_fixture()
      starter = message_fixture(channel, member, %{body: "starter"})
      thread = thread_fixture(channel, starter, member)
      reply = message_fixture(thread, member, %{body: "reply"})
      bot = bot_scope(owner)

      assert {:ok, %{messages: [_]}} =
               Bots.command_list_messages(bot, %{"channel_id" => channel.id})

      assert {:ok, %Channel{deleted_at: %DateTime{}}} = Chat.delete_channel(manager, channel.id)

      for scope <- [scope_for(member), manager, bot] do
        visible = scope |> Chat.list_channels() |> Enum.map(& &1.id)
        refute channel.id in visible
        refute thread.id in visible
        assert Chat.get_channel(scope, channel.id) == nil
        assert Chat.get_channel_by_slug(scope, channel.slug) == nil
        assert Chat.get_thread(scope, thread.id) == nil
        assert Chat.get_message(scope, starter.id) == nil
        assert Chat.get_message(scope, reply.id) == nil
        assert {:error, :not_found} = Chat.list_messages(scope, channel.id)
        assert {:error, :not_found} = Chat.create_message(scope, channel.id, %{body: "hi"})
      end

      assert {:error, :not_found} =
               Bots.command_list_messages(bot, %{"channel_id" => channel.id})

      assert {:error, :not_found} = Chat.update_channel(manager, channel.id, %{"name" => "x"})
      assert {:error, :not_found} = Chat.delete_channel(manager, channel.id)
    end

    test "a deleted channel's slug is free for a new channel", %{manager: manager} do
      name = "Reuse #{System.unique_integer([:positive])}"
      {:ok, old} = Chat.create_channel(manager, %{"name" => name, "kind" => "text"})
      {:ok, _} = Chat.delete_channel(manager, old.id)

      assert {:ok, new} = Chat.create_channel(manager, %{"name" => name, "kind" => "text"})
      assert new.slug == old.slug
      assert Chat.get_channel_by_slug(manager, old.slug).id == new.id
    end

    test "deleting a category moves its channels, deleted ones too, to the end of the top level",
         %{manager: manager} do
      top = channel_fixture()
      category = channel_fixture(%{kind: :category})
      live = channel_fixture(%{parent_channel_id: category.id, position: 1})
      gone = channel_fixture(%{parent_channel_id: category.id, position: 2})
      {:ok, _} = Chat.delete_channel(manager, gone.id)

      assert {:ok, _} = Chat.delete_channel(manager, category.id)

      assert Repo.get!(Channel, live.id).parent_channel_id == nil
      assert Repo.get!(Channel, live.id).position > Repo.get!(Channel, top.id).position
      assert Repo.get!(Channel, gone.id).parent_channel_id == nil
      assert Chat.get_channel(manager, live.id)
      assert Chat.get_channel(manager, category.id) == nil
    end

    test "a member without manage_channels is refused and the channel stays" do
      channel = channel_fixture()
      assert {:error, :forbidden} = Chat.delete_channel(scope_for(user_fixture()), channel.id)
      assert Repo.get!(Channel, channel.id).deleted_at == nil
    end
  end

  describe "restore_channel/2" do
    test "brings a channel back at the end of its category, with its threads",
         %{manager: manager} do
      member = user_fixture()
      category = channel_fixture(%{kind: :category})
      channel = channel_fixture(%{parent_channel_id: category.id, position: 1})
      starter = message_fixture(channel, member, %{body: "starter"})
      thread = thread_fixture(channel, starter, member)
      {:ok, _} = Chat.delete_channel(manager, channel.id)
      later = channel_fixture(%{parent_channel_id: category.id, position: 5})

      assert [%Channel{id: id}] =
               Enum.filter(Chat.list_deleted_channels(manager), &(&1.id == channel.id))

      assert id == channel.id

      assert {:ok, restored} = Chat.restore_channel(manager, channel.id)
      assert restored.deleted_at == nil
      assert ids_under(manager, category.id) == [later.id, channel.id]
      assert Chat.get_thread(scope_for(member), thread.id)
      refute Enum.any?(Chat.list_deleted_channels(manager), &(&1.id == channel.id))
    end

    test "a channel whose category is gone comes back at the top level", %{manager: manager} do
      category = channel_fixture(%{kind: :category})
      channel = channel_fixture(%{parent_channel_id: category.id})
      {:ok, _} = Chat.delete_channel(manager, channel.id)
      {:ok, _} = Chat.delete_channel(manager, category.id)

      assert {:ok, %Channel{parent_channel_id: nil}} = Chat.restore_channel(manager, channel.id)
    end

    test "a slug a live channel took meanwhile gives the restored channel the next free one",
         %{manager: manager} do
      name = "Taken #{System.unique_integer([:positive])}"
      {:ok, old} = Chat.create_channel(manager, %{"name" => name, "kind" => "text"})
      {:ok, _} = Chat.delete_channel(manager, old.id)
      {:ok, new} = Chat.create_channel(manager, %{"name" => name, "kind" => "text"})

      assert {:ok, restored} = Chat.restore_channel(manager, old.id)
      assert new.slug == old.slug
      assert restored.slug == old.slug <> "-2"
    end

    test "is refused as missing to a non-manager, and for a channel the manager could not see",
         %{manager: manager, default_role: default_role} do
      channel = channel_fixture()
      hidden = channel_fixture()

      channel_permission_overwrite_fixture(hidden, %{
        role_id: default_role.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      owner = scope_for(owner_fixture())
      {:ok, _} = Chat.delete_channel(manager, channel.id)
      {:ok, _} = Chat.delete_channel(owner, hidden.id)

      assert {:error, :not_found} = Chat.restore_channel(scope_for(user_fixture()), channel.id)
      assert {:error, :not_found} = Chat.restore_channel(manager, hidden.id)
      refute Enum.any?(Chat.list_deleted_channels(manager), &(&1.id == hidden.id))
      assert Enum.any?(Chat.list_deleted_channels(owner), &(&1.id == hidden.id))
      assert Chat.list_deleted_channels(scope_for(user_fixture())) == []
      assert {:error, :not_found} = Chat.restore_channel(manager, Ecto.UUID.generate())
    end
  end

  # The visible channels under a category, in sidebar order.
  defp ids_under(scope, category_id) do
    scope
    |> Chat.list_channel_tree()
    |> Enum.find_value([], fn section ->
      section.category && section.category.id == category_id && section.channels
    end)
    |> Enum.map(& &1.id)
  end

  defp bot_scope(owner) do
    bot = bot_fixture(owner)
    {:ok, %{token: token}} = Bots.create_bot_token(scope_for(owner), bot.id, %{"label" => "test"})
    {:ok, scope} = Bots.get_bot_scope_by_token(token)
    scope
  end
end
