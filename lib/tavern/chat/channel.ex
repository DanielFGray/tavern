defmodule Tavern.Chat.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channels" do
    field(:name, :string)
    field(:slug, :string)
    field(:position, :integer, default: 0)
    field(:topic, :string)
    field(:unread_count, :integer, virtual: true, default: 0)

    field(:kind, Ecto.Enum,
      values: [
        :text,
        :category,
        :announcement,
        :forum,
        :voice,
        :stage,
        :thread_public,
        :thread_private,
        :thread_announcement
      ],
      default: :text
    )

    field(:nsfw, :boolean, default: false)
    field(:slowmode_seconds, :integer, default: 0)
    # How many members may sit in one voice channel at once. Only a `:voice` channel reads it.
    field(:voice_member_limit, :integer, default: 6)
    field(:default_auto_archive_minutes, :integer, default: 1440)
    field(:archived_at, :utc_datetime_usec)
    field(:locked_at, :utc_datetime_usec)
    # Set when a manager deletes the channel. A deleted channel is hidden from everyone, with its
    # threads and messages, until it is restored (docs/design/channel-management.md).
    field(:deleted_at, :utc_datetime_usec)
    # A thread's tags, set from its title and starter message by `Tavern.Chat.Hashtags`.
    field(:hashtags, {:array, :string}, default: [])

    belongs_to(:parent_channel, __MODULE__)
    belongs_to(:created_by, Tavern.Chat.User)
    belongs_to(:starter_message, Tavern.Chat.Message)

    has_many(:messages, Tavern.Chat.Message)
    has_many(:child_channels, __MODULE__, foreign_key: :parent_channel_id)
    has_many(:channel_memberships, Tavern.Chat.ChannelMembership)
    has_many(:permission_overwrites, Tavern.Chat.ChannelPermissionOverwrite)
    has_many(:tags, Tavern.Chat.ChannelTag)

    timestamps(type: :utc_datetime_usec)
  end

  @thread_kinds [:thread_public, :thread_private, :thread_announcement]

  def thread?(%__MODULE__{kind: kind}), do: kind in @thread_kinds

  @doc """
  Whether the channel may hold public threads: text-like channels and forums. A forum's threads
  are its posts, and each starts from a message inside itself (docs/design/forums.md).
  """
  def thread_host?(%__MODULE__{kind: kind}), do: kind in [:text, :announcement, :forum]

  def forum?(%__MODULE__{kind: kind}), do: kind == :forum

  # The kinds a manager may create. Voice channels carry the voice room rules (docs/design/voice.md).
  @managed_kinds [:text, :announcement, :forum, :category, :voice]

  def managed_kinds, do: @managed_kinds

  @doc """
  A changeset for a new channel or category. `Tavern.Chat.Channels` sets the slug and position
  when the attrs do not carry them; only provisioning and fixtures pass them. A thread is not
  made here: its kind, parent, starter message and creator are fixed when it is created (see
  `thread_changeset/2`), because a thread's visibility comes from its parent.
  """
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :name,
      :slug,
      :position,
      :topic,
      :kind,
      :parent_channel_id,
      :nsfw,
      :slowmode_seconds,
      :default_auto_archive_minutes,
      :voice_member_limit
    ])
    |> validate_not_thread()
    |> validate_inclusion(:kind, @managed_kinds)
    |> validate_settings()
  end

  @doc """
  A changeset for a manager's edit of a channel or category. The slug, kind, parent and position
  are not edited here: the slug keeps the value it was created with, so links to the channel
  stay valid after a rename, and a move goes through `Tavern.Chat.Channels.place_channel/4`.
  """
  def settings_changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :name,
      :topic,
      :nsfw,
      :slowmode_seconds,
      :default_auto_archive_minutes,
      :voice_member_limit
    ])
    |> validate_not_thread()
    |> validate_settings()
  end

  @doc """
  The slug a name gives: lowercase letters, digits and single hyphens, at most 40 characters.
  A name with none of those gives `"channel"`.
  """
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.slice(0, 40)
    |> String.trim("-")
    |> case do
      "" -> "channel"
      slug -> slug
    end
  end

  def slugify(_name), do: "channel"

  @doc """
  A changeset for a thread. The caller sets the kind, slug, position, parent channel, starter
  message and creator on the struct; a client chooses only the name.

  A thread's `name` is its title once someone has named it (a forum post's author, a rename, a
  bot that names a thread it starts), and nil until then. `title/1` gives what a view shows.
  """
  def thread_changeset(%__MODULE__{kind: kind} = thread, attrs) when kind in @thread_kinds do
    thread
    |> cast(attrs, [:name])
    |> validate_settings([:slug, :position])
  end

  @title_length 40

  @doc """
  What a view shows as the name of `channel`. A channel and a named thread show their name. A
  thread that no one has named shows the start of its starter message, so the starter must be
  loaded (`Repo.preload(thread, :starter_message)`); a thread with no starter shows `"Thread"`.
  """
  def title(%__MODULE__{name: name}) when is_binary(name), do: name
  def title(%__MODULE__{starter_message: %Tavern.Chat.Message{body: body}}), do: title_from(body)
  def title(%__MODULE__{starter_message: nil}), do: "Thread"

  @doc "The title of a thread that starts from a message with `body`: its first 40 characters."
  def title_from(body) when is_binary(body) do
    case String.trim(body) do
      "" -> "Thread"
      text -> String.slice(text, 0, @title_length)
    end
  end

  defp validate_not_thread(changeset) do
    cond do
      changeset.data.kind in @thread_kinds ->
        add_error(changeset, :kind, "a thread is not edited as a channel")

      get_field(changeset, :kind) in @thread_kinds ->
        add_error(changeset, :kind, "is invalid")

      true ->
        changeset
    end
  end

  defp validate_settings(changeset, required \\ [:name, :slug, :position]) do
    changeset
    |> update_change(:name, &normalize_text/1)
    |> update_change(:slug, &normalize_slug/1)
    |> update_change(:topic, &normalize_optional_text/1)
    |> validate_required(required)
    |> validate_length(:name, min: 1, max: @title_length)
    |> validate_length(:slug, min: 1, max: 48)
    |> validate_length(:topic, max: 160)
    |> validate_number(:slowmode_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 21_600
    )
    |> validate_number(:default_auto_archive_minutes,
      greater_than_or_equal_to: 60,
      less_than_or_equal_to: 10_080
    )
    |> validate_number(:voice_member_limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 25
    )
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> validate_category_parenting()
    |> unique_constraint(:slug, name: :channels_live_slug_index)
  end

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value

  defp normalize_optional_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_text(value), do: value

  defp normalize_slug(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_slug(value), do: value

  defp validate_category_parenting(changeset) do
    if get_field(changeset, :kind) == :category and get_field(changeset, :parent_channel_id) do
      add_error(changeset, :parent_channel_id, "categories cannot be nested")
    else
      changeset
    end
  end
end
