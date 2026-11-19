defmodule Tavern.Chat.Mentions do
  @moduledoc """
  The `@name` mentions in a message body: who a message mentions, whether its author may mention
  a role, and the candidates the composer offers.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageRoleMention
  alias Tavern.Chat.MessageUserMention
  alias Tavern.Chat.Role
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @doc """
  The mention candidates for the composer: active members, then roles. A scope that is not an
  active member gets none, and a banned, removed or deleted user is not a candidate.
  """
  def composer_candidates(%Scope{} = scope) do
    if is_nil(Visibility.member(scope)), do: [], else: candidates()
  end

  @doc """
  Replaces the mention rows of a message with the ones its body names now. Runs inside the
  caller's transaction.
  """
  def sync(%Message{id: message_id, body: body}) do
    clear(message_id)

    mention_tokens = tokens_from_body(body)
    user_ids = MapSet.new(existing_user_ids(mention_tokens))
    role_ids = MapSet.new(existing_role_ids(mention_tokens))

    Enum.each(user_ids, fn user_id ->
      %MessageUserMention{}
      |> MessageUserMention.changeset(%{message_id: message_id, mentioned_user_id: user_id})
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:message_id, :mentioned_user_id])
    end)

    Enum.each(role_ids, fn role_id ->
      %MessageRoleMention{}
      |> MessageRoleMention.changeset(%{message_id: message_id, mentioned_role_id: role_id})
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:message_id, :mentioned_role_id])
    end)

    :ok
  end

  def clear(message_id) do
    from(mention in MessageUserMention, where: mention.message_id == ^message_id)
    |> Repo.delete_all()

    from(mention in MessageRoleMention, where: mention.message_id == ^message_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  `:ok` when the scope may mention every role the body of `attrs` names, else `{:error,
  changeset}`. A role that is not mentionable, or the default role, needs `:mention_everyone`.
  """
  def authorize(scope, channel_id, attrs) do
    role_ids = attrs |> mentioned_role_ids() |> Enum.uniq()

    disallowed_role_mentions =
      role_ids
      |> mentioned_roles()
      |> Enum.reject(&(&1.mentionable and not &1.is_default))

    cond do
      disallowed_role_mentions == [] ->
        :ok

      Visibility.can?(scope, :mention_everyone, %Channel{id: channel_id}) ->
        :ok

      true ->
        changeset =
          %Message{}
          |> Message.changeset(attrs)
          |> Ecto.Changeset.add_error(:body, "You do not have permission to mention that role.")

        {:error, changeset}
    end
  end

  defp candidates do
    users =
      User
      |> join(:inner, [user], membership in Membership, on: membership.user_id == user.id)
      |> where([user, membership], is_nil(user.deleted_at) and is_nil(membership.deactivated_at))
      |> order_by([user], asc: user.display_name, asc: user.username)
      |> limit(25)
      |> Repo.all()

    roles =
      target_roles()
      |> order_by([role], desc: role.position, asc: role.name)
      |> limit(10)
      |> Repo.all()

    user_entries =
      Enum.map(users, fn user ->
        %{
          id: user.id,
          label: user.username,
          description: user.display_name,
          type: "user"
        }
      end)

    role_entries =
      Enum.map(roles, fn role ->
        %{
          id: role.id,
          label: String.trim_leading(role.name, "@"),
          description: (role.is_default && "default role") || "role",
          type: "role"
        }
      end)

    user_entries ++ role_entries
  end

  defp existing_user_ids(mention_tokens) do
    usernames = Enum.uniq(mention_tokens)

    User
    |> where([user], user.username in ^usernames and is_nil(user.deleted_at))
    |> select([user], user.id)
    |> Repo.all()
  end

  # "@here" and "@everyone" name the default role whatever it is called; other tokens match role
  # names, so a role named "@everyone" is not a mass mention.
  defp existing_role_ids(mention_tokens) do
    {everyone_tokens, role_tokens} = Enum.split_with(mention_tokens, &everyone_token?/1)
    everyone? = everyone_tokens != []

    role_names =
      role_tokens
      |> Enum.flat_map(&role_name_candidates/1)
      |> Enum.uniq()

    target_roles()
    |> where([role], role.name in ^role_names or (^everyone? and role.is_default))
    |> select([role], role.id)
    |> Repo.all()
  end

  # The roles a message can mention. The Unverified role is not one: members hold it without a
  # `member_roles` row, so a mention could reach nobody, and it is not a group to address.
  defp target_roles, do: where(Role, [role], not role.is_unverified)

  defp tokens_from_body(body) when is_binary(body) do
    ~r/(?:^|[^[:alnum:]_])@([[:alnum:]_@-]+)/u
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp tokens_from_body(_body), do: []

  defp everyone_token?(token), do: String.trim_leading(token, "@") in ["here", "everyone"]

  defp role_name_candidates(token) do
    normalized = String.trim_leading(token, "@")
    [token, normalized, "@#{normalized}"]
  end

  defp mentioned_role_ids(attrs) do
    attrs
    |> Map.get("body")
    |> tokens_from_body()
    |> then(&existing_role_ids/1)
  end

  defp mentioned_roles([]), do: []

  defp mentioned_roles(role_ids) do
    valid_ids = Enum.filter(role_ids, &valid_binary_id?/1)

    Role
    |> where([role], role.id in ^valid_ids)
    |> Repo.all()
  end

  defp valid_binary_id?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_binary_id?(_value), do: false
end
