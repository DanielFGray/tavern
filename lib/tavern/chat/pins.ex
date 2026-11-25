defmodule Tavern.Chat.Pins do
  @moduledoc """
  Pinned messages (docs/design/pins.md). A member with `pin_messages` in a channel or thread pins
  its messages, up to 50 per conversation. A message is pinned while its `pinned_at` is set;
  deleting the message clears it. Pinning also posts a pin line (`Message.pin_line?/1`) in the
  conversation, written by the member who pinned; unpinning posts nothing.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Ids
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageRows
  alias Tavern.Chat.Messages
  alias Tavern.Chat.SendLimit
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @limit 50

  def limit, do: @limit

  @doc """
  Pins a message and posts the pin line. Returns `{:ok, %{message: message, line: line}}`; the
  caller's own session hears no broadcast, so it shows both itself. Pinning a pinned message
  changes nothing and posts no line (`line: nil`). It is `{:error, :pin_limit}` when the
  conversation holds #{@limit} pins. A message the scope may not view is `{:error, :not_found}`;
  one it may not pin, or a pin line, is `{:error, :forbidden}`.
  """
  def pin_message(%Scope{} = scope, message_id) do
    write(scope, message_id, fn
      %Message{pinned_at: %DateTime{}} = message ->
        {:ok, {message, nil}}

      message ->
        lock_conversation_pins!(message.channel_id)

        # The pin line is a message, so it counts toward the member's send limit. Without that,
        # pin and unpin in a loop would post lines without bound.
        with :ok <- under_cap(message.channel_id),
             :ok <- SendLimit.admit(scope.user_id) do
          pinned =
            message |> Ecto.Changeset.change(pinned_at: DateTime.utc_now()) |> Repo.update!()

          line =
            Repo.insert!(%Message{
              channel_id: message.channel_id,
              author_id: scope.user_id,
              kind: :pin,
              reply_to_id: message.id,
              body: "pinned a message."
            })

          {:ok, {pinned, line}}
        end
    end)
    |> case do
      {:ok, {message, line}} -> {:ok, %{message: message, line: line}}
      error -> error
    end
  end

  @doc """
  Unpins a message. Unpinning one that is not pinned changes nothing. Refusals follow
  `pin_message/2`.
  """
  def unpin_message(%Scope{} = scope, message_id) do
    write(scope, message_id, fn
      %Message{pinned_at: nil} = message ->
        {:ok, {message, nil}}

      message ->
        {:ok, {message |> Ecto.Changeset.change(pinned_at: nil) |> Repo.update!(), nil}}
    end)
    |> case do
      {:ok, {message, nil}} -> {:ok, message}
      error -> error
    end
  end

  @doc """
  The pinned messages of channel or thread `channel_id`, most recently pinned first, each with
  the preloads a message broadcast carries. A conversation the scope may not view is
  `{:error, :not_found}`.
  """
  def list_pins(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ids.cast(channel_id),
         true <- Visibility.can?(scope, :view_channel, %Channel{id: channel_id}) do
      pins =
        Message
        |> where([message], message.channel_id == ^channel_id and not is_nil(message.pinned_at))
        |> Message.where_listed()
        |> order_by([message], desc: message.pinned_at, desc: message.id)
        |> preload(^MessageRows.write_preloads())
        |> Repo.all()

      {:ok, pins}
    else
      _ -> {:error, :not_found}
    end
  end

  # Decides `:pin_message`, locks the message and applies `change`, which returns the message and
  # the pin line it wrote, if any. Only a changed message is broadcast.
  defp write(scope, message_id, change) do
    with {:ok, message_id} <- Ids.cast(message_id) do
      Repo.transact(fn ->
        with :ok <- Visibility.authorize_write(scope, :pin_message, %Message{id: message_id}),
             %Message{} = message <- MessageRows.lock_live_message(message_id),
             false <- Message.pin_line?(message),
             {:ok, {changed, line}} <- change.(message) do
          {:ok, {changed != message, MessageRows.reload_message(changed.id), line}}
        else
          nil -> {:error, :not_found}
          true -> {:error, :forbidden}
          error -> error
        end
      end)
      |> publish()
    end
  end

  defp publish({:ok, {changed?, message, line}}) do
    if changed?, do: Topics.broadcast_channel(message.channel_id, {:message_updated, message})

    line =
      if line do
        {:ok, line} = Messages.publish_message({MessageRows.reload_message(line.id), []})
        line
      end

    {:ok, {message, line}}
  end

  defp publish({:error, reason}), do: {:error, reason}

  # Two pins in one conversation decide the cap one after the other. The lock is per conversation,
  # so it never waits on sends or on pins elsewhere.
  defp lock_conversation_pins!(channel_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["pins:" <> channel_id])
  end

  defp under_cap(channel_id) do
    if pin_count(channel_id) < @limit, do: :ok, else: {:error, :pin_limit}
  end

  defp pin_count(channel_id) do
    Repo.aggregate(
      from(message in Message,
        where:
          message.channel_id == ^channel_id and not is_nil(message.pinned_at) and
            is_nil(message.deleted_at)
      ),
      :count
    )
  end
end
