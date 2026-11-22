defmodule Tavern.Chat.MessageRows do
  @moduledoc """
  Row access to one message that the message, question, embed and thread writers share. It sits below
  all of them, so a writer can lock or reload a message without calling back into
  `Tavern.Chat.Messages`.
  """

  import Ecto.Query, only: [from: 2, preload: 2]

  alias Tavern.Chat.Message
  alias Tavern.Repo

  # What a write returns and broadcasts. Reads carry the mention lists too, so a bot reads whom a
  # message mentions from either.
  @write_preloads [
    :channel,
    :user_mentions,
    author: :avatar_asset,
    role_mentions: :mentioned_role,
    reactions: [emoji: :asset],
    reply_to: :author,
    embeds: :image_asset,
    question: [:options, answers: :user]
  ]

  @doc "The message with its write preloads, the shape every message broadcast carries."
  def reload_message(message_id) do
    Message
    |> preload(^@write_preloads)
    |> Repo.get!(message_id)
  end

  @doc "Locks a message row that is not deleted `FOR UPDATE`, or returns nil."
  def lock_live_message(message_id) do
    Repo.one(
      from(message in Message,
        where: message.id == ^message_id and is_nil(message.deleted_at),
        lock: "FOR UPDATE"
      )
    )
  end
end
