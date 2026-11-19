defmodule Tavern.Chat.Authorization do
  @moduledoc false

  import Bitwise

  alias Tavern.Accounts
  alias Tavern.Chat.Channel
  alias Tavern.Chat.ChannelPermissionOverwrite
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Role
  alias Tavern.Chat.User

  @all_permissions PermissionBits.flags() |> Map.keys() |> PermissionBits.combine()

  def all_permissions, do: @all_permissions

  @doc """
  The member's server bits. `default_role` is @everyone, or nil when there is none.
  `implicit_roles` are the other roles the member holds without a `member_roles` row: the
  Unverified role, which the caller derives (`Tavern.Accounts.unverified?/1`). They count exactly
  as given roles do.
  """
  def server_permissions(%User{} = user, default_role, implicit_roles) do
    user
    |> do_server_permissions(default_bits(default_role), held_roles(user, implicit_roles))
    |> expand_administrator()
  end

  # Overwrites apply to every active member, even one whose server bits are all denied or whose
  # default role grants nothing: a channel overwrite can still grant them bits there.
  def channel_permissions(%User{} = user, %Channel{} = channel, default_role, implicit_roles) do
    server_permissions = server_permissions(user, default_role, implicit_roles)

    cond do
      not active_member?(user) ->
        0

      administrator?(server_permissions) ->
        @all_permissions

      true ->
        apply_channel_overwrites(
          server_permissions,
          user,
          held_roles(user, implicit_roles),
          channel.permission_overwrites || [],
          default_role
        )
    end
  end

  def has_permission?(permissions, permission_name) when is_integer(permissions) do
    permission_bit = PermissionBits.flag(permission_name)
    band(permissions, permission_bit) == permission_bit
  end

  # A removed or banned account holds nothing. Allow wins: a role's deny removes only bits the
  # default role grants, and any held role's allow restores them. Both unions are taken before they
  # combine, so role order never matters. The default role holds no `member_roles` row and denies
  # nothing.
  defp do_server_permissions(%User{} = user, default_permissions, held_roles) do
    cond do
      not active_member?(user) ->
        0

      user.membership.is_owner ->
        @all_permissions

      true ->
        {allow, deny} =
          Enum.reduce(held_roles, {0, 0}, fn role, {allow, deny} ->
            {allow ||| role.permissions, deny ||| role.deny_permissions}
          end)

        default_permissions
        |> drop_permissions(deny)
        |> add_permissions(allow)
    end
  end

  # Every role the member holds other than the default role: the given ones and the implicit ones.
  defp held_roles(%User{} = user, implicit_roles),
    do: Enum.map(user.member_roles || [], & &1.role) ++ implicit_roles

  defp default_bits(%Role{permissions: permissions}), do: permissions
  defp default_bits(nil), do: 0

  defp active_member?(%User{} = user), do: Accounts.membership_state(user) == :active

  defp expand_administrator(permissions) do
    if administrator?(permissions), do: @all_permissions, else: permissions
  end

  defp administrator?(permissions), do: has_permission?(permissions, :administrator)

  defp apply_channel_overwrites(
         server_permissions,
         %User{} = user,
         held_roles,
         overwrites,
         default_role
       ) do
    {everyone_deny, everyone_allow} =
      overwrites
      |> Enum.filter(&matches_default_role?(&1, default_role))
      |> merge_overwrites()

    role_ids = MapSet.new(held_roles, & &1.id)

    {role_deny, role_allow} =
      overwrites
      |> Enum.filter(&matches_member_role?(&1, role_ids))
      |> merge_overwrites()

    {user_deny, user_allow} =
      overwrites
      |> Enum.filter(&(&1.user_id == user.id))
      |> merge_overwrites()

    server_permissions
    |> drop_permissions(everyone_deny)
    |> add_permissions(everyone_allow)
    |> drop_permissions(role_deny)
    |> add_permissions(role_allow)
    |> drop_permissions(user_deny)
    |> add_permissions(user_allow)
  end

  defp merge_overwrites(overwrites) do
    Enum.reduce(overwrites, {0, 0}, fn overwrite, {deny_permissions, allow_permissions} ->
      {
        deny_permissions ||| overwrite.deny_permissions,
        allow_permissions ||| overwrite.allow_permissions
      }
    end)
  end

  defp matches_default_role?(%ChannelPermissionOverwrite{role_id: role_id}, %Role{
         id: default_role_id
       }) do
    role_id == default_role_id
  end

  defp matches_default_role?(_overwrite, nil), do: false

  defp matches_member_role?(%ChannelPermissionOverwrite{role_id: nil}, _role_ids), do: false

  defp matches_member_role?(%ChannelPermissionOverwrite{role_id: role_id}, role_ids) do
    MapSet.member?(role_ids, role_id)
  end

  defp drop_permissions(permissions, denied_permissions),
    do: permissions &&& bnot(denied_permissions)

  defp add_permissions(permissions, allowed_permissions), do: permissions ||| allowed_permissions
end
