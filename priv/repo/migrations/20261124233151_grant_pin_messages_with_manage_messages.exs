defmodule Tavern.Repo.Migrations.GrantPinMessagesWithManageMessages do
  @moduledoc """
  `pin_messages` (bit 30) is new. Wherever a role or overwrite grants or denies
  `manage_messages` (bit 11), it now grants or denies `pin_messages` too, so a server's
  moderators can pin from the start. The values are literal: this migration must not change
  when `Tavern.Chat.PermissionBits` does.
  """
  use Ecto.Migration

  @manage_messages 2048
  @pin_messages 1_073_741_824

  @columns [
    {"roles", "permissions"},
    {"roles", "deny_permissions"},
    {"channel_permission_overwrites", "allow_permissions"},
    {"channel_permission_overwrites", "deny_permissions"}
  ]

  def up do
    for {table, column} <- @columns do
      execute """
      UPDATE #{table} SET #{column} = #{column} | #{@pin_messages}
      WHERE #{column} & #{@manage_messages} <> 0
      """
    end
  end

  def down do
    for {table, column} <- @columns do
      execute "UPDATE #{table} SET #{column} = #{column} & ~#{@pin_messages}::bigint"
    end
  end
end
