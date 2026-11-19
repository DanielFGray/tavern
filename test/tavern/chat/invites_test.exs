defmodule Tavern.Chat.InvitesTest do
  use Tavern.DataCase, async: false

  alias Tavern.Accounts
  alias Tavern.Chat
  alias Tavern.Chat.Invites
  alias Tavern.Repo

  import Tavern.ChatFixtures

  describe "create_invite/2" do
    test "an owner creates an invite; a blank code gets a random one" do
      owner = owner_fixture()
      channel = channel_fixture()

      assert {:ok, invite} =
               Chat.create_invite(scope_for(owner), %{
                 "channel_id" => channel.id,
                 "max_uses" => "3"
               })

      assert invite.code != ""
      assert byte_size(invite.code) == 8
      assert invite.max_uses == 3
      assert invite.uses == 0
      assert invite.inviter_id == owner.id
      assert invite.channel_id == channel.id
    end

    test "a member without manage_server is refused" do
      _owner = owner_fixture()
      member = user_fixture()
      channel = channel_fixture()

      assert {:error, :forbidden} =
               Chat.create_invite(scope_for(member), %{"channel_id" => channel.id})
    end

    test "a code shorter than four characters is a changeset error" do
      owner = owner_fixture()
      channel = channel_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id, "code" => "ab"})
    end
  end

  describe "redeem/2" do
    test "a valid code is redeemed once, and the same user cannot redeem it twice" do
      owner = owner_fixture()
      channel = channel_fixture()
      {:ok, invite} = Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id})

      user = user_fixture()

      assert {:ok, %Chat.Invite{}} = Repo.transact(fn -> Invites.redeem(invite.code, user) end)

      assert Repo.reload!(invite).uses == 1

      assert Repo.transact(fn -> Invites.redeem(invite.code, user) end) ==
               {:error, :invalid_invite}
    end

    test "a use cap stops later registrations" do
      owner = owner_fixture()
      channel = channel_fixture()

      {:ok, invite} =
        Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id, "max_uses" => "1"})

      first = user_fixture()
      second = user_fixture()

      Repo.transact(fn -> Invites.redeem(invite.code, first) end)

      assert Repo.transact(fn -> Invites.redeem(invite.code, second) end) ==
               {:error, :invalid_invite}
    end

    test "revoked and expired codes are refused" do
      owner = owner_fixture()
      channel = channel_fixture()

      {:ok, invite} = Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id})
      {:ok, _revoked} = Chat.revoke_invite(scope_for(owner), invite.id)

      user = user_fixture()

      assert Repo.transact(fn -> Invites.redeem(invite.code, user) end) ==
               {:error, :invalid_invite}

      {:ok, expired} =
        Chat.create_invite(scope_for(owner), %{
          "channel_id" => channel.id,
          "expires_at" => DateTime.add(DateTime.utc_now(), -1)
        })

      assert Repo.transact(fn -> Invites.redeem(expired.code, user) end) ==
               {:error, :invalid_invite}
    end

    test "an unknown code is refused" do
      user = user_fixture()

      assert Repo.transact(fn -> Invites.redeem("nocode00", user) end) ==
               {:error, :invalid_invite}
    end

    test "redeem outside a transaction raises" do
      owner = owner_fixture()
      channel = channel_fixture()
      {:ok, invite} = Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id})
      user = user_fixture()

      assert_raise ArgumentError, ~r/must run inside a transaction/, fn ->
        Invites.redeem(invite.code, user)
      end
    end
  end

  describe "revoke_invite/2" do
    test "an owner revokes; an unknown id answers not_found" do
      owner = owner_fixture()
      channel = channel_fixture()
      {:ok, invite} = Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id})

      assert {:ok, revoked} = Chat.revoke_invite(scope_for(owner), invite.id)
      assert revoked.revoked_at

      assert {:error, :not_found} = Chat.revoke_invite(scope_for(owner), Ecto.UUID.generate())
    end
  end

  describe "registration with an invite" do
    test "register_user/2 redeems the code and records the use" do
      owner = owner_fixture()
      channel = channel_fixture()
      {:ok, invite} = Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id})

      assert {:ok, user} =
               Accounts.register_user(
                 %{
                   email: "invited@example.com",
                   username: "invited_user",
                   display_name: "Invited",
                   password: "supersecurepass"
                 },
                 invite_code: invite.code
               )

      assert Repo.reload!(invite).uses == 1

      assert Repo.exists?(
               from invite_use in Chat.InviteUse, where: invite_use.user_id == ^user.id
             )
    end

    test "an invalid code rolls back the whole registration" do
      owner = owner_fixture()
      channel = channel_fixture()

      {:ok, invite} =
        Chat.create_invite(scope_for(owner), %{"channel_id" => channel.id, "max_uses" => "1"})

      first = user_fixture()
      Repo.transact(fn -> Invites.redeem(invite.code, first) end)

      assert {:error, :invalid_invite} =
               Accounts.register_user(
                 %{
                   email: "late@example.com",
                   username: "late_user",
                   display_name: "Late",
                   password: "supersecurepass"
                 },
                 invite_code: invite.code
               )

      refute Repo.exists?(from u in Chat.User, where: u.email == "late@example.com")
    end
  end
end
