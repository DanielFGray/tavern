defmodule Tavern.Chat.Typing do
  @moduledoc """
  Who is typing in a channel or thread. Typing is ephemeral (`Tavern.Ephemeral`), so none of
  these calls takes a membership lock: a decision made now is the decision the announcement uses.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Ids
  alias Tavern.Chat.Topics
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Ephemeral
  alias Tavern.Repo

  @doc """
  Records that the scope's member is typing in a channel or thread. Needs `:send_messages`. A
  channel the scope may not view is `{:error, :not_found}`.
  """
  def announce(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ids.cast(channel_id) do
      if Visibility.can?(scope, :send_messages, %Channel{id: channel_id}) do
        _ = Ephemeral.put_typing(channel_id, scope.user_id)
        Topics.broadcast_channel(channel_id, {:typing_started, channel_id, scope.user_id})
        :ok
      else
        refusal(scope, channel_id)
      end
    end
  end

  def clear(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ids.cast(channel_id) do
      if Visibility.can?(scope, :view_channel, %Channel{id: channel_id}) do
        _ = Ephemeral.remove_typing(channel_id, scope.user_id)
        Topics.broadcast_channel(channel_id, {:typing_stopped, channel_id, scope.user_id})
        :ok
      else
        refusal(scope, channel_id)
      end
    end
  end

  @doc "Users other than the scope's own who are typing in a channel the scope may view."
  def list_users(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ids.cast(channel_id),
         true <- Visibility.can?(scope, :view_channel, %Channel{id: channel_id}) do
      channel_id
      |> Ephemeral.list_typing_user_ids()
      |> Enum.reject(&(&1 == scope.user_id))
      |> users()
    else
      _ -> []
    end
  end

  defp users([]), do: []

  defp users(user_ids) do
    User
    |> where([user], user.id in ^user_ids)
    |> where([user], is_nil(user.deleted_at))
    |> order_by([user], asc: user.display_name, asc: user.username)
    |> Repo.all()
  end

  defp refusal(scope, channel_id) do
    if Visibility.visible_channel(scope, channel_id),
      do: {:error, :forbidden},
      else: {:error, :not_found}
  end
end
