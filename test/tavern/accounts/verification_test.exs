defmodule Tavern.Accounts.VerificationTest do
  use Tavern.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Accounts.LoginRateLimiter
  alias Tavern.Accounts.Scope
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Membership
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Role
  alias Tavern.Chat.User
  alias Tavern.Chat.UserSession
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  setup do
    LoginRateLimiter.reset!()
    %{unverified_role: unverified_role} = Bootstrap.ensure_seed_data!()
    channel = channel_fixture(%{"name" => "Lobby"})
    %{unverified_role: unverified_role, channel: channel}
  end

  describe "confirmation links" do
    test "a link verifies once and fails a second time" do
      user = unverified_user_fixture()
      assert Accounts.unverified?(user)

      token = confirmation_token(user)

      assert {:ok, confirmed} = Accounts.confirm_user(token)
      assert %DateTime{} = confirmed.confirmed_at
      refute Accounts.unverified?(Repo.preload(confirmed, :membership))

      assert {:error, :invalid} = Accounts.confirm_user(token)
    end

    test "a link fails after it expires" do
      user = unverified_user_fixture()
      token = confirmation_token(user)

      from(session in UserSession, where: session.user_id == ^user.id)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      assert {:error, :invalid} = Accounts.confirm_user(token)
      assert is_nil(Repo.get!(User, user.id).confirmed_at)
    end

    test "a link fails once the account's email is no longer the address it was sent to" do
      user = unverified_user_fixture()
      token = confirmation_token(user)

      user |> Ecto.Changeset.change(email: "elsewhere@example.com") |> Repo.update!()

      assert {:error, :invalid} = Accounts.confirm_user(token)
    end

    test "resending is rate limited" do
      user = unverified_user_fixture()

      for _ <- 1..3 do
        assert :ok = Accounts.resend_user_confirmation(user)
        assert_received {:mail_captured, %{to: to}}
        assert to == user.email
      end

      assert {:error, {:rate_limited, seconds}} = Accounts.resend_user_confirmation(user)
      assert seconds > 0
      refute_received {:mail_captured, _}
    end

    test "a verified member needs no resend" do
      user = user_fixture()
      assert {:error, :not_needed} = Accounts.resend_user_confirmation(user)
      refute_received {:mail_captured, _}
    end
  end

  describe "the Unverified role" do
    test "an unverified member can read but cannot send, react or start threads", ctx do
      author = user_fixture()
      message = message_fixture(ctx.channel, author)
      user = unverified_user_fixture()
      scope = scope_for(user)

      assert Visibility.can?(scope, :view_channel, ctx.channel)
      assert {:ok, [_ | _]} = Chat.list_messages(scope, ctx.channel.id)

      assert {:error, _} = Chat.create_message(scope, ctx.channel.id, %{"body" => "hello"})
      refute Visibility.can?(scope, :add_reactions, message)
      refute Visibility.can?(scope, :create_public_threads, ctx.channel)
      refute Visibility.can?(scope, :mention_everyone, ctx.channel)
    end

    test "a member who also holds a role that allows sending can send (allow wins)", ctx do
      user = unverified_user_fixture()
      speaker = role_fixture(%{permissions: PermissionBits.flag(:send_messages)})
      member_role_fixture(user, speaker)

      assert {:ok, _message} =
               Chat.create_message(scope_for(user), ctx.channel.id, %{"body" => "hello"})
    end

    test "an overwrite on the Unverified role applies to unverified members only", ctx do
      user = unverified_user_fixture()
      verified = user_fixture()
      other = channel_fixture(%{"name" => "Other"})

      channel_permission_overwrite_fixture(ctx.channel, %{
        role_id: ctx.unverified_role.id,
        allow_permissions: PermissionBits.flag(:send_messages),
        deny_permissions: 0
      })

      channel_permission_overwrite_fixture(other, %{
        role_id: ctx.unverified_role.id,
        allow_permissions: 0,
        deny_permissions: PermissionBits.flag(:view_channel)
      })

      assert Visibility.can?(scope_for(user), :send_messages, ctx.channel)
      refute Visibility.can?(scope_for(user), :view_channel, other)
      assert Visibility.can?(scope_for(verified), :view_channel, other)
    end

    test "bots and owners never hold it", ctx do
      owner = unverified_user_fixture()
      owner.membership |> Membership.ownership_changeset(true) |> Repo.update!()
      owner = Accounts.get_member(scope_for(owner), owner.id)
      assert is_nil(owner.confirmed_at)
      refute Accounts.unverified?(owner)
      assert {:ok, _} = Chat.create_message(scope_for(owner), ctx.channel.id, %{"body" => "hi"})

      bot = bot_fixture(owner)
      assert is_nil(Repo.get!(User, bot.id).confirmed_at)
      refute Accounts.unverified?(bot)

      assert Visibility.authority(%Scope{user_id: bot.id}, []).server_permissions
             |> Tavern.Chat.Authorization.has_permission?(:send_messages)
    end

    test "with no mail provider nobody holds it", ctx do
      without_mail()
      user = unverified_user_fixture()

      refute Accounts.unverified?(user)

      assert {:ok, _message} =
               Chat.create_message(scope_for(user), ctx.channel.id, %{"body" => "hello"})
    end

    test "it is listed with a count of the members who hold it", ctx do
      manager = owner_fixture()
      unverified_user_fixture()
      unverified_user_fixture()
      user_fixture()

      role = Enum.find(Chat.list_roles(scope_for(manager)), & &1.is_unverified)
      assert role.id == ctx.unverified_role.id
      assert role.member_count == 2
    end

    test "only its permissions can be edited; it is never deleted, moved or given", ctx do
      owner = owner_fixture()
      user = user_fixture()
      scope = scope_for(owner)
      role_id = ctx.unverified_role.id
      reactions = PermissionBits.flag(:add_reactions)

      assert {:ok, updated} =
               Chat.update_role(scope, role_id, %{
                 "name" => "Renamed",
                 "permissions" => 0,
                 "deny_permissions" => reactions
               })

      assert updated.name == "Unverified"
      assert updated.deny_permissions == reactions

      assert {:error, :forbidden} = Chat.delete_role(scope, role_id)
      assert {:error, :forbidden} = Chat.move_role(scope, role_id, :up)
      assert {:error, :forbidden} = Chat.add_member_role(scope, user.id, role_id)
      assert Repo.get!(Role, role_id).position == 0
    end

    test "it is never a mention target, even for a member who may mention every role", ctx do
      owner = owner_fixture()
      scope = scope_for(owner)

      refute Enum.any?(Chat.composer_mentions(scope), &(&1.id == ctx.unverified_role.id))

      {:ok, message} = Chat.create_message(scope, ctx.channel.id, %{"body" => "hi @Unverified"})
      assert Repo.preload(message, :role_mentions).role_mentions == []
    end

    test "a new role and moves never take its place", ctx do
      owner = owner_fixture()
      scope = scope_for(owner)

      {:ok, first} = Chat.create_role(scope, %{"name" => "First"})
      {:ok, second} = Chat.create_role(scope, %{"name" => "Second"})
      {:ok, _} = Chat.move_role(scope, first.id, :down)

      positions = Map.new(Repo.all(Role), &{&1.id, &1.position})
      assert positions[ctx.unverified_role.id] == 0
      assert positions[first.id] == 1
      assert positions[second.id] == 2
    end
  end

  describe "email change" do
    test "the address changes only when the link sent to the new address opens" do
      user = user_fixture(%{email: "old-address@example.com"})

      assert {:ok, :confirmation_sent} =
               Accounts.update_user_email(user, "supersecurepass", %{
                 "email" => "new-address@example.com"
               })

      assert_received {:mail_captured, %{to: "new-address@example.com", text: text}}
      [token] = Regex.run(~r{/users/confirm-email/(\S+)}, text, capture: :all_but_first)

      assert Repo.get!(User, user.id).email == "old-address@example.com"
      refute Accounts.unverified?(Repo.preload(Repo.get!(User, user.id), :membership))

      assert {:ok, changed} = Accounts.update_user_email_from_token(token)
      assert changed.email == "new-address@example.com"
      assert {:error, :invalid} = Accounts.update_user_email_from_token(token)
    end

    test "an address another account holds is refused before any mail" do
      user_fixture(%{email: "taken@example.com"})
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_user_email(user, "supersecurepass", %{
                 "email" => "taken@example.com"
               })

      assert {"has already been taken", _} = changeset.errors[:email]
      refute_received {:mail_captured, _}
    end

    test "change links and resends share one limit per member" do
      user = unverified_user_fixture()

      for _ <- 1..3, do: assert(:ok = Accounts.resend_user_confirmation(user))

      assert {:error, changeset} =
               Accounts.update_user_email(user, "supersecurepass", %{
                 "email" => "late@example.com"
               })

      assert {"was sent too many links" <> _, _} = changeset.errors[:email]
      assert Repo.get!(User, user.id).email == user.email
    end

    test "opening the link verifies an unverified member" do
      user = unverified_user_fixture()

      assert {:ok, :confirmation_sent} =
               Accounts.update_user_email(user, "supersecurepass", %{
                 "email" => "proved@example.com"
               })

      assert_received {:mail_captured, %{to: "proved@example.com", text: text}}
      [token] = Regex.run(~r{/users/confirm-email/(\S+)}, text, capture: :all_but_first)

      assert {:ok, changed} = Accounts.update_user_email_from_token(token)
      assert %DateTime{} = changed.confirmed_at
    end
  end

  describe "the migration" do
    test "marks every existing account verified and leaves deleted accounts alone" do
      unconfirmed = unverified_user_fixture()
      deleted = unverified_user_fixture()
      {:ok, _} = Accounts.delete_account(deleted.id)

      migration = {20_261_119_181_454, Tavern.Repo.Migrations.AddEmailVerification}
      Ecto.Migrator.run(Repo, [migration], :down, all: true, log: false, migration_lock: false)
      Ecto.Migrator.run(Repo, [migration], :up, all: true, log: false, migration_lock: false)

      assert %DateTime{} = Repo.get!(User, unconfirmed.id).confirmed_at
      assert is_nil(Repo.get!(User, deleted.id).confirmed_at)
    end
  end

  defp confirmation_token(user) do
    :ok = Accounts.deliver_user_confirmation_instructions(user)
    assert_received {:mail_captured, %{to: to, text: text}}
    assert to == user.email
    [token] = Regex.run(~r{/users/confirm/(\S+)}, text, capture: :all_but_first)
    token
  end

  defp without_mail do
    previous = Application.get_env(:tavern, Tavern.Mailer)
    Application.put_env(:tavern, Tavern.Mailer, provider: nil)
    on_exit(fn -> Application.put_env(:tavern, Tavern.Mailer, previous) end)
  end
end
