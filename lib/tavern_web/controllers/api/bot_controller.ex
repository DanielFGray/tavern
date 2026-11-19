defmodule TavernWeb.API.BotController do
  use TavernWeb, :controller

  alias Tavern.Accounts.Scope
  alias Tavern.Bots
  alias Tavern.Chat
  alias Tavern.Chat.Topics
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias TavernWeb.API.ErrorHelpers

  @reauthorize_interval 20_000

  # The bot context decides every write in its own transaction, so a write answers `forbidden`
  # when the scope may not manage bots. The two reads keep their own check, so a member without
  # manage_bots gets 403 rather than an empty list or a not-found.
  def index(conn, _params) do
    scope = conn.assigns.current_scope

    if Bots.can_manage_bots?(scope) do
      json(conn, TavernWeb.API.BotJSON.index(%{bots: Bots.list_controllable_bot_users(scope)}))
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def create(conn, %{"bot" => bot_params}) when is_map(bot_params) do
    case Bots.create_bot(conn.assigns.current_scope, bot_params) do
      {:ok, bot} ->
        conn
        |> put_status(:created)
        |> json(TavernWeb.API.BotJSON.show(%{bot: bot}))

      {:error, :forbidden} ->
        forbidden(conn)

      {:error, changeset} ->
        ErrorHelpers.render_changeset_error(conn, :unprocessable_entity, "invalid_bot", changeset)
    end
  end

  def create(conn, _params), do: ErrorHelpers.render_invalid_body(conn)

  def update(conn, %{"id" => id, "bot" => bot_params}) when is_map(bot_params) do
    case Bots.update_bot(conn.assigns.current_scope, id, bot_params) do
      {:ok, updated_bot} ->
        json(conn, TavernWeb.API.BotJSON.show(%{bot: updated_bot}))

      {:error, :forbidden} ->
        forbidden(conn)

      {:error, :not_found} ->
        bot_not_found(conn)

      {:error, changeset} ->
        ErrorHelpers.render_changeset_error(conn, :unprocessable_entity, "invalid_bot", changeset)
    end
  end

  def update(conn, _params), do: ErrorHelpers.render_invalid_body(conn)

  def delete(conn, %{"id" => id}) do
    case Bots.revoke_bot(conn.assigns.current_scope, id) do
      {:ok, revoked_bot} -> json(conn, TavernWeb.API.BotJSON.show(%{bot: revoked_bot}))
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> bot_not_found(conn)
    end
  end

  def create_token(conn, %{"id" => id, "token" => token_params}) when is_map(token_params) do
    case Bots.create_bot_token(conn.assigns.current_scope, id, token_params) do
      {:ok, token_info} ->
        conn
        |> put_status(:created)
        |> json(TavernWeb.API.BotJSON.token(%{bot: token_info.bot, token: token_info}))

      {:error, :forbidden} ->
        forbidden(conn)

      {:error, :not_found} ->
        bot_not_found(conn)

      {:error, changeset} ->
        ErrorHelpers.render_changeset_error(
          conn,
          :unprocessable_entity,
          "invalid_bot_token",
          changeset
        )
    end
  end

  def create_token(conn, _params), do: ErrorHelpers.render_invalid_body(conn)

  def list_tokens(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    if Bots.can_manage_bots?(scope) do
      case Bots.list_controllable_bot_tokens(scope, id) do
        {:ok, tokens} -> json(conn, TavernWeb.API.BotJSON.tokens(%{tokens: tokens}))
        {:error, :not_found} -> bot_not_found(conn)
      end
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def revoke_token(conn, %{"id" => id}) do
    case Bots.revoke_bot_token(conn.assigns.current_scope, id) do
      {:ok, revoked_token} ->
        json(conn, %{data: %{id: revoked_token.id, revoked_at: revoked_token.revoked_at}})

      {:error, :forbidden} ->
        forbidden(conn)

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot token not found.")

      {:error, changeset} ->
        ErrorHelpers.render_changeset_error(
          conn,
          :unprocessable_entity,
          "invalid_bot_token",
          changeset
        )
    end
  end

  # The membership can end between the auth plug and this call, so the member is read here too.
  def events(conn, _params) do
    case Bots.acting_member(conn.assigns.current_bot_scope) do
      {:ok, bot_user} -> open_events(conn, bot_user)
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  defp open_events(conn, bot_user) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    :ok = Topics.subscribe_server()
    scope = conn.assigns.current_bot_scope
    subscribed = sync_subscriptions(MapSet.new(), scope)

    initial =
      "event: ready\ndata: #{Jason.encode!(%{bot: Bots.serialize_bot_user(bot_user)})}\n\n"

    case chunk(conn, initial) do
      {:ok, conn} ->
        schedule_reauthorize()

        stream_events(conn, %{
          token: bearer_token(conn),
          bot_user: bot_user,
          scope: scope,
          subscribed: subscribed
        })

      {:error, _reason} ->
        conn
    end
  end

  # Message events arrive only from the channel topics in `state.subscribed`: the channels and
  # threads the bot can view. A server event re-syncs that set before anything is emitted, so a bot
  # that has received `thread.created` is already subscribed to that thread.
  #
  # A `:reauthorize` message, sent every `@reauthorize_interval`, re-checks the bearer token and
  # re-syncs subscriptions from the fresh bot user. It sits in the mailbox like any event, so the
  # check runs under steady traffic too. The loop ends when the token no longer authenticates the
  # same bot or when a write to the client fails.
  defp stream_events(conn, state) do
    receive do
      message -> act(dispatch(message), conn, state)
    end
  end

  @doc """
  Decides what one mailbox message asks of the stream, without doing it:

    * `{:emit, event_name, payload}` writes an event to the client;
    * `:resync` recomputes the subscribed channels;
    * `{:thread_created, thread}` resyncs, then emits `thread.created` if the bot now views it;
    * `:reauthorize` re-checks the token;
    * `:ignore` is a message the stream does not use.
  """
  def dispatch({:message_created, message}),
    do: {:emit, "message.created", Bots.serialize_message(message)}

  def dispatch({:message_updated, message}),
    do: {:emit, "message.updated", Bots.serialize_message(message)}

  def dispatch({:message_deleted, message}),
    do: {:emit, "message.deleted", Bots.serialize_message(message)}

  def dispatch({:reaction_added, message, reaction}),
    do: {:emit, "reaction.added", Bots.serialize_reaction(message, reaction)}

  def dispatch({:reaction_removed, message, reaction}),
    do: {:emit, "reaction.removed", Bots.serialize_reaction(message, reaction)}

  def dispatch({:poll_voted, message, vote}),
    do: {:emit, "poll.voted", Bots.serialize_poll_vote(message, vote)}

  def dispatch({:poll_closed, message, reason}),
    do: {:emit, "poll.closed", Bots.serialize_poll_closed(message, reason)}

  def dispatch({:channel_created, %{kind: :thread_public} = thread}),
    do: {:thread_created, thread}

  def dispatch({:channel_created, _channel}), do: :resync
  def dispatch({event, _channel}) when event in [:channel_updated, :channel_deleted], do: :resync
  def dispatch(:roles_changed), do: :resync
  def dispatch(:reauthorize), do: :reauthorize
  def dispatch(_other), do: :ignore

  defp act({:emit, event_name, payload}, conn, state), do: emit(conn, event_name, payload, state)
  defp act(:resync, conn, state), do: stream_events(conn, resync(state))
  defp act(:reauthorize, conn, state), do: reauthorize(conn, state)
  defp act(:ignore, conn, state), do: stream_events(conn, state)

  defp act({:thread_created, thread}, conn, state) do
    state = resync(state)

    if MapSet.member?(state.subscribed, thread.id) do
      emit(conn, "thread.created", Bots.serialize_thread(thread), state)
    else
      stream_events(conn, state)
    end
  end

  # A banned or removed bot keeps a valid token, so the member read is part of the check: a
  # bot with no active membership is closed like a revoked token.
  defp reauthorize(conn, state) do
    with {:ok, %Scope{user_id: id} = scope} when id == state.bot_user.id <-
           fetch_scope(state.token),
         %User{} = bot_user <- Visibility.member(scope) do
      state = resync(%{state | bot_user: bot_user})

      case chunk(conn, ": keepalive\n\n") do
        {:ok, conn} ->
          schedule_reauthorize()
          stream_events(conn, state)

        {:error, _reason} ->
          conn
      end
    else
      _revoked ->
        case chunk(conn, "event: closed\ndata: {\"reason\":\"token_revoked\"}\n\n") do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end
    end
  end

  defp emit(conn, event_name, payload, state) do
    case chunk(conn, "event: #{event_name}\ndata: #{Jason.encode!(payload)}\n\n") do
      {:ok, conn} -> stream_events(conn, state)
      {:error, _reason} -> conn
    end
  end

  defp schedule_reauthorize, do: Process.send_after(self(), :reauthorize, @reauthorize_interval)

  defp resync(state),
    do: %{state | subscribed: sync_subscriptions(state.subscribed, state.scope)}

  defp sync_subscriptions(subscribed, scope) do
    wanted =
      scope
      |> Chat.list_channels()
      |> Enum.reject(&(&1.kind == :category))
      |> MapSet.new(& &1.id)

    Topics.sync_channel_subscriptions(subscribed, wanted)
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp fetch_scope(nil), do: {:error, :unauthorized}
  defp fetch_scope(token), do: Bots.get_bot_scope_by_token(token)

  defp bot_not_found(conn),
    do: ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot not found.")

  defp forbidden(conn),
    do: ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage this bot.")

  # The same answer RequireBotAuth gives a token it refuses, so a client sees one auth failure.
  defp unauthorized(conn),
    do:
      ErrorHelpers.render_error(
        conn,
        :unauthorized,
        "unauthorized",
        "Valid bot bearer token required."
      )
end
