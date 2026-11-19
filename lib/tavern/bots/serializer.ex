defmodule Tavern.Bots.Serializer do
  @moduledoc false

  alias Ecto.Association.NotLoaded
  alias Tavern.Chat.Channel
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageEmbed
  alias Tavern.Chat.User

  def serialize_bot_user(%User{} = bot_user) do
    serialize_user(bot_user)
    |> Map.merge(%{
      email: bot_user.email,
      bio: bot_user.bio,
      role_ids: Enum.map(bot_user.member_roles || [], & &1.role_id),
      inserted_at: bot_user.inserted_at
    })
  end

  def serialize_user(%User{} = user) do
    %{
      id: user.id,
      username: user.username,
      display_name: user.display_name,
      bot: user.bot,
      system: user.system
    }
  end

  # Reads nothing. The message must come from a scoped read that preloads its author, channel
  # tree and reply target, which is what `Tavern.Chat` returns.
  def serialize_message(%Message{} = message) do
    %{
      id: message.id,
      channel_id: message.channel_id,
      author_id: message.author_id,
      reply_to_id: message.reply_to_id,
      body: message.body,
      kind: to_string(message.kind),
      metadata: message.metadata || %{},
      inserted_at: message.inserted_at,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      author: serialize_loaded_user(message.author),
      channel: serialize_channel_summary(message.channel),
      reply_to: serialize_message_reference(message.reply_to),
      embeds: serialize_embeds(message.embeds)
    }
  end

  def serialize_thread(%Channel{} = thread) do
    serialize_channel_summary(thread)
    |> Map.merge(%{
      parent_channel: serialize_channel_summary(thread.parent_channel),
      starter_message: serialize_message_reference(thread.starter_message)
    })
  end

  def moderation_response(updated_subject, moderation_case, action) do
    %{
      subject_user_id: updated_subject.id,
      moderation_case_id: moderation_case.id,
      action: action
    }
  end

  defp serialize_channel_summary(%Channel{} = channel) do
    %{
      id: channel.id,
      name: channel.name,
      slug: channel.slug,
      kind: to_string(channel.kind),
      topic: channel.topic,
      parent_channel_id: channel.parent_channel_id,
      starter_message_id: channel.starter_message_id,
      inserted_at: channel.inserted_at,
      archived_at: channel.archived_at,
      locked_at: channel.locked_at
    }
  end

  defp serialize_channel_summary(%NotLoaded{}), do: nil
  defp serialize_channel_summary(nil), do: nil

  defp serialize_message_reference(%Message{} = message) do
    %{
      id: message.id,
      channel_id: message.channel_id,
      author_id: message.author_id,
      reply_to_id: message.reply_to_id,
      body: message.body,
      kind: to_string(message.kind),
      metadata: message.metadata || %{},
      inserted_at: message.inserted_at,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      author: serialize_loaded_user(message.author)
    }
  end

  defp serialize_message_reference(%NotLoaded{}), do: nil
  defp serialize_message_reference(nil), do: nil

  # An embed's image is served by the app at `image_url`; the linked site is never contacted by a
  # client that only reads the message.
  defp serialize_embeds(embeds) when is_list(embeds) do
    Enum.map(embeds, fn %MessageEmbed{} = embed ->
      %{
        url: embed.url,
        kind: to_string(embed.kind),
        provider: embed.provider,
        title: embed.title,
        description: embed.description,
        site_name: embed.site_name,
        video_id: embed.video_id,
        image_url: serialize_image_url(embed.image_asset)
      }
    end)
  end

  defp serialize_embeds(%NotLoaded{}), do: nil

  defp serialize_image_url(%MediaAsset{} = asset), do: MediaAssets.asset_url(asset)
  defp serialize_image_url(_asset), do: nil

  defp serialize_loaded_user(%User{} = user), do: serialize_user(user)
  defp serialize_loaded_user(%NotLoaded{}), do: nil
  defp serialize_loaded_user(nil), do: nil
end
