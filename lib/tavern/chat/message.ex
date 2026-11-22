defmodule Tavern.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [where: 3]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field(:body, :string)

    field(:kind, Ecto.Enum,
      values: [:default, :system, :reply, :thread_starter, :call, :slash_command],
      default: :default
    )

    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    field(:pinned_at, :utc_datetime_usec)
    field(:nonce, :string)
    field(:metadata, :map, default: %{})
    field(:suppress_embeds, :boolean, default: false)

    belongs_to(:channel, Tavern.Chat.Channel)
    belongs_to(:author, Tavern.Chat.User)
    belongs_to(:reply_to, __MODULE__)

    has_many(:attachments, Tavern.Chat.MessageAttachment)
    has_many(:reactions, Tavern.Chat.Reaction)
    has_many(:reports, Tavern.Chat.MessageReport)
    has_many(:user_mentions, Tavern.Chat.MessageUserMention)
    has_many(:role_mentions, Tavern.Chat.MessageRoleMention)
    has_many(:embeds, Tavern.Chat.MessageEmbed, preload_order: [asc: :position])
    has_one(:question, Tavern.Chat.Question)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  A changeset for what an author writes: the body and the composer's metadata. The server sets
  every other field itself (`kind`, `nonce`, `edited_at`, `deleted_at`, `pinned_at`,
  `suppress_embeds`), so a client cannot forge a system message, a pin or a deletion.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :metadata])
    |> validate_required([:body])
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, min: 1, max: 4000)
    |> validate_change(:metadata, &check_metadata_bounds/2)
  end

  @doc "A changeset for a new message: what `changeset/2` takes, plus the message it replies to."
  def create_changeset(message, attrs) do
    message
    |> cast(attrs, [:reply_to_id])
    |> changeset(attrs)
  end

  def deleted?(%{deleted_at: deleted_at}), do: not is_nil(deleted_at)

  @doc """
  Whether a list shows the message: the transcript, reply counts, unread counts, channel previews
  and bot history. A deleted message is not listed, nor is a closed permission request
  (docs/design/questions.md): a bot asks many of them, and once answered they only hide the
  conversation around them. Reading the message by its id still finds it. `where_listed/1` is
  the same rule as a query; this one needs the question preloaded.
  """
  def listed?(%__MODULE__{} = message),
    do: not deleted?(message) and not closed_permission?(message.question)

  @doc "Narrows a query whose first binding is a message to the messages `listed?/1` accepts."
  def where_listed(query) do
    where(
      query,
      [message],
      is_nil(message.deleted_at) and
        fragment(
          "NOT EXISTS (SELECT 1 FROM questions WHERE message_id = ? AND kind = 'permission' AND closed_at IS NOT NULL)",
          message.id
        )
    )
  end

  defp closed_permission?(nil), do: false

  defp closed_permission?(%Tavern.Chat.Question{kind: kind, closed_at: closed_at}),
    do: kind == :permission and not is_nil(closed_at)

  # Metadata is stored as the client sent it (`Tavern.Chat.Messages` keeps only `entities`), so
  # these bounds are all that stops a client from filling a row. The numbers are argued in
  # docs/design/bot-api.md, "Metadata limits".
  @max_metadata_bytes 16_384
  @max_metadata_depth 3

  defp check_metadata_bounds(field, metadata) do
    cond do
      byte_size(Jason.encode!(metadata)) > @max_metadata_bytes ->
        [{field, {"is larger than %{max} bytes encoded", max: @max_metadata_bytes}}]

      nesting_depth(metadata) > @max_metadata_depth ->
        [{field, {"nests deeper than %{max} levels", max: @max_metadata_depth}}]

      true ->
        []
    end
  end

  # A map or list is one level deeper than its deepest child; a scalar adds no level.
  defp nesting_depth(%{} = map), do: 1 + deepest(Map.values(map))
  defp nesting_depth(list) when is_list(list), do: 1 + deepest(list)
  defp nesting_depth(_scalar), do: 0

  defp deepest(values), do: values |> Enum.map(&nesting_depth/1) |> Enum.max(fn -> 0 end)
end
