defmodule Tavern.Accounts.AccountDeletionTest do
  @moduledoc """
  `Accounts.delete_account/2` wipes an account so its email and username can register again, and
  keeps its messages under "Deleted user". `Accounts.delete_due_accounts/1` runs the deletions
  whose scheduled time has passed.
  """
  use Tavern.DataCase, async: false

  import Ecto.Query
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.AuditLogLine
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Message
  alias Tavern.Chat.User
  alias Tavern.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()

    member =
      user_fixture(%{email: "leaving@example.com", username: "leaving_member", bio: "hello"})

    %{owner: owner, member: member, channel: channel_by_slug!("general")}
  end

  describe "delete_account/2" do
    test "wipes the identity, profile, roles, sessions and images, and keeps messages", ctx do
      avatar = media_asset_fixture(ctx.member, %{kind: :avatar})
      ctx.member |> Ecto.Changeset.change(avatar_asset_id: avatar.id) |> Repo.update!()

      ctx.member.membership
      |> Ecto.Changeset.change(nickname: "nick", pronouns: "they/them")
      |> Repo.update!()

      member_role_fixture(ctx.member, role_fixture(%{position: 5}))
      token = Accounts.generate_user_session_token(ctx.member)
      message = message_fixture(ctx.channel, ctx.member, %{body: "still here"})

      assert {:ok, deleted} = Accounts.delete_account(ctx.member.id, ctx.owner.id)

      user = Repo.get!(User, ctx.member.id)
      assert user.id == deleted.id
      assert is_nil(user.email)
      assert user.username =~ ~r/^deleted-[0-9a-f]{16}$/
      assert user.display_name == "Deleted user"
      assert is_nil(user.bio)
      assert is_nil(user.hashed_password)
      assert is_nil(user.avatar_asset_id)
      assert user.deleted_at

      membership = Repo.get_by!(Membership, user_id: ctx.member.id)
      assert membership.deactivated_at
      assert is_nil(membership.nickname)
      assert is_nil(membership.pronouns)

      assert Repo.all(from(role in MemberRole, where: role.user_id == ^ctx.member.id)) == []
      assert is_nil(Accounts.get_user_by_session_token(token))
      assert is_nil(Repo.get(MediaAsset, avatar.id))

      assert is_nil(
               Accounts.get_user_by_email_and_password("leaving@example.com", "supersecurepass")
             )

      assert %Message{author_id: author_id, body: "still here"} = Repo.get!(Message, message.id)
      assert author_id == ctx.member.id
    end

    test "frees the email and username for a new registration", ctx do
      {:ok, _deleted} = Accounts.delete_account(ctx.member.id, ctx.owner.id)

      assert {:ok, fresh} =
               Accounts.register_user(%{
                 email: "leaving@example.com",
                 username: "leaving_member",
                 display_name: "Fresh",
                 password: "supersecurepass"
               })

      refute fresh.id == ctx.member.id
    end

    test "writes an account_deleted audit entry naming the actor", ctx do
      {:ok, deleted} = Accounts.delete_account(ctx.member.id, ctx.owner.id)

      entry =
        AuditLogEntry
        |> Repo.get_by!(action_type: "account_deleted", subject_user_id: ctx.member.id)
        |> Repo.preload([:actor_user, :subject_user, :channel])

      assert entry.actor_user_id == ctx.owner.id

      assert AuditLogLine.format(entry) ==
               "@#{ctx.owner.username} deleted the account @#{deleted.username}"
    end

    test "is idempotent: a second call writes nothing", ctx do
      {:ok, first} = Accounts.delete_account(ctx.member.id, ctx.owner.id)
      assert {:ok, second} = Accounts.delete_account(ctx.member.id, ctx.owner.id)

      assert second.username == first.username

      assert Repo.aggregate(
               from(entry in AuditLogEntry,
                 where:
                   entry.action_type == "account_deleted" and
                     entry.subject_user_id == ^ctx.member.id
               ),
               :count
             ) == 1
    end

    test "refuses bots and owners, and answers not_found for an unknown id", ctx do
      bot = bot_fixture(ctx.owner)

      assert {:error, :bot} = Accounts.delete_account(bot.id, ctx.owner.id)
      assert {:error, :owner} = Accounts.delete_account(ctx.owner.id, nil)
      assert {:error, :not_found} = Accounts.delete_account(Ecto.UUID.generate(), nil)
      assert {:error, :not_found} = Accounts.delete_account("not-a-uuid", nil)

      assert Repo.get!(User, bot.id).display_name == bot.display_name
      assert is_nil(Repo.get!(User, ctx.owner.id).deleted_at)
    end

    test "a deleted account's tombstone username is never recorded as a mention", ctx do
      {:ok, deleted} = Accounts.delete_account(ctx.member.id, ctx.owner.id)

      {:ok, message} =
        Chat.create_message(scope_for(ctx.owner), ctx.channel.id, %{
          "body" => "hi @#{deleted.username}"
        })

      assert Repo.preload(message, :user_mentions).user_mentions == []
    end
  end

  describe "delete_due_accounts/1" do
    test "deletes only accounts whose time has passed, once", ctx do
      other = user_fixture()
      plain_kick = user_fixture()

      {:ok, _, _} = Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), ctx.member.id)
      {:ok, _, _} = Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), other.id)
      {:ok, _, _} = Chat.kick_member(scope_for(ctx.owner), plain_kick.id)
      {:ok, _} = Chat.cancel_account_deletion(scope_for(ctx.owner), other.id)

      now = DateTime.utc_now()
      assert Accounts.delete_due_accounts(DateTime.add(now, 29, :day)) == 0
      assert is_nil(Repo.get!(User, ctx.member.id).deleted_at)

      later = DateTime.add(now, 31, :day)
      assert Accounts.delete_due_accounts(later) == 1
      assert Repo.get!(User, ctx.member.id).deleted_at
      assert is_nil(Repo.get!(User, other.id).deleted_at)
      assert is_nil(Repo.get!(User, plain_kick.id).deleted_at)

      assert Accounts.delete_due_accounts(later) == 0

      entry = Repo.get_by!(AuditLogEntry, action_type: "account_deleted")
      assert entry.subject_user_id == ctx.member.id
      assert is_nil(entry.actor_user_id)
    end

    test "a member who rejoined before the time is not deleted", ctx do
      {:ok, _, _} = Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), ctx.member.id)
      {:ok, invite} = Chat.create_invite(scope_for(ctx.owner), %{"channel_id" => ctx.channel.id})
      {:ok, _} = Chat.rejoin_with_invite(scope_for(ctx.member), invite.code)

      assert Accounts.delete_due_accounts(DateTime.add(DateTime.utc_now(), 31, :day)) == 0
      assert is_nil(Repo.get!(User, ctx.member.id).deleted_at)
    end
  end
end
