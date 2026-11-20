defmodule Tavern.Accounts.PasswordResetTest do
  use Tavern.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Accounts.LoginRateLimiter
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Topics
  alias Tavern.Chat.User
  alias Tavern.Chat.UserSession
  alias Tavern.ProductEvents
  alias Tavern.Repo

  @ip "203.0.113.7"

  setup do
    LoginRateLimiter.reset!()
    Bootstrap.ensure_seed_data!()
    :ok
  end

  describe "the emailed link" do
    test "sets a new password, and the old password stops working" do
      user = user_fixture(%{email: "forgetful@example.com"})
      token = reset_token(user)

      assert Accounts.get_user_by_password_reset_token(token).id == user.id

      assert {:ok, _} =
               Accounts.reset_user_password(token, %{"password" => "a brand new password"})

      assert Accounts.get_user_by_email_and_password(user.email, "a brand new password")
      assert is_nil(Accounts.get_user_by_email_and_password(user.email, "supersecurepass"))
    end

    test "ends every session of the member and none of anyone else's" do
      user = user_fixture()
      other = user_fixture()
      session = Accounts.generate_user_session_token(user)
      other_session = Accounts.generate_user_session_token(other)
      assert Accounts.get_user_by_session_token(session)

      token = reset_token(user)

      assert {:ok, _} =
               Accounts.reset_user_password(token, %{"password" => "a brand new password"})

      assert is_nil(Accounts.get_user_by_session_token(session))
      assert Accounts.get_user_by_session_token(other_session)
    end

    test "works once" do
      user = user_fixture()
      token = reset_token(user)

      assert {:ok, _} =
               Accounts.reset_user_password(token, %{"password" => "a brand new password"})

      assert {:error, :invalid} =
               Accounts.reset_user_password(token, %{"password" => "another new password"})

      assert is_nil(Accounts.get_user_by_password_reset_token(token))
      assert Accounts.get_user_by_email_and_password(user.email, "a brand new password")
    end

    test "fails after 1 hour" do
      user = user_fixture()
      token = reset_token(user)

      [row] =
        Repo.all(from(s in UserSession, where: s.context == "reset" and s.user_id == ^user.id))

      assert DateTime.diff(row.expires_at, DateTime.utc_now()) in 3_590..3_600

      from(s in UserSession, where: s.id == ^row.id)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      assert is_nil(Accounts.get_user_by_password_reset_token(token))

      assert {:error, :invalid} =
               Accounts.reset_user_password(token, %{"password" => "a brand new password"})

      assert Accounts.get_user_by_email_and_password(user.email, "supersecurepass")
    end

    test "a weak password is refused and the link still works" do
      user = user_fixture()
      token = reset_token(user)

      assert {:error, changeset} = Accounts.reset_user_password(token, %{"password" => "short"})

      assert {"should be at least %{count} character(s)", [count: 12] ++ _} =
               changeset.errors[:password]

      assert Accounts.get_user_by_email_and_password(user.email, "supersecurepass")

      assert {:ok, _} =
               Accounts.reset_user_password(token, %{"password" => "a brand new password"})
    end

    test "a newer request replaces the older link" do
      user = user_fixture()
      first = reset_token(user)
      second = reset_token(user)

      assert {:error, :invalid} =
               Accounts.reset_user_password(first, %{"password" => "a brand new password"})

      assert {:ok, _} =
               Accounts.reset_user_password(second, %{"password" => "a brand new password"})
    end

    test "fails once the account's email changes" do
      user = user_fixture()
      token = reset_token(user)

      user |> Ecto.Changeset.change(email: "elsewhere@example.com") |> Repo.update!()

      assert {:error, :invalid} =
               Accounts.reset_user_password(token, %{"password" => "a brand new password"})
    end

    test "spends the confirmation and email change links mailed before it" do
      user = unverified_user_fixture()
      :ok = Accounts.deliver_user_confirmation_instructions(user)
      assert_receive {:mail_captured, %{text: confirm_text}}
      [confirm] = Regex.run(~r{/users/confirm/(\S+)}, confirm_text, capture: :all_but_first)

      {:ok, :confirmation_sent} =
        Accounts.update_user_email(user, "supersecurepass", %{"email" => "moved@example.com"})

      assert_receive {:mail_captured, %{text: change_text}}
      [change] = Regex.run(~r{/users/confirm-email/(\S+)}, change_text, capture: :all_but_first)

      token = reset_token(user)

      assert {:ok, reset} =
               Accounts.reset_user_password(token, %{"password" => "a brand new password"})

      assert %DateTime{} = reset.confirmed_at

      assert {:error, :invalid} = Accounts.confirm_user(confirm)
      assert {:error, :invalid} = Accounts.update_user_email_from_token(change)

      assert Repo.aggregate(
               from(s in UserSession, where: s.user_id == ^user.id and s.context != "session"),
               :count
             ) == 0
    end
  end

  describe "verification by the link" do
    test "an unverified member who resets is verified, announced, and can send" do
      channel = channel_fixture(%{"name" => "Lobby"})
      user = unverified_user_fixture()
      assert Accounts.unverified?(user)
      assert {:error, _} = Chat.create_message(scope_for(user), channel.id, %{"body" => "hi"})

      ref = :telemetry_test.attach_event_handlers(self(), [ProductEvents.event()])
      on_exit(fn -> :telemetry.detach(ref) end)
      listen_to_server_events()
      token = reset_token(user)

      assert {:ok, reset} =
               Accounts.reset_user_password(token, %{"password" => "a brand new password"})

      assert %DateTime{} = reset.confirmed_at
      assert %DateTime{} = Repo.get!(User, user.id).confirmed_at
      refute Accounts.unverified?(Repo.preload(reset, :membership))
      assert {:ok, _} = Chat.create_message(scope_for(reset), channel.id, %{"body" => "hi"})

      user_id = user.id
      assert_receive {:server_event, {:email_confirmed, ^user_id}}
      event = ProductEvents.event()
      member = ProductEvents.pseudonym(user.id)
      assert_receive {^event, ^ref, %{}, %{event: "member.verified", member: ^member}}
    end

    test "a failed reset verifies nobody" do
      user = unverified_user_fixture()
      token = reset_token(user)

      assert {:error, _changeset} = Accounts.reset_user_password(token, %{"password" => "short"})
      assert is_nil(Repo.get!(User, user.id).confirmed_at)
    end

    test "a verified member keeps the same confirmed_at, and nothing is announced" do
      user = user_fixture()
      confirmed_at = Repo.get!(User, user.id).confirmed_at
      assert %DateTime{} = confirmed_at

      ref = :telemetry_test.attach_event_handlers(self(), [ProductEvents.event()])
      on_exit(fn -> :telemetry.detach(ref) end)
      listen_to_server_events()
      token = reset_token(user)

      assert {:ok, reset} =
               Accounts.reset_user_password(token, %{"password" => "a brand new password"})

      assert reset.confirmed_at == confirmed_at
      assert Repo.get!(User, user.id).confirmed_at == confirmed_at

      event = ProductEvents.event()
      refute_receive {:server_event, {:email_confirmed, _}}, 100
      refute_receive {^event, ^ref, %{}, %{event: "member.verified"}}, 100
    end
  end

  describe "asking for a link" do
    test "an email with no account gets the same reply and no mail" do
      assert :ok = Accounts.request_password_reset("nobody@example.com", @ip)
      refute_receive {:mail_captured, _}, 150
      assert Repo.aggregate(from(s in UserSession, where: s.context == "reset"), :count) == 0
    end

    test "a bot, a deleted account and an account with no password get no mail" do
      owner = owner_fixture()
      bot = bot_fixture(owner)
      Repo.update_all(from(u in User, where: u.id == ^bot.id), set: [email: "bot@example.com"])

      deleted = user_fixture(%{email: "gone@example.com"})
      {:ok, _} = Accounts.delete_account(deleted.id)

      for email <- ["bot@example.com", "gone@example.com"] do
        assert :ok = Accounts.request_password_reset(email, @ip)
      end

      refute_receive {:mail_captured, _}, 150
    end

    test "the address is matched without regard to case or surrounding spaces" do
      user_fixture(%{email: "mixed@example.com"})
      assert :ok = Accounts.request_password_reset("  Mixed@Example.com ", @ip)
      assert_receive {:mail_captured, %{to: "mixed@example.com"}}
    end

    test "sends nothing while no mail provider is set" do
      user = user_fixture()
      without_mail()

      assert :ok = Accounts.request_password_reset(user.email, @ip)
      refute_receive {:mail_captured, _}, 150
      refute Accounts.password_reset_available?()
    end

    test "counts against the login limiter, known email or not" do
      user = user_fixture()

      for email <- [user.email, "nobody@example.com"] do
        for _ <- 1..5, do: assert(:ok = Accounts.request_password_reset(email, @ip))
        assert {:error, {:rate_limited, seconds}} = Accounts.request_password_reset(email, @ip)
        assert seconds > 0
      end
    end

    test "mails one account at most 3 links per 15 minutes and still replies :ok" do
      user = user_fixture()

      for _ <- 1..4, do: assert(:ok = Accounts.request_password_reset(user.email, @ip))

      for _ <- 1..3, do: assert_receive({:mail_captured, %{to: to}} when to == user.email)
      refute_receive {:mail_captured, _}, 150
    end
  end

  # `Topics.broadcast_server/1` skips the process that sends, so the test hears the server topic
  # through a second process, which forwards each event as `{:server_event, event}`.
  defp listen_to_server_events do
    test = self()

    start_supervised!(
      {Task,
       fn ->
         :ok = Topics.subscribe_server()
         send(test, :listening)
         forward_server_events(test)
       end}
    )

    assert_receive :listening
  end

  defp forward_server_events(test) do
    receive do
      event -> send(test, {:server_event, event})
    end

    forward_server_events(test)
  end

  defp reset_token(user) do
    :ok =
      Accounts.request_password_reset(
        user.email,
        "198.51.100.#{System.unique_integer([:positive])}"
      )

    assert_receive {:mail_captured, %{to: to, text: text}}
    assert to == user.email
    [token] = Regex.run(~r{/users/reset-password/(\S+)}, text, capture: :all_but_first)
    token
  end

  defp without_mail do
    previous = Application.get_env(:tavern, Tavern.Mailer)
    Application.put_env(:tavern, Tavern.Mailer, provider: nil)
    on_exit(fn -> Application.put_env(:tavern, Tavern.Mailer, previous) end)
  end
end
