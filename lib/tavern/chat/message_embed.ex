defmodule Tavern.Chat.MessageEmbed do
  @moduledoc """
  A preview of one link in a message, fetched by the server after the message was written (see
  `Tavern.Chat.Embeds`). A `:link` embed shows a page's title, description, site name and image; a
  `:video` embed is a YouTube video, played only after a click. The server sets every field.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_embeds" do
    field(:position, :integer)
    field(:url, :string)
    field(:kind, Ecto.Enum, values: [:link, :video])
    field(:provider, :string)
    field(:title, :string)
    field(:description, :string)
    field(:site_name, :string)
    field(:video_id, :string)
    field(:fetched_at, :utc_datetime_usec)

    belongs_to(:message, Tavern.Chat.Message)
    belongs_to(:image_asset, Tavern.Chat.MediaAsset)
  end
end
