defmodule Tavern.Chat.InviteRequestsTest do
  # The intake and send limits are server-wide counters in Valkey, so these tests run alone.
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.AuditLogLine
  alias Tavern.Chat.Invite
  alias Tavern.Chat.InviteRequest
  alias Tavern.Chat.InviteRequestLimits
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.ServerSettings

  @ip "203.0.113.7"

  setup do
    InviteRequestLimits.reset!()
    on_exit(&InviteRequestLimits.reset!/0)

    owner = owner_fixture()
    channel_fixture(%{slug: "general", name: "general"})
    moderator = user_fixture()
    member = user_fixture()

    role =
      role_fixture(%{permissions: PermissionBits.combine([:view_channel, :manage_applications])})

    member_role_fixture(moderator, role)
    set_settings!(registration_mode: :invite_only, accept_invite_requests: true)

    %{owner: owner, moderator: scope_for(moderator), member: scope_for(member)}
  end

  describe "request_invite/2" do
    test "stores a pending request and sends no mail" do
      assert {:ok, :received} = Chat.request_invite(%{"email" => "new@example.com"}, @ip)

      assert [%InviteRequest{status: :pending, email: "new@example.com", ip_address: @ip}] =
               Repo.all(InviteRequest)

      refute_received {:mail_captured, _}
    end

    test "answers the same and stores nothing for a duplicate or a member's address", %{
      owner: owner
    } do
      assert {:ok, :received} = Chat.request_invite(%{"email" => "dup@example.com"}, @ip)
      assert {:ok, :received} = Chat.request_invite(%{"email" => "DUP@example.com"}, @ip)
      assert {:ok, :received} = Chat.request_invite(%{"email" => owner.email}, "198.51.100.1")

      assert ["dup@example.com"] = Repo.all(from(r in InviteRequest, select: r.email))
    end

    test "refuses a malformed address with a changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Chat.request_invite(%{"email" => "not an address"}, @ip)

      assert %{email: [_]} = errors_on(changeset)
    end

    test "refuses while the setting is off or registration is open" do
      set_settings!(accept_invite_requests: false)
      assert {:error, :not_accepting} = Chat.request_invite(%{"email" => "a@example.com"}, @ip)

      set_settings!(accept_invite_requests: true, registration_mode: :open)
      assert {:error, :not_accepting} = Chat.request_invite(%{"email" => "a@example.com"}, @ip)
    end

    test "refuses while mail is not configured" do
      with_mailer_config([provider: nil], fn ->
        assert {:error, :not_accepting} =
                 Chat.request_invite(%{"email" => "a@example.com"}, @ip)
      end)
    end

    test "over the per-IP hourly limit answers received and stores nothing" do
      with_limits([requests_per_ip_hour: 2], fn ->
        for n <- 1..3, do: Chat.request_invite(%{"email" => "h#{n}@example.com"}, @ip)
        assert {:ok, :received} = Chat.request_invite(%{"email" => "h4@example.com"}, @ip)
        assert Repo.aggregate(InviteRequest, :count) == 2

        assert {:ok, :received} =
                 Chat.request_invite(%{"email" => "other@example.com"}, "10.0.0.9")

        assert Repo.aggregate(InviteRequest, :count) == 3
      end)
    end

    test "over the per-IP daily limit answers received and stores nothing" do
      with_limits([requests_per_ip_hour: 100, requests_per_ip_day: 2], fn ->
        for n <- 1..3, do: Chat.request_invite(%{"email" => "d#{n}@example.com"}, @ip)
        assert Repo.aggregate(InviteRequest, :count) == 2
      end)
    end

    test "over the server-wide pending cap answers received and stores nothing" do
      with_limits([pending_requests_per_day: 2], fn ->
        for n <- 1..3 do
          assert {:ok, :received} =
                   Chat.request_invite(%{"email" => "s#{n}@example.com"}, "10.0.1.#{n}")
        end

        assert Repo.aggregate(InviteRequest, :count) == 2
      end)
    end

    test "a duplicate does not use up the server-wide pending cap" do
      with_limits([pending_requests_per_day: 1], fn ->
        Chat.request_invite(%{"email" => "same@example.com"}, "10.0.2.1")
        Chat.request_invite(%{"email" => "same@example.com"}, "10.0.2.2")
        assert Repo.aggregate(InviteRequest, :count) == 1
      end)
    end
  end

  describe "deciding needs manage_applications" do
    test "a member without the bit is forbidden everywhere", %{member: member} do
      request = request!("forbidden@example.com")

      assert {:error, :forbidden} = Chat.list_invite_requests(member, :all)
      assert {:error, :forbidden} = Chat.approve_invite_request(member, request.id)
      assert {:error, :forbidden} = Chat.deny_invite_request(member, request.id)
      assert {:error, :forbidden} = Chat.deny_invite_requests_from_ip(member, @ip)
      assert {:error, :forbidden} = Chat.resend_invite(member, request.id)
      assert Repo.reload!(request).status == :pending
    end

    test "the owner passes without holding the bit", %{owner: owner} do
      request = request!("owner-ok@example.com")

      assert {:ok, %InviteRequest{status: :denied}} =
               Chat.deny_invite_request(scope_for(owner), request.id)
    end
  end

  describe "approve_invite_request/2" do
    test "binds a one-use invite, audits, and mails its link", %{moderator: moderator} do
      request = request!("approve@example.com")

      assert {:ok, approved} = Chat.approve_invite_request(moderator, request.id)
      assert approved.status == :approved
      assert approved.decided_by_id == moderator.user_id
      assert approved.delivered_at
      assert is_nil(approved.delivery_error)

      invite = Repo.get!(Invite, approved.invite_id)
      assert invite.max_uses == 1
      assert invite.inviter_id == moderator.user_id
      assert DateTime.diff(invite.expires_at, DateTime.utc_now(), :day) in 6..7

      assert_received {:mail_captured, %{to: "approve@example.com", text: text, html: html}}
      assert text =~ "/register?code=#{invite.code}"
      assert html =~ "code=#{invite.code}"

      assert Repo.get_by!(AuditLogEntry, action_type: "invite_request_approved").target_id ==
               request.id
    end

    test "a decided request cannot be decided again", %{moderator: moderator} do
      request = request!("twice@example.com")
      assert {:ok, _} = Chat.approve_invite_request(moderator, request.id)
      assert {:error, :not_pending} = Chat.approve_invite_request(moderator, request.id)
      assert {:error, :not_pending} = Chat.deny_invite_request(moderator, request.id)
      assert Repo.aggregate(Invite, :count) == 1
    end

    test "an unknown id is not found", %{moderator: moderator} do
      assert {:error, :not_found} = Chat.approve_invite_request(moderator, Ecto.UUID.generate())
      assert {:error, :not_found} = Chat.approve_invite_request(moderator, "nope")
    end
  end

  describe "deny_invite_request/2" do
    test "denies, audits, and mails nothing", %{moderator: moderator} do
      request = request!("deny@example.com")

      assert {:ok, %InviteRequest{status: :denied, decided_at: %DateTime{}}} =
               Chat.deny_invite_request(moderator, request.id)

      assert Repo.get_by!(AuditLogEntry, action_type: "invite_request_denied")
      refute_received {:mail_captured, _}
    end
  end

  describe "deny_invite_requests_from_ip/2" do
    test "denies every pending request from one IP, with one audit entry", %{moderator: moderator} do
      for n <- 1..3, do: Chat.request_invite(%{"email" => "flood#{n}@example.com"}, @ip)
      other = request!("elsewhere@example.com", "10.9.9.9")

      assert {:ok, requests} = Chat.list_invite_requests(moderator, :pending)
      assert Enum.find(requests, &(&1.ip_address == @ip)).ip_request_count == 3
      assert Enum.find(requests, &(&1.id == other.id)).ip_request_count == 1

      assert {:ok, 3} = Chat.deny_invite_requests_from_ip(moderator, @ip)
      assert {:ok, [%{id: id}]} = Chat.list_invite_requests(moderator, :pending)
      assert id == other.id

      assert %AuditLogEntry{metadata: %{"count" => 3}} =
               Repo.get_by!(AuditLogEntry, action_type: "invite_requests_denied_by_ip")
    end
  end

  describe "mail delivery" do
    test "a failed send leaves the request approved with its error; Resend then sends", %{
      moderator: moderator
    } do
      request = request!("flaky@example.com")

      with_mailer_config(cloudflare_config(), fn ->
        Req.Test.stub(__MODULE__, fn conn ->
          conn
          |> Plug.Conn.put_status(500)
          |> Req.Test.json(%{
            "success" => false,
            "errors" => [%{"code" => 1, "message" => "down"}]
          })
        end)

        assert {:ok, approved} = Chat.approve_invite_request(moderator, request.id)
        assert approved.status == :approved
        assert approved.delivery_error =~ "500"
        assert is_nil(approved.delivered_at)

        Req.Test.stub(__MODULE__, fn conn ->
          Req.Test.json(conn, %{"success" => true, "result" => %{"delivered" => ["x"]}})
        end)

        assert {:ok, resent} = Chat.resend_invite(moderator, request.id)
        assert resent.delivered_at
        assert is_nil(resent.delivery_error)
      end)
    end

    test "one invite email per address per day, Resend included", %{moderator: moderator} do
      request = request!("once@example.com")

      assert {:ok, %{delivered_at: %DateTime{}}} =
               Chat.approve_invite_request(moderator, request.id)

      assert_received {:mail_captured, _}

      assert {:ok, resent} = Chat.resend_invite(moderator, request.id)
      assert resent.delivery_error == "not sent: daily limit"
      assert resent.delivered_at
      refute_received {:mail_captured, _}
    end

    test "over the server-wide daily mail cap, approval stands and mail waits", %{
      moderator: moderator
    } do
      first = request!("cap1@example.com")
      second = request!("cap2@example.com", "10.3.3.3")

      with_limits([mails_per_day: 1], fn ->
        assert {:ok, %{delivery_error: nil}} = Chat.approve_invite_request(moderator, first.id)

        assert {:ok, %{status: :approved, delivery_error: "not sent: daily limit"}} =
                 Chat.approve_invite_request(moderator, second.id)
      end)
    end

    test "Resend refuses an invite that was used, revoked or expired", %{moderator: moderator} do
      request = request!("used@example.com")
      {:ok, approved} = Chat.approve_invite_request(moderator, request.id)

      Repo.get!(Invite, approved.invite_id) |> Ecto.Changeset.change(uses: 1) |> Repo.update!()

      assert {:error, :invite_unusable} = Chat.resend_invite(moderator, request.id)
    end

    test "Resend needs an approved request", %{moderator: moderator} do
      request = request!("pending@example.com")
      assert {:error, :not_approved} = Chat.resend_invite(moderator, request.id)
    end
  end

  describe "the accept setting" do
    test "cannot be turned on while mail is not configured", %{owner: owner} do
      set_settings!(accept_invite_requests: false)

      with_mailer_config(
        [provider: :cloudflare, from: nil, account_id: "a", api_token: nil],
        fn ->
          assert {:error, changeset} =
                   Chat.update_server_settings(scope_for(owner), %{
                     "accept_invite_requests" => "true"
                   })

          assert [message] = errors_on(changeset).accept_invite_requests
          assert message =~ "EMAIL_FROM"
          assert message =~ "CLOUDFLARE_EMAIL_API_TOKEN"
        end
      )

      assert {:ok, %{accept_invite_requests: true}} =
               Chat.update_server_settings(scope_for(owner), %{"accept_invite_requests" => "true"})
    end
  end

  test "the audit page renders a line for every decision", %{moderator: moderator} do
    approved = request!("line-approve@example.com")
    denied = request!("line-deny@example.com")
    request!("line-flood@example.com", "10.7.7.7")

    {:ok, _} = Chat.approve_invite_request(moderator, approved.id)
    {:ok, _} = Chat.deny_invite_request(moderator, denied.id)
    {:ok, 1} = Chat.deny_invite_requests_from_ip(moderator, "10.7.7.7")

    lines =
      from(entry in AuditLogEntry, where: like(entry.action_type, "invite_request%"))
      |> Repo.all()
      |> Repo.preload([:actor_user, :subject_user, :channel])
      |> Enum.map(&AuditLogLine.format/1)

    assert length(lines) == 3
    assert Enum.all?(lines, &(is_binary(&1) and &1 != ""))
  end

  test "end to end: request, approve, follow the mailed link, register with its code", %{
    moderator: moderator
  } do
    assert {:ok, :received} = Chat.request_invite(%{"email" => "e2e@example.com"}, @ip)
    [request] = Repo.all(InviteRequest)

    assert {:ok, _} = Chat.approve_invite_request(moderator, request.id)
    assert_received {:mail_captured, %{text: text}}

    [_, code] = Regex.run(~r{/register\?code=([a-z0-9]+)}, text)

    attrs = %{
      email: "e2e@example.com",
      username: "e2e_user",
      display_name: "E2E",
      password: "supersecurepass"
    }

    assert {:error, :invite_required} = Accounts.register_user(attrs)
    assert {:ok, user} = Accounts.register_user(attrs, invite_code: code)
    assert user.email == "e2e@example.com"

    assert {:error, :invalid_invite} =
             Accounts.register_user(%{attrs | email: "again@example.com", username: "again"},
               invite_code: code
             )
  end

  defp request!(email, ip \\ @ip) do
    {:ok, :received} = Chat.request_invite(%{"email" => email}, ip)
    Repo.get_by!(InviteRequest, email: email)
  end

  defp set_settings!(changes) do
    settings = Repo.one(ServerSettings) || %ServerSettings{name: "Tavern", singleton: true}

    settings
    |> Ecto.Changeset.change(changes)
    |> Repo.insert_or_update!()

    Chat.reset_server_settings_cache()
  end

  defp cloudflare_config do
    [
      provider: :cloudflare,
      from: "tavern@example.test",
      account_id: "acct",
      api_token: "token",
      req_options: [plug: {Req.Test, __MODULE__}]
    ]
  end

  defp with_mailer_config(config, fun), do: with_env(Tavern.Mailer, config, fun)

  defp with_limits(overrides, fun) do
    config = Application.fetch_env!(:tavern, Tavern.Chat.InviteRequests)
    limits = Keyword.merge(config[:limits], overrides)
    with_env(Tavern.Chat.InviteRequests, Keyword.put(config, :limits, limits), fun)
  end

  defp with_env(key, value, fun) do
    previous = Application.fetch_env!(:tavern, key)
    Application.put_env(:tavern, key, value)

    try do
      fun.()
    after
      Application.put_env(:tavern, key, previous)
    end
  end
end
