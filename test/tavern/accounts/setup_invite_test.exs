defmodule Tavern.Accounts.SetupInviteTest do
  @moduledoc """
  A fresh server is invite only, and its owner claims it with the one-use setup invite that the
  migrate step prints while no owner exists.
  """
  use Tavern.DataCase, async: false

  import ExUnit.CaptureIO

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat.Invite

  setup do
    Bootstrap.ensure_seed_data!()
    :ok
  end

  defp attrs(name) do
    %{
      email: "#{name}@example.com",
      username: name,
      display_name: name,
      password: "supersecurepass"
    }
  end

  test "a fresh server refuses a registration without a code" do
    assert {:error, :invite_required} = Accounts.register_user(attrs("stranger"))
  end

  test "the setup invite is reused until used, and its user owns the server" do
    invite = Accounts.ensure_setup_invite()
    assert %Invite{max_uses: 1} = invite
    assert Accounts.ensure_setup_invite().id == invite.id

    {:ok, owner} = Accounts.register_user(attrs("operator"), invite_code: invite.code)
    assert owner.membership.is_owner
    assert Accounts.ensure_setup_invite() == nil
  end

  test "an expired setup invite is replaced" do
    invite = Accounts.ensure_setup_invite()
    invite |> Ecto.Changeset.change(expires_at: DateTime.utc_now()) |> Repo.update!()

    assert %Invite{} = fresh = Accounts.ensure_setup_invite()
    refute fresh.id == invite.id
  end

  test "the migrate step prints the setup link while no owner exists, then nothing" do
    invite = Accounts.ensure_setup_invite()
    printed = capture_io(&Tavern.Release.announce_setup_invite/0)
    assert printed =~ ~r{https?://[^/\s]+/register\?code=#{invite.code}\s}

    {:ok, _owner} = Accounts.register_user(attrs("operator"), invite_code: invite.code)
    assert capture_io(&Tavern.Release.announce_setup_invite/0) == ""
  end
end
