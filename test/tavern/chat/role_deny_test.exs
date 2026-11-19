defmodule Tavern.Chat.RoleDenyTest do
  @moduledoc """
  Server-level resolution with role denies: the default role's bits, minus every held role's
  deny, plus every held role's allow. Allow wins.
  """
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Authorization
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Role
  alias Tavern.Chat.Visibility

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()

    default = Chat.default_role()

    default =
      default
      |> Ecto.Changeset.change(permissions: bits([:view_channel, :send_messages, :add_reactions]))
      |> Repo.update!()

    channel = channel_fixture(%{name: "Lobby"})
    muted = role_fixture(%{name: "Muted", deny_permissions: bits([:send_messages])})

    %{owner: owner, default: default, channel: channel, muted: muted, member: user_fixture()}
  end

  defp bits(names), do: PermissionBits.combine(names)

  defp can?(user, action, target), do: Visibility.can?(scope_for(user), action, target)

  defp server_bits(user), do: Visibility.authority(scope_for(user), []).server_permissions

  describe "server-level resolution" do
    test "a role deny removes a bit the default role grants", ctx do
      member_role_fixture(ctx.member, ctx.muted)

      refute can?(ctx.member, :send_messages, ctx.channel)
      assert can?(ctx.member, :view_channel, ctx.channel)
      assert can?(ctx.member, :add_reactions, ctx.channel)
    end

    test "another held role's allow restores a denied bit, whatever the role order", ctx do
      speaker = role_fixture(%{name: "Speaker", permissions: bits([:send_messages])})
      member_role_fixture(ctx.member, speaker)
      member_role_fixture(ctx.member, ctx.muted)

      assert can?(ctx.member, :send_messages, ctx.channel)

      above = role_fixture(%{name: "Muted above", deny_permissions: bits([:send_messages])})
      member_role_fixture(ctx.member, above)

      assert can?(ctx.member, :send_messages, ctx.channel)
    end

    test "a deny on a bit the default role lacks changes nothing", ctx do
      before = server_bits(ctx.member)
      no_links = role_fixture(%{name: "No links", deny_permissions: bits([:embed_links])})
      member_role_fixture(ctx.member, no_links)

      assert server_bits(ctx.member) == before

      linker = role_fixture(%{name: "Linker", permissions: bits([:embed_links])})
      member_role_fixture(ctx.member, linker)

      assert can?(ctx.member, :embed_links, ctx.channel)
    end

    test "administrator and the owner bypass a role deny", ctx do
      admin = role_fixture(%{name: "Admin", permissions: bits([:administrator])})
      member_role_fixture(ctx.member, admin)
      member_role_fixture(ctx.member, ctx.muted)
      member_role_fixture(ctx.owner, ctx.muted)

      assert can?(ctx.member, :send_messages, ctx.channel)
      assert can?(ctx.owner, :send_messages, ctx.channel)
    end
  end

  describe "channel overwrites after a role deny" do
    test "a role overwrite allow re-grants the denied bit in that channel only", ctx do
      member_role_fixture(ctx.member, ctx.muted)
      elsewhere = channel_fixture(%{name: "Elsewhere"})

      channel_permission_overwrite_fixture(ctx.channel, %{
        role_id: ctx.muted.id,
        allow_permissions: bits([:send_messages])
      })

      assert can?(ctx.member, :send_messages, ctx.channel)
      refute can?(ctx.member, :send_messages, elsewhere)
    end

    test "a role overwrite re-grants view and send after a role denies both", ctx do
      jail =
        role_fixture(%{name: "Jail", deny_permissions: bits([:view_channel, :send_messages])})

      member_role_fixture(ctx.member, jail)

      ctx.default
      |> Ecto.Changeset.change(permissions: bits([:view_channel, :send_messages]))
      |> Repo.update!()

      assert server_bits(ctx.member) == 0
      refute can?(ctx.member, :view_channel, ctx.channel)

      channel_permission_overwrite_fixture(ctx.channel, %{
        role_id: jail.id,
        allow_permissions: bits([:view_channel, :send_messages])
      })

      assert can?(ctx.member, :view_channel, ctx.channel)
      assert can?(ctx.member, :send_messages, ctx.channel)
    end

    test "an active member with no server bits gets view from a role overwrite", ctx do
      ctx.default |> Ecto.Changeset.change(permissions: 0) |> Repo.update!()
      reader = role_fixture(%{name: "Reader"})
      member_role_fixture(ctx.member, reader)

      assert server_bits(ctx.member) == 0
      refute can?(ctx.member, :view_channel, ctx.channel)

      channel_permission_overwrite_fixture(ctx.channel, %{
        role_id: reader.id,
        allow_permissions: bits([:view_channel])
      })

      assert can?(ctx.member, :view_channel, ctx.channel)
      refute can?(ctx.member, :send_messages, ctx.channel)
    end

    test "a removed member gets nothing from an allowing overwrite", ctx do
      channel_permission_overwrite_fixture(ctx.channel, %{
        user_id: ctx.member.id,
        allow_permissions: bits([:view_channel, :send_messages])
      })

      channel = Repo.preload(ctx.channel, :permission_overwrites, force: true)
      user = Repo.preload(ctx.member, [:membership, member_roles: :role], force: true)
      assert Authorization.channel_permissions(user, channel, ctx.default, []) != 0

      deactivated = put_in(user.membership.deactivated_at, DateTime.utc_now())
      assert Authorization.channel_permissions(deactivated, channel, ctx.default, []) == 0

      assert Authorization.channel_permissions(
               %{user | membership: nil},
               channel,
               ctx.default,
               []
             ) ==
               0
    end

    test "a user overwrite allow re-grants the denied bit", ctx do
      member_role_fixture(ctx.member, ctx.muted)

      channel_permission_overwrite_fixture(ctx.channel, %{
        user_id: ctx.member.id,
        allow_permissions: bits([:send_messages])
      })

      assert can?(ctx.member, :send_messages, ctx.channel)
    end
  end

  describe "role rows" do
    test "a bit both allowed and denied on one role is refused", ctx do
      changeset =
        Role.changeset(ctx.muted, %{permissions: bits([:send_messages])})

      refute changeset.valid?
      assert %{deny_permissions: [_]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{}} =
               Chat.update_role(scope_for(ctx.owner), ctx.muted.id, %{
                 "permissions" => bits([:send_messages])
               })

      assert_raise Postgrex.Error, ~r/role_bits_allowed_or_denied/, fn ->
        from(role in Role, where: role.id == ^ctx.muted.id)
        |> Repo.update_all(set: [permissions: bits([:send_messages])])
      end
    end

    test "the default role refuses deny bits", ctx do
      assert {:error, changeset} =
               Chat.update_role(scope_for(ctx.owner), ctx.default.id, %{
                 "deny_permissions" => bits([:send_messages])
               })

      assert %{deny_permissions: [_]} = errors_on(changeset)
      assert Repo.get!(Role, ctx.default.id).deny_permissions == 0

      assert_raise Postgrex.Error, ~r/default_role_denies_nothing/, fn ->
        from(role in Role, where: role.id == ^ctx.default.id)
        |> Repo.update_all(set: [deny_permissions: bits([:attach_files])])
      end
    end

    test "the owner sets a role's deny bits, and the audit entry records them", ctx do
      assert {:ok, role} =
               Chat.update_role(scope_for(ctx.owner), ctx.muted.id, %{
                 "deny_permissions" => bits([:send_messages, :add_reactions])
               })

      assert role.deny_permissions == bits([:send_messages, :add_reactions])

      entry =
        Repo.get_by!(Tavern.Chat.AuditLogEntry, action_type: "role_updated", target_id: role.id)

      assert entry.metadata["deny_permissions"] == role.deny_permissions
    end
  end
end
