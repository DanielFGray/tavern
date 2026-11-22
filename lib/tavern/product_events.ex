defmodule Tavern.ProductEvents do
  @moduledoc """
  Turns committed chat and account changes into product events: one `:telemetry` event,
  `[:tavern, :product_event]`, per action. `Tavern.Observability` writes each one as a log
  record, which OpenObserve counts with SQL. `docs/design/observability.md` lists every event
  and its fields.

  Callers pass the change after its transaction commits, so an event never names a write that
  rolled back. `Tavern.Chat.Topics` passes every broadcast; the writes that broadcast nothing
  (sign-up, verification, moderation, deletion, sessions, invites, uploads) call `record/1` themselves.

  An event carries no message text, email or username. A member appears only as
  `pseudonym/1`, an HMAC of the member id. A thread appears only by its id: its title is text a
  member wrote, or the start of its starter message (`Channel.title/1`). Its channel, which
  always has a name, gives the name.

  A field with no value is left out, never nil: the OTLP log exporter would write `nil` as the
  string `"nil"`.
  """

  import Ecto.Query, only: [from: 2]

  alias Tavern.Chat.Channel
  alias Tavern.Chat.Invite
  alias Tavern.Chat.Message
  alias Tavern.Chat.ModerationCase
  alias Tavern.Chat.Question
  alias Tavern.Chat.Reaction
  alias Tavern.Chat.User
  alias Tavern.Repo

  @event [:tavern, :product_event]

  @doc "The `:telemetry` event name every product event uses."
  def event, do: @event

  @doc """
  Emits the product event for `fact`, a broadcast tuple from `Tavern.Chat.Topics` or one of the
  tuples below. Any other broadcast (typing, embeds, re-renders, sidebar reloads) is no product
  event, and returns `:ok` with nothing emitted.

  - `{:member_signed_up, user, invited?}`
  - `{:member_verified, user_id}`: the account confirmed its first address
  - `{:member_moderated, moderation_case}`
  - `{:member_deletion_scheduled, actor_id, user_id}`
  - `{:member_rejoined, user_id}`
  - `{:member_deleted, user_id, actor_id}`: `actor_id` is `nil` for the deletion sweep
  - `{:session_seen, user_id}`
  - `{:invite_created, invite}`: the invite with its channel preloaded
  - `{:upload_created, user_id, kind}`
  """
  def record(fact)

  def record({:member_signed_up, %User{} = user, invited?}),
    do: emit("member.signed_up", %{member: pseudonym(user.id), invited: invited?})

  def record({:member_verified, user_id}),
    do: emit("member.verified", %{member: pseudonym(user_id)})

  def record({:member_moderated, %ModerationCase{} = moderation_case}) do
    emit("member.moderated", %{
      action: Atom.to_string(moderation_case.action_type),
      actor: pseudonym(moderation_case.actor_user_id),
      member: pseudonym(moderation_case.subject_user_id)
    })
  end

  def record({:member_deletion_scheduled, actor_id, user_id}),
    do:
      emit("member.deletion_scheduled", %{actor: pseudonym(actor_id), member: pseudonym(user_id)})

  def record({:member_rejoined, user_id}),
    do: emit("member.rejoined", %{member: pseudonym(user_id)})

  def record({:member_deleted, user_id, actor_id}) do
    by =
      cond do
        is_nil(actor_id) -> "sweep"
        actor_id == user_id -> "self"
        true -> "moderator"
      end

    emit("member.deleted", %{member: pseudonym(user_id), by: by})
  end

  def record({:session_seen, user_id}),
    do: emit("session.seen", %{member: pseudonym(user_id)})

  def record({:invite_created, %Invite{channel: %Channel{} = channel} = invite}),
    do: emit("invite.created", Map.put(place(channel), :actor, pseudonym(invite.inviter_id)))

  def record({:upload_created, user_id, kind}),
    do: emit("upload.created", %{member: pseudonym(user_id), kind: Atom.to_string(kind)})

  def record({:message_created, %Message{author: %User{} = author} = message}) do
    emit(
      "message.created",
      message.channel
      |> place()
      |> Map.merge(%{
        member: pseudonym(author.id),
        author_kind: author_kind(author),
        message_kind: Atom.to_string(message.kind),
        question: question_kind(message.question)
      })
    )
  end

  def record({event, %Message{} = message, %Reaction{} = reaction})
      when event in [:reaction_added, :reaction_removed] do
    name = if event == :reaction_added, do: "reaction.added", else: "reaction.removed"

    emit(
      name,
      message.channel
      |> place()
      |> Map.merge(%{
        member: pseudonym(reaction.user_id),
        emoji_kind: if(reaction.emoji_id, do: "custom", else: "unicode")
      })
    )
  end

  def record({:question_answered, %Message{} = message, %{user_id: user_id}}) do
    emit(
      "question.answered",
      message.channel
      |> place()
      |> Map.merge(%{member: pseudonym(user_id), question: question_kind(message.question)})
    )
  end

  def record({:question_closed, %Message{} = message, reason}) do
    emit(
      "question.closed",
      message.channel
      |> place()
      |> Map.merge(%{reason: Atom.to_string(reason), question: question_kind(message.question)})
    )
  end

  def record({:channel_created, %Channel{} = channel}) do
    if Channel.thread?(channel) do
      emit("thread.created", Map.put(place(channel), :member, pseudonym(channel.created_by_id)))
    else
      emit("channel.created", place(channel))
    end
  end

  def record(_broadcast), do: :ok

  @doc """
  The member's id as it appears in product events: the first 16 bytes, hex encoded, of an
  HMAC-SHA256 of the id under a key derived from the endpoint's `secret_key_base`. It is stable
  for as long as that secret is, and cannot be turned back into the id without it.
  """
  def pseudonym(user_id) when is_binary(user_id) do
    :crypto.mac(:hmac, :sha256, pseudonym_key(), user_id)
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp pseudonym_key do
    secret_key_base = Application.fetch_env!(:tavern, TavernWeb.Endpoint)[:secret_key_base]
    :crypto.mac(:hmac, :sha256, secret_key_base, "tavern product event member pseudonym")
  end

  defp emit(name, fields) do
    :telemetry.execute(@event, %{}, Map.put(fields, :event, name))
  end

  # Where an event happened: the channel, and for a thread also `thread_id`. A thread is named by
  # its channel (one primary-key read of its parent), never by its own title. A text channel's
  # parent is its category, which holds no messages, so a channel names itself.
  defp place(%Channel{} = channel) do
    if Channel.thread?(channel) do
      {id, name, kind} =
        Repo.one!(
          from(parent in Channel,
            where: parent.id == ^channel.parent_channel_id,
            select: {parent.id, parent.name, parent.kind}
          )
        )

      %{
        thread_id: channel.id,
        channel_id: id,
        channel_name: name,
        channel_kind: Atom.to_string(kind)
      }
    else
      %{
        channel_id: channel.id,
        channel_name: channel.name,
        channel_kind: Atom.to_string(channel.kind)
      }
    end
  end

  # A message's question kind (`poll`, `ask`, `permission`), or `none` for a plain message. Event
  # fields are never nil.
  defp question_kind(%Question{kind: kind}), do: Atom.to_string(kind)
  defp question_kind(_question), do: "none"

  defp author_kind(%User{bot: true}), do: "bot"
  defp author_kind(%User{system: true}), do: "system"
  defp author_kind(%User{}), do: "person"
end
