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
        :thread_announcement,
        :direct
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
    # A direct message names its two participants, the lower id first
    # (docs/design/direct-messages.md). Every other kind leaves both nil.
    belongs_to(:direct_low_user, Tavern.Chat.User)
    belongs_to(:direct_high_user, Tavern.Chat.User)
    # The other participant of a direct message, for the account that read it.
    field(:peer, :any, virtual: true)

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

  def direct?(%__MODULE__{kind: kind}), do: kind == :direct

  @doc "The two participants of a direct message, the lower id first."
  def participant_ids(%__MODULE__{kind: :direct} = channel),
    do: [channel.direct_low_user_id, channel.direct_high_user_id]

  @doc "Whether `user_id` is one of the two participants of a direct message."
  def participant?(%__MODULE__{kind: :direct} = channel, user_id),
    do: user_id in participant_ids(channel)

  def participant?(%__MODULE__{}, _user_id), do: false

  @doc "The participant of a direct message who is not `user_id`."
  def peer_id(%__MODULE__{kind: :direct} = channel, user_id),
    do: channel |> participant_ids() |> Enum.find(&(&1 != user_id))

  @doc """
  A new direct message between two accounts, unsaved. The ids are put in order, so a pair always
  names the same row (the unique index `channels_direct_pair_index`). A DM has no name: each
  viewer sees the peer's. Its slug is a placeholder, as a thread's is.
  """
  def new_direct(user_id, other_user_id) do
    [low, high] = Enum.sort([user_id, other_user_id])

    %__MODULE__{
      kind: :direct,
      slug: "dm-#{Ecto.UUID.generate()}",
      direct_low_user_id: low,
      direct_high_user_id: high
    }
  end

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
  @deleted_starter_title "Deleted message"

  @doc """
  What a view shows as the name of `channel`. A channel and a named thread show their name. A
  thread that no one has named shows the start of its starter message, so the starter must be
  loaded (`Repo.preload(thread, :starter_message)`); a thread with no starter shows `"Thread"`.
  A thread whose starter was deleted shows `"Deleted message"`: the starter's body is a
  placeholder, and no part of it may show as a title.
  """
  def title(%__MODULE__{name: name}) when is_binary(name), do: name

  def title(%__MODULE__{starter_message: %Tavern.Chat.Message{deleted_at: %DateTime{}}}),
    do: @deleted_starter_title

  def title(%__MODULE__{starter_message: %Tavern.Chat.Message{body: body}}), do: title_from(body)
  def title(%__MODULE__{starter_message: nil}), do: "Thread"

  @doc """
  Whether `title/1` is the placeholder for a deleted starter. A view draws that title muted, so
  it reads as a missing name rather than a message's text.
  """
  def deleted_starter_title?(%__MODULE__{name: name} = thread) when not is_binary(name),
    do: title(thread) == @deleted_starter_title

  def deleted_starter_title?(%__MODULE__{}), do: false

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
