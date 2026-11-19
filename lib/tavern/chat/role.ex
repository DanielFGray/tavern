defmodule Tavern.Chat.Role do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "roles" do
    field(:name, :string)
    field(:description, :string)
    field(:color, :integer, default: 0)
    field(:permissions, :integer, default: 0)
    field(:deny_permissions, :integer, default: 0)
    field(:position, :integer, default: 0)
    field(:mentionable, :boolean, default: false)
    field(:hoist, :boolean, default: false)
    field(:managed, :boolean, default: false)
    field(:is_default, :boolean, default: false)
    field(:member_count, :integer, virtual: true)

    belongs_to(:icon_asset, Tavern.Chat.MediaAsset)

    has_many(:member_roles, Tavern.Chat.MemberRole)
    has_many(:emoji_roles, Tavern.Chat.EmojiRole)
    has_many(:permission_overwrites, Tavern.Chat.ChannelPermissionOverwrite)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [
      :name,
      :description,
      :color,
      :permissions,
      :deny_permissions,
      :position,
      :mentionable,
      :hoist,
      :managed,
      :is_default,
      :icon_asset_id
    ])
    |> validate_required([:name, :permissions, :position])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:permissions, greater_than_or_equal_to: 0)
    |> validate_number(:deny_permissions, greater_than_or_equal_to: 0)
    |> validate_deny()
  end

  @doc """
  The fields a person may set on a role. Position, `managed` and `is_default` are set by
  `Tavern.Chat.Roles`, never from input. The default role takes only its bits, and its deny must
  stay empty: it is the base that every other role's deny subtracts from.
  """
  def manage_changeset(%__MODULE__{is_default: true} = role, attrs) do
    role
    |> cast(attrs, [:permissions, :deny_permissions])
    |> validate_bits()
  end

  def manage_changeset(%__MODULE__{} = role, attrs) do
    role
    |> cast(attrs, [
      :name,
      :description,
      :color,
      :permissions,
      :deny_permissions,
      :mentionable,
      :hoist
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:color, greater_than_or_equal_to: 0, less_than_or_equal_to: 0xFFFFFF)
    |> validate_bits()
  end

  # The owner skips the subset rule, so the bits are checked against the known flags here.
  defp validate_bits(changeset) do
    changeset
    |> validate_known_bits(:permissions)
    |> validate_known_bits(:deny_permissions)
    |> validate_deny()
  end

  defp validate_known_bits(changeset, field) do
    all = Tavern.Chat.Authorization.all_permissions()

    changeset
    |> validate_required([field])
    |> validate_change(field, fn ^field, bits ->
      if bits >= 0 and Bitwise.band(bits, Bitwise.bnot(all)) == 0,
        do: [],
        else: [{field, "has unknown permission bits"}]
    end)
  end

  # Each bit on a role is allowed, denied or neither, never both. The default role denies nothing.
  # The database holds the same two rules as check constraints.
  defp validate_deny(changeset) do
    allow = get_field(changeset, :permissions) || 0
    deny = get_field(changeset, :deny_permissions) || 0

    changeset =
      cond do
        get_field(changeset, :is_default) and deny != 0 ->
          add_error(changeset, :deny_permissions, "the default role cannot deny permissions")

        Bitwise.band(allow, deny) != 0 ->
          add_error(
            changeset,
            :deny_permissions,
            "a permission cannot be both allowed and denied"
          )

        true ->
          changeset
      end

    changeset
    |> check_constraint(:deny_permissions, name: :role_bits_allowed_or_denied)
    |> check_constraint(:deny_permissions, name: :default_role_denies_nothing)
  end
end
