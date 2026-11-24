defmodule Tavern.Bots.Serializer do
  @moduledoc false

  alias Ecto.Association.NotLoaded
  alias Tavern.Chat.Attachments
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Emoji
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageAttachment
  alias Tavern.Chat.MessageEmbed
  alias Tavern.Chat.Question
  alias Tavern.Chat.Questions
  alias Tavern.Chat.Reaction
  alias Tavern.Chat.User
  alias Tavern.Repo

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

  def serialize_member(%User{} = user, roles) do
    serialize_user(user) |> Map.put(:role_ids, Enum.map(roles, & &1.id))
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
      embeds: serialize_embeds(message.embeds),
      attachments: serialize_attachments(message.attachments),
      question: serialize_question(message.question),
      reactions: serialize_reactions(message.reactions),
      mentions: serialize_mentions(message)
    }
  end

  @doc """
  The `reaction.added` / `reaction.removed` payload. `reaction` is the row inserted or deleted, with
  its emoji loaded.
  """
  def serialize_reaction(%Message{} = message, %Reaction{} = reaction) do
    %{
      message_id: message.id,
      channel_id: message.channel_id,
      user_id: reaction.user_id,
      emoji: serialize_emoji(reaction)
    }
  end

  # `[{emoji, count}]` in the order each emoji was first used, without who reacted.
  defp serialize_reactions(reactions) when is_list(reactions) do
    sorted = Enum.sort_by(reactions, &{&1.inserted_at, &1.id})
    counts = Enum.frequencies_by(sorted, &serialize_emoji/1)

    sorted
    |> Enum.map(&serialize_emoji/1)
    |> Enum.uniq()
    |> Enum.map(&%{emoji: &1, count: Map.fetch!(counts, &1)})
  end

  defp serialize_reactions(%NotLoaded{}), do: nil

  # A unicode emoji is its character; a custom emoji is `%{id, name}`.
  defp serialize_emoji(%Reaction{emoji_unicode: unicode}) when is_binary(unicode), do: unicode

  defp serialize_emoji(%Reaction{emoji_id: id, emoji: %Emoji{name: name}}),
    do: %{id: id, name: name}

  # `@everyone` and `@here` are stored as a mention of the default role, so they are reported as
  # `everyone`, not as a role id.
  defp serialize_mentions(%Message{user_mentions: users, role_mentions: roles})
       when is_list(users) and is_list(roles) do
    {everyone, named} = Enum.split_with(roles, & &1.mentioned_role.is_default)

    %{
      user_ids: Enum.map(users, & &1.mentioned_user_id),
      role_ids: Enum.map(named, & &1.mentioned_role_id),
      everyone: everyone != []
    }
  end

  defp serialize_mentions(_message), do: nil

  @doc """
  The `question.answered` payload: the question after the answer, and the answer itself (who,
  which options by id, label and kind, and the Other text). An anonymous poll's payload has
  `answer: nil`, so a reader learns only the new counts.
  """
  def serialize_question_answer(%Message{question: %Question{} = question} = message, answer) do
    options = Map.new(question.options, &{&1.id, &1})

    %{
      message_id: message.id,
      channel_id: message.channel_id,
      question: serialize_question(question),
      answer:
        unless question.anonymous do
          %{
            user_id: answer.user_id,
            option_ids: answer.option_ids,
            options: Enum.map(answer.option_ids, &serialize_option_ref(Map.fetch!(options, &1))),
            other_text: answer.other_text
          }
        end
    }
  end

  @doc """
  The `question.closed` payload: the final results and why it closed (`answered`, `time` or
  `closed_by_hand`).
  """
  def serialize_question_closed(%Message{question: %Question{} = question} = message, reason) do
    %{
      message_id: message.id,
      channel_id: message.channel_id,
      reason: to_string(reason),
      question: serialize_question(question)
    }
  end

  defp serialize_option_ref(option),
    do: %{id: option.id, label: option.label, kind: option.kind && to_string(option.kind)}

  # Results come from `Questions.results/2`, which leaves answerers out of an anonymous poll.
  defp serialize_question(%Question{} = question) do
    results = Questions.results(question, nil)

    %{
      id: question.id,
      kind: to_string(question.kind),
      multi_select: question.multi_select,
      anonymous: question.anonymous,
      allow_other: question.allow_other,
      closes_at: question.closes_at,
      closed_at: question.closed_at,
      closed: results.closed?,
      max_answers: question.max_answers,
      answerer_user_ids: question.answerer_user_ids,
      answerer_role_ids: question.answerer_role_ids,
      answer_count: results.answer_count,
      options:
        Enum.map(results.options, fn option ->
          %{
            id: option.id,
            label: option.label,
            kind: option.kind && to_string(option.kind),
            count: option.count,
            answerer_ids: option.answerers && Enum.map(option.answerers, & &1.id)
          }
        end),
      other:
        results.other &&
          %{
            count: results.other.count,
            answers:
              Enum.map(results.other.answers, &%{text: &1.text, user_id: &1.user && &1.user.id})
          }
    }
  end

  defp serialize_question(%NotLoaded{}), do: nil
  defp serialize_question(nil), do: nil

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
      name: channel_title(channel),
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

  # A message's channel comes without its starter message, which an unnamed thread's title needs.
  defp channel_title(%Channel{name: name}) when is_binary(name), do: name

  defp channel_title(%Channel{} = channel),
    do: channel |> Repo.preload(:starter_message) |> Channel.title()

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

  # `url` is the app's `/attachments` route, which answers only a signed-in member's browser
  # session today, not a bot token.
  defp serialize_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn %MessageAttachment{asset: %MediaAsset{} = asset} = attachment ->
      %{
        id: attachment.id,
        kind: to_string(attachment.kind),
        filename: Attachments.filename(asset),
        content_type: asset.content_type,
        byte_size: asset.byte_size,
        url: Attachments.url(attachment)
      }
    end)
  end

  defp serialize_attachments(%NotLoaded{}), do: nil

  defp serialize_image_url(%MediaAsset{} = asset), do: MediaAssets.asset_url(asset)
  defp serialize_image_url(_asset), do: nil

  defp serialize_loaded_user(%User{} = user), do: serialize_user(user)
  defp serialize_loaded_user(%NotLoaded{}), do: nil
  defp serialize_loaded_user(nil), do: nil
end
