defmodule Tavern.TestSupport do
  @moduledoc """
  Server-side test commands for E2E / Playwright tests.

  Every command receives a string-keyed payload (from `Jason.decode!/1`)
  and the current `Plug.Conn`. Commands return either:

    * `{:json, map}` – controller sends the map as JSON
    * `{:conn, conn}` – controller returns the conn as-is (e.g. login redirect)
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts
  alias Tavern.Accounts.LoginRateLimiter
  alias Tavern.Chat
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Message
  alias Tavern.Chat.User
  alias Tavern.Repo

  # ---------------------------------------------------------------------------
  # Public entry point
  # ---------------------------------------------------------------------------

  @doc """
  Dispatch a named command. Returns `{:json, data}` or `{:conn, conn}`.
  """
  def run_command(command, payload, conn)

  def run_command("login", payload, conn) do
    user = upsert_test_user!(payload)
    next = payload["next"] || "/"

    conn =
      conn
      |> Plug.Conn.put_session(:user_return_to, next)
      |> TavernWeb.UserAuth.log_in_user(user)

    {:conn, conn}
  end

  def run_command(command, payload, _conn) do
    {:json, execute(command, payload)}
  end

  # ---------------------------------------------------------------------------
  # Commands (all return plain maps)
  # ---------------------------------------------------------------------------

  defp execute("reset_login_rate_limiter", _payload) do
    LoginRateLimiter.reset!()
    %{success: true}
  end

  defp execute("upsert_user", payload) do
    user = upsert_test_user!(payload)
    %{user: user_payload(user)}
  end

  defp execute("clear_test_users", _payload) do
    test_user_ids =
      from(u in User,
        where: like(u.username, "test_%") or like(u.username, "e2e_%"),
        select: u.id
      )

    # Messages have on_delete: :restrict on author_id, so delete them first.
    {msg_count, _} =
      Repo.delete_all(from(m in Message, where: m.author_id in subquery(test_user_ids)))

    # Everything else cascades from users.
    {user_count, _} =
      Repo.delete_all(
        from(u in User, where: like(u.username, "test_%") or like(u.username, "e2e_%"))
      )

    %{success: true, deleted_users: user_count, deleted_messages: msg_count}
  end

  defp execute("set_server_name", payload) do
    name = payload["name"] || raise "name is required"

    {:ok, settings} = Chat.update_server_settings(owner_scope!(), %{"name" => name})

    %{server: %{name: settings.name, icon_url: Chat.server_icon_url(settings)}}
  end

  defp execute("set_registration_mode", payload) do
    mode = payload["mode"] || raise "mode is required"

    {:ok, settings} = Chat.update_server_settings(owner_scope!(), %{"registration_mode" => mode})

    %{server: %{registration_mode: Atom.to_string(settings.registration_mode)}}
  end

  defp execute("create_invite", payload) do
    scope = owner_scope!()

    channel =
      Chat.list_channels(scope)
      |> Enum.find(&(&1.slug == "general")) || raise "no general channel"

    {:ok, invite} =
      Chat.create_invite(
        scope,
        payload |> Map.take(["code", "max_uses"]) |> Map.put("channel_id", channel.id)
      )

    %{invite: %{code: invite.code, id: invite.id, channel_id: channel.id}}
  end

  defp execute("get_server_branding", _payload) do
    settings = Chat.get_server_settings()
    %{server: %{name: settings.name, icon_url: Chat.server_icon_url(settings)}}
  end

  defp execute("list_channels", _payload) do
    channels =
      Repo.all(from(channel in Channel, where: is_nil(channel.deleted_at)))
      |> Enum.filter(&(&1.kind in [:text, :announcement]))
      |> Enum.map(fn channel ->
        %{id: channel.id, name: channel.name, slug: channel.slug, kind: channel.kind}
      end)

    %{channels: channels}
  end

  # Creates a channel of `kind` (text by default) with this slug, unless one exists.
  defp execute("ensure_channel", payload) do
    slug = payload["slug"] || raise "slug is required"

    channel =
      case Repo.one(from(c in Channel, where: c.slug == ^slug and is_nil(c.deleted_at))) do
        %Channel{} = channel ->
          channel

        nil ->
          {:ok, channel} =
            Chat.create_channel(owner_scope!(), %{
              "name" => payload["name"] || slug,
              "slug" => slug,
              "kind" => payload["kind"] || "text"
            })

          channel
      end

    %{channel: %{id: channel.id, name: channel.name, slug: channel.slug, kind: channel.kind}}
  end

  defp execute("create_bot_with_token", payload) do
    scope = owner_scope!()

    username = payload["username"] || "test_bot_#{System.unique_integer([:positive])}"

    {:ok, bot_user} =
      Tavern.Bots.create_bot(scope, %{
        username: username,
        display_name: payload["display_name"] || username,
        email: payload["email"] || "#{username}@bot.local"
      })

    {:ok, %{token: token}} =
      Tavern.Bots.create_bot_token(scope, bot_user.id, %{
        label: payload["label"] || "k6-load-test"
      })

    %{
      bot: %{id: bot_user.id, username: bot_user.username},
      token: token
    }
  end

  defp execute("create_message", payload) do
    channel_slug = payload["channel_slug"] || raise "channel_slug is required"
    username = payload["username"] || raise "username is required"
    body = payload["body"] || raise "body is required"

    channel =
      Repo.one!(from(c in Channel, where: c.slug == ^channel_slug and is_nil(c.deleted_at)))

    user = Repo.get_by!(User, username: username)

    {:ok, message} = Chat.create_message(Accounts.user_scope(user), channel.id, %{"body" => body})

    %{
      message: %{
        id: message.id,
        channel_id: message.channel_id,
        body: message.body
      }
    }
  end

  defp execute("delete_account", payload) do
    username = payload["username"] || raise "username is required"
    ensure_safe_test_identity!("#{username}@example.com", username)

    {:ok, user} = Accounts.delete_account(Repo.get_by!(User, username: username).id)
    %{user: user_payload(user)}
  end

  # Sends the account a fresh confirmation link and returns the captured mail with the link's
  # path. This request subscribes to captured mail first, so the capture provider hands it the mail.
  defp execute("capture_verification_mail", payload) do
    email = payload["email"] || raise "email is required"
    user = Accounts.get_user_by_email(email) || raise "no account has #{email}"
    ensure_safe_test_identity!(email, user.username)

    :ok = Tavern.Mailer.Capture.subscribe()
    :ok = Accounts.deliver_user_confirmation_instructions(user)
    mail = Tavern.Mailer.Capture.await(email, 1_000) || raise "no mail was captured for #{email}"

    [link] = Regex.run(~r{https?://\S+/users/confirm/\S+}, mail.text)
    %{mail: %{to: mail.to, subject: mail.subject, path: URI.parse(link).path}}
  end

  defp execute("bulk_create_users", payload) do
    count = payload["count"] || 10
    offset = payload["offset"] || 0
    prefix = payload["prefix"] || "test_k6"
    password = payload["password"] || "LoadTest12345!"

    users =
      Enum.map(1..count, fn i ->
        n = offset + i
        username = "#{prefix}_#{n}"
        email = "#{username}@example.com"

        user =
          Accounts.get_user_by_email(email) ||
            register_test_user!(
              %{
                email: email,
                username: username,
                display_name: "Load User #{n}",
                password: password
              },
              true
            )

        %{id: user.id, email: user.email, username: user.username}
      end)

    %{users: users, count: length(users)}
  end

  defp execute("clear_k6_data", _payload) do
    k6_user_ids =
      from(u in User,
        where: like(u.username, "test_k6_%") or like(u.username, "test_bot_%"),
        where: u.system == false,
        select: u.id
      )

    {msg_count, _} =
      Repo.delete_all(from(m in Message, where: m.author_id in subquery(k6_user_ids)))

    {user_count, _} =
      Repo.delete_all(
        from(u in User,
          where: like(u.username, "test_k6_%") or like(u.username, "test_bot_%"),
          where: u.system == false
        )
      )

    %{success: true, deleted_users: user_count, deleted_messages: msg_count}
  end

  defp execute(command, _payload), do: raise("Command '#{command}' not understood.")

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp upsert_test_user!(payload) do
    email = payload["email"] || raise "email is required"
    username = payload["username"] || raise "username is required"

    ensure_safe_test_identity!(email, username)

    Accounts.get_user_by_email(email) ||
      payload
      |> normalize_user_attrs(email, username)
      |> register_test_user!(payload["verified"] != false)
  end

  # Test users are verified unless the payload says `"verified": false`: the test database is
  # seeded with the Unverified role and mail is captured, so verification is active, and most
  # specs need a member who can send.
  defp register_test_user!(attrs, verified?) do
    user = Accounts.register_user!(attrs)

    if verified?,
      do: user |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now()) |> Repo.update!(),
      else: user
  end

  defp normalize_user_attrs(payload, email, username) do
    %{
      email: email,
      username: username,
      display_name: payload["display_name"] || username,
      password: payload["password"] || "supersecurepass"
    }
  end

  defp ensure_safe_test_identity!(email, username) do
    unless String.ends_with?(email, "@example.com") do
      raise "test users must use an @example.com email"
    end

    unless String.starts_with?(username, "test_") or String.starts_with?(username, "e2e_") do
      raise "test usernames must start with 'test_' or 'e2e_'"
    end
  end

  defp owner_scope! do
    User
    |> join(:inner, [user], membership in Membership, on: membership.user_id == user.id)
    |> where([_user, membership], membership.is_owner == true)
    |> limit(1)
    |> Repo.one!()
    |> Accounts.user_scope()
  end

  defp user_payload(user) do
    %{id: user.id, email: user.email, username: user.username, display_name: user.display_name}
  end
end
