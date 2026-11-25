defmodule Tavern.Chat.OwnerDirectMessages do
  @moduledoc """
  The owner's audited reading of direct messages (docs/design/direct-messages.md, Owner
  reading). It applies only on a server whose `direct_message_privacy` is `:owner_can_read`.

  This is not visibility. `Tavern.Chat.Visibility` still shows a DM to its two participants only,
  so a DM the owner read never enters the owner's search, lists or sidebar. These functions read
  the rows themselves, and every read of messages writes an audit entry first.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts
  alias Tavern.Accounts.Scope
  alias Tavern.Chat.AuditLog
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Ids
  alias Tavern.Chat.Message
  alias Tavern.Chat.ServerConfig
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @page_size 50

  @doc """
  Whether the scope may read direct messages as the owner: the server is `:owner_can_read`, and
  the scope is a person (not a bot token) who owns the server now.
  """
  def owner_reader?(%Scope{bot_token_id: nil} = scope) do
    ServerConfig.get_server_settings().direct_message_privacy == :owner_can_read and
      Accounts.owner?(Visibility.member(scope))
  end

  def owner_reader?(%Scope{}), do: false

  @doc """
  Every live DM with its two participants and the time of its last message, most recent first:
  `{:ok, [%{dm: channel, participants: [user, user], last_activity_at: datetime}]}`. It reads no
  message, so it writes no audit entry. Anyone but an owner reader gets `{:error, :forbidden}`.
  """
  def list_direct_messages_for_owner(%Scope{} = scope) do
    if owner_reader?(scope) do
      rows =
        from(channel in Channel,
          left_join: message in Message,
          on: message.channel_id == channel.id,
          where: channel.kind == :direct and is_nil(channel.deleted_at),
          group_by: channel.id,
          order_by: [
            desc: coalesce(max(message.inserted_at), channel.inserted_at),
            desc: channel.id
          ],
          select: {channel, coalesce(max(message.inserted_at), channel.inserted_at)}
        )
        |> Repo.all()

      users = participants_by_id(Enum.map(rows, &elem(&1, 0)))

      {:ok,
       Enum.map(rows, fn {dm, last_activity_at} ->
         %{dm: dm, participants: participants(dm, users), last_activity_at: last_activity_at}
       end)}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  One page of DM `dm_id`, oldest message first:
  `{:ok, %{dm: channel, participants: [user, user], messages: messages, next_cursor: cursor}}`.
  The page holds the newest messages before `cursor` (`nil` for the newest page). `next_cursor`
  reads the page before this one, and is `nil` on the first page of the DM.

  Every call writes the audit entry `view_direct_message` before it reads, in the same
  transaction, so no page is read without an entry. A deleted message is not shown. The read
  marks nothing read and subscribes to nothing. Anyone but an owner reader, and an id that is not
  a live DM, gets `{:error, :forbidden}` or `{:error, :not_found}`.
  """
  def read_direct_message_for_owner(%Scope{} = scope, dm_id, cursor \\ nil) do
    Repo.transact(fn ->
      with true <- owner_reader?(scope) || {:error, :forbidden},
           {:ok, dm_id} <- Ids.cast(dm_id),
           %Channel{} = dm <- live_direct_message(dm_id) || {:error, :not_found} do
        participants = participants(dm, participants_by_id([dm]))
        record_reading!(scope, dm, participants)
        {page, next_cursor} = page(dm.id, cursor)

        {:ok, %{dm: dm, participants: participants, messages: page, next_cursor: next_cursor}}
      else
        {:error, _reason} = error -> error
      end
    end)
  end

  defp live_direct_message(dm_id) do
    Repo.one(
      from(channel in Channel,
        where: channel.id == ^dm_id and channel.kind == :direct and is_nil(channel.deleted_at)
      )
    )
  end

  # `AuditLogLine` reads only preloaded rows, so the entry keeps the usernames as they are now
  # beside the ids, as role entries keep `role_name`.
  defp record_reading!(scope, dm, participants) do
    AuditLog.record!(scope.user_id, "view_direct_message", nil, {"direct_message", dm.id},
      metadata: %{
        "participant_ids" => Enum.map(participants, & &1.id),
        "participant_usernames" => Enum.map(participants, & &1.username)
      }
    )
  end

  defp page(dm_id, cursor) do
    messages =
      from(message in Message,
        where: message.channel_id == ^dm_id and is_nil(message.deleted_at),
        order_by: [desc: message.inserted_at, desc: message.id],
        limit: ^(@page_size + 1),
        preload: [author: :avatar_asset, attachments: :asset]
      )
      |> before_cursor(cursor)
      |> Repo.all()

    {page, rest} = Enum.split(messages, @page_size)
    next_cursor = if rest != [], do: cursor_of(List.last(page))

    {Enum.reverse(page), next_cursor}
  end

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, {inserted_at, id}) do
    where(
      query,
      [message],
      message.inserted_at < ^inserted_at or
        (message.inserted_at == ^inserted_at and message.id < ^id)
    )
  end

  defp cursor_of(%Message{inserted_at: inserted_at, id: id}), do: {inserted_at, id}

  defp participants_by_id(dms) do
    ids = Enum.flat_map(dms, &Channel.participant_ids/1)

    from(user in User, where: user.id in ^ids, preload: [:avatar_asset])
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp participants(dm, users), do: Enum.map(Channel.participant_ids(dm), &Map.fetch!(users, &1))
end
