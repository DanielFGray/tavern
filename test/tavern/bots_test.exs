defmodule Tavern.BotsTest do
  use Tavern.DataCase

  import Ecto.Query, only: [from: 2]
  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Bots
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.Membership
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  describe "bot tokens and command registry" do
    test "creates bot users with roles and one-time tokens" do
      actor = owner_fixture(%{email: "bot-owner@example.com", username: "bot_owner"})

      role =
        role_fixture(%{
          name: "Bot Speaker",
          permissions: PermissionBits.combine([:send_messages])
        })

      {:ok, bot_user} =
        Bots.create_bot(scope_for(actor), %{
          "display_name" => "Helper Bot",
          "username" => "helper_bot",
          "email" => "helper-bot@example.com",
          "role_ids" => [role.id]
        })

      assert bot_user.bot
      assert Enum.any?(bot_user.member_roles, &(&1.role_id == role.id))

      {:ok, %{token: token}} =
        Bots.create_bot_token(scope_for(actor), bot_user.id, %{"label" => "primary"})

      assert {:ok, bot_scope} = Bots.get_bot_scope_by_token(token)
      assert bot_scope.user_id == bot_user.id
    end

    test "executes registered message command" do
      actor = owner_fixture(%{email: "bot-cmd-owner@example.com", username: "bot_cmd_owner"})

      role =
        role_fixture(%{
          name: "Bot Speaker",
          permissions: PermissionBits.combine([:view_channel, :send_messages])
        })

      channel = channel_fixture(%{name: "Bots", slug: unique_slug()})
      bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})

      {:ok, %{message: message}} =
        Bots.execute_command(
          "send_message",
          bot_scope_for(bot_user, actor),
          %{"channel_id" => channel.id, "body" => "hello from bot"}
        )

      assert message.body == "hello from bot"
      assert message.channel_id == channel.id
    end

    test "a human user is not a bot: no token can be minted for one" do
      owner = owner_fixture()
      user = user_fixture(%{email: "human@example.com", username: "human_user"})

      assert {:error, :not_found} = Bots.create_bot_token(scope_for(owner), user.id, %{})
    end

    test "send_message returns invalid_params for malformed channel ids" do
      actor =
        owner_fixture(%{email: "bot-bad-channel-owner@example.com", username: "bot_bad_owner"})

      bot_user = bot_fixture(actor)

      assert {:error, :invalid_params} =
               Bots.command_send_message(
                 bot_scope_for(bot_user, actor),
                 %{"channel_id" => "not-a-uuid", "body" => "hello"}
               )
    end
  end

  describe "audit entries" do
    test "every bot write records who did what to which bot" do
      owner = owner_fixture()
      scope = scope_for(owner)
      role = role_fixture()

      {:ok, bot} = Bots.create_bot(scope, bot_attrs(%{"role_ids" => [role.id]}))
      {:ok, _bot} = Bots.update_bot(scope, bot.id, %{"display_name" => "Renamed"})
      {:ok, %{bot_token: token}} = Bots.create_bot_token(scope, bot.id, %{"label" => "ci"})
      {:ok, _token} = Bots.revoke_bot_token(scope, token.id)
      {:ok, _bot} = Bots.revoke_bot(scope, bot.id)

      entries =
        Repo.all(
          from(entry in AuditLogEntry,
            where: entry.target_type == "bot" and entry.target_id == ^bot.id,
            order_by: [asc: entry.inserted_at, asc: entry.id]
          )
        )

      assert Enum.map(entries, & &1.action_type) ==
               ~w(bot_created bot_updated bot_token_created bot_token_revoked bot_revoked)

      assert Enum.all?(entries, &(&1.actor_user_id == owner.id and &1.subject_user_id == bot.id))

      by_action = Map.new(entries, &{&1.action_type, &1.metadata})
      assert by_action["bot_created"] == %{"role_ids" => [role.id]}
      assert by_action["bot_updated"] == %{}
      assert by_action["bot_token_created"] == %{"token_id" => token.id}
      assert by_action["bot_token_revoked"] == %{"token_id" => token.id}
    end
  end

  describe "bot authority" do
    setup do
      owner = owner_fixture()
      %{owner: owner}
    end

    test "a manage_bots-only member cannot give a bot an administrator role" do
      bot_manager = member_with([:manage_bots])
      admin_role = role_fixture(%{permissions: PermissionBits.combine([:administrator])})

      assert {:error, :forbidden} =
               Bots.create_bot(
                 scope_for(bot_manager),
                 bot_attrs(%{"role_ids" => [admin_role.id]})
               )

      assert Bots.list_controllable_bot_users(scope_for(bot_manager)) == []
    end

    test "the system user is never a manageable bot", %{owner: owner} do
      %{system_user: system_user} = Bootstrap.ensure_seed_data!()

      refute Enum.any?(
               Bots.list_controllable_bot_users(scope_for(owner)),
               &(&1.id == system_user.id)
             )

      assert {:error, :not_found} = Bots.create_bot_token(scope_for(owner), system_user.id, %{})
      assert {:error, :not_found} = Bots.update_bot(scope_for(owner), system_user.id, %{})
    end

    test "a manage_bots-only member cannot give a bot any role" do
      bot_manager = member_with([:manage_bots])
      speaker = role_fixture(%{permissions: 0, position: 0})

      assert {:error, :forbidden} =
               Bots.create_bot(scope_for(bot_manager), bot_attrs(%{"role_ids" => [speaker.id]}))
    end

    test "a role manager can grant only lower roles whose permissions they hold" do
      manager = member_with([:manage_bots, :manage_roles, :send_messages], position: 50)
      lower = role_fixture(%{permissions: PermissionBits.combine([:send_messages]), position: 10})
      higher = role_fixture(%{permissions: 0, position: 60})
      stronger = role_fixture(%{permissions: PermissionBits.combine([:ban_members]), position: 5})

      assert {:ok, bot} =
               Bots.create_bot(scope_for(manager), bot_attrs(%{"role_ids" => [lower.id]}))

      assert [%{role_id: role_id}] = bot.member_roles
      assert role_id == lower.id

      for role <- [higher, stronger] do
        assert {:error, :forbidden} =
                 Bots.create_bot(scope_for(manager), bot_attrs(%{"role_ids" => [role.id]}))
      end

      assert Enum.map(Bots.grantable_roles(scope_for(manager)), & &1.id) == [lower.id]
    end

    test "a bot manager cannot mint a token for a bot that outranks them", %{owner: owner} do
      admin_role = role_fixture(%{permissions: PermissionBits.combine([:administrator])})
      admin_bot = bot_fixture(owner, %{"role_ids" => [admin_role.id]})
      bot_manager = member_with([:manage_bots])

      assert {:error, :forbidden} =
               Bots.create_bot_token(scope_for(bot_manager), admin_bot.id, %{})

      assert {:error, :forbidden} = Bots.revoke_bot(scope_for(bot_manager), admin_bot.id)
      assert {:ok, []} = Bots.list_controllable_bot_tokens(scope_for(owner), admin_bot.id)
    end

    test "a token revoke needs control of the token's bot, decided before the token is read",
         %{owner: owner} do
      admin_role = role_fixture(%{permissions: PermissionBits.combine([:administrator])})
      admin_bot = bot_fixture(owner, %{"role_ids" => [admin_role.id]})
      {:ok, %{bot_token: token}} = Bots.create_bot_token(scope_for(owner), admin_bot.id, %{})
      bot_manager = member_with([:manage_bots])
      member = user_fixture()

      assert {:error, :forbidden} = Bots.revoke_bot_token(scope_for(bot_manager), token.id)

      for token_id <- [token.id, Ecto.UUID.generate()] do
        assert {:error, :forbidden} = Bots.revoke_bot_token(scope_for(member), token_id)
      end

      assert {:error, :not_found} = Bots.revoke_bot_token(scope_for(owner), Ecto.UUID.generate())
      refute Repo.reload!(token).revoked_at
      assert {:ok, %{revoked_at: %DateTime{}}} = Bots.revoke_bot_token(scope_for(owner), token.id)
    end

    test "authority is read from the database when the write runs" do
      manager_role = role_fixture(%{permissions: PermissionBits.combine([:manage_bots])})
      manager = user_fixture()
      member_role = member_role_fixture(manager, manager_role)
      scope = scope_for(manager)

      Tavern.Repo.delete!(member_role)

      assert {:error, :forbidden} = Bots.create_bot(scope, bot_attrs())
    end

    test "updating a bot without role_ids keeps its roles", %{owner: owner} do
      role = role_fixture()
      bot = bot_fixture(owner, %{"role_ids" => [role.id]})

      assert {:ok, updated} =
               Bots.update_bot(scope_for(owner), bot.id, %{"display_name" => "Renamed"})

      assert updated.display_name == "Renamed"
      assert Enum.map(updated.member_roles, & &1.role_id) == [role.id]
    end

    test "a manager cannot grant or control a role that unlocks a private channel", %{
      owner: owner
    } do
      manager = member_with([:manage_bots, :manage_roles], position: 50)
      {private, insider} = private_channel_insider_role()

      assert {:error, :forbidden} =
               Bots.create_bot(scope_for(manager), bot_attrs(%{"role_ids" => [insider.id]}))

      refute Enum.any?(Bots.grantable_roles(scope_for(manager)), &(&1.id == insider.id))

      bot = bot_fixture(owner, %{"role_ids" => [insider.id]})
      assert {:error, :forbidden} = Bots.create_bot_token(scope_for(manager), bot.id, %{})

      assert {:ok, _bot} =
               Bots.create_bot(scope_for(owner), bot_attrs(%{"role_ids" => [insider.id]}))

      channel_permission_overwrite_fixture(private, %{
        user_id: manager.id,
        allow_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:ok, granted} =
               Bots.create_bot(scope_for(manager), bot_attrs(%{"role_ids" => [insider.id]}))

      assert Enum.any?(granted.member_roles, &(&1.role_id == insider.id))
      assert Enum.any?(Bots.grantable_roles(scope_for(manager)), &(&1.id == insider.id))
    end
  end

  defp private_channel_insider_role do
    Bootstrap.ensure_seed_data!()
    private = channel_fixture(%{name: "Private", slug: unique_slug()})

    channel_permission_overwrite_fixture(private, %{
      role_id: default_role().id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    insider =
      role_fixture(%{
        name: "Insider #{System.unique_integer([:positive])}",
        permissions: 0,
        position: 10
      })

    channel_permission_overwrite_fixture(private, %{
      role_id: insider.id,
      allow_permissions: PermissionBits.combine([:view_channel])
    })

    {private, insider}
  end

  defp member_with(permissions, opts \\ []) do
    role =
      role_fixture(%{
        permissions: PermissionBits.combine(permissions),
        position: Keyword.get(opts, :position, 1)
      })

    member = user_fixture()
    member_role_fixture(member, role)
    member
  end

  defp bot_attrs(attrs \\ %{}) do
    id = System.unique_integer([:positive])

    Map.merge(
      %{
        "display_name" => "Bot #{id}",
        "username" => "bot_#{id}",
        "email" => "bot_#{id}@example.com"
      },
      attrs
    )
  end

  test "get_bot_scope_by_token refuses a valid token whose bot is deactivated" do
    actor = owner_fixture(%{email: "bot-deact-owner@example.com", username: "bot_deact_owner"})
    bot_user = bot_fixture(actor)

    {:ok, %{token: token}} =
      Bots.create_bot_token(scope_for(actor), bot_user.id, %{"label" => "deact"})

    assert {:ok, _scope} = Bots.get_bot_scope_by_token(token)

    Repo.update_all(from(m in Membership, where: m.user_id == ^bot_user.id),
      set: [deactivated_at: DateTime.utc_now()]
    )

    assert {:error, :unauthorized} = Bots.get_bot_scope_by_token(token)
  end

  defp bot_scope_for(bot_user, actor) do
    {:ok, %{token: token}} =
      Bots.create_bot_token(scope_for(actor), bot_user.id, %{"label" => "test"})

    {:ok, scope} = Bots.get_bot_scope_by_token(token)
    scope
  end
end
