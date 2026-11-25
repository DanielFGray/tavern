defmodule Tavern.Chat.AlertsTest do
  @moduledoc "The alert rule (docs/design/push-notifications.md)."
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Alerts
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.PushSubscriptions
  alias Tavern.Chat.Topics

  setup do
    Bootstrap.ensure_seed_data!()
    %{channel: channel_fixture(), author: owner_fixture(), member: user_fixture()}
  end

  defp alerted(message), do: Map.new(Alerts.recipients(message), &{&1.user_id, &1})

  # Answers every push with 201 and reports it, from the send task as well as the test.
  defp stub_push_service do
    test_pid = self()
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(Tavern.Embeds.SafeHTTP, fn conn ->
      send(test_pid, {:push, conn.host, conn.request_path})
      Plug.Conn.send_resp(conn, 201, "")
    end)
  end

  defp await_pushes do
    for pid <- Task.Supervisor.children(Tavern.WebPush.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  defp settings(user, attrs),
    do: {:ok, _} = Chat.update_user_notification_setting(scope_for(user), attrs)

  defp level(user, channel, level),
    do:
      {:ok, _} =
        Chat.update_channel_membership_notification(scope_for(user), channel.id, %{
          notification_level: level
        })

  test "a direct mention alerts its member and no one else", ctx do
    bystander = user_fixture()
    message = message_fixture(ctx.channel, ctx.author, %{body: "hi @#{ctx.member.username}"})

    alerted = alerted(message)

    assert %{mentioned?: true, desktop?: true, push?: false} = alerted[ctx.member.id]
    refute Map.has_key?(alerted, bystander.id)
    refute Map.has_key?(alerted, ctx.author.id)
  end

  test "publish sends the alert to the member's topic", ctx do
    :ok = Topics.subscribe_user(ctx.member.id)
    message = message_fixture(ctx.channel, ctx.author, %{body: "hi @#{ctx.member.username}"})
    tag = "mention-#{message.id}"
    channel_id = ctx.channel.id
    path = "/?channel=#{ctx.channel.slug}"

    assert_receive {:alert, %{tag: ^tag, channel_id: ^channel_id, path: ^path, title: title}}
    assert title =~ "mentioned you in ##{ctx.channel.name}"
  end

  test "@everyone alerts unless the member suppresses it", ctx do
    quiet = user_fixture()
    settings(quiet, %{suppress_everyone: true})

    alerted = alerted(message_fixture(ctx.channel, ctx.author, %{body: "@everyone"}))

    assert alerted[ctx.member.id].mentioned?
    refute Map.has_key?(alerted, quiet.id)
  end

  test "a role mention alerts its holders unless they suppress role mentions", ctx do
    role = role_fixture(%{name: "crew", mentionable: true})
    quiet = user_fixture()
    member_role_fixture(ctx.member, role)
    member_role_fixture(quiet, role)
    settings(quiet, %{suppress_roles: true})

    alerted = alerted(message_fixture(ctx.channel, ctx.author, %{body: "@crew"}))

    assert alerted[ctx.member.id].mentioned?
    refute Map.has_key?(alerted, quiet.id)
  end

  test "an all-messages level alerts on every message, and a channel's level beats the global one",
       ctx do
    level(ctx.member, ctx.channel, :all_messages)
    settings(ctx.member, %{notify_on_mentions: false})
    everywhere = user_fixture()
    settings(everywhere, %{notify_on_all_messages: true})
    silenced = user_fixture()
    settings(silenced, %{notify_on_all_messages: true})
    level(silenced, ctx.channel, :nothing)

    alerted = alerted(message_fixture(ctx.channel, ctx.author, %{body: "plain"}))

    assert %{mentioned?: false} = alerted[ctx.member.id]
    assert Map.has_key?(alerted, everywhere.id)
    refute Map.has_key?(alerted, silenced.id)
  end

  test "mentions off at the default level silences a mention", ctx do
    settings(ctx.member, %{notify_on_mentions: false})

    message = message_fixture(ctx.channel, ctx.author, %{body: "hi @#{ctx.member.username}"})

    refute Map.has_key?(alerted(message), ctx.member.id)
  end

  test "a member who cannot view the channel gets no alert", ctx do
    hidden = channel_fixture(%{name: "Staff", slug: unique_slug()})

    channel_permission_overwrite_fixture(hidden, %{
      role_id: default_role().id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    message = message_fixture(hidden, ctx.author, %{body: "@everyone"})

    refute Map.has_key?(alerted(message), ctx.member.id)
  end

  test "desktop alerts off leaves the member out", ctx do
    settings(ctx.member, %{desktop_enabled: false})

    message = message_fixture(ctx.channel, ctx.author, %{body: "hi @#{ctx.member.username}"})

    refute Map.has_key?(alerted(message), ctx.member.id)
  end

  test "a member with desktop alerts off still gets push on a subscribed device", ctx do
    settings(ctx.member, %{desktop_enabled: false})
    stub_push_service()

    {:ok, _} =
      PushSubscriptions.subscribe(
        scope_for(ctx.member),
        ctx.member |> browser_session() |> elem(1),
        push_subscription_params("https://push.site.test/d")
      )

    message = message_fixture(ctx.channel, ctx.author, %{body: "hi @#{ctx.member.username}"})

    assert %{desktop?: false, push?: true} = alerted(message)[ctx.member.id]
    await_pushes()
  end

  test "publish sends a push to each subscribed device of a recipient", ctx do
    {:ok, _} =
      PushSubscriptions.subscribe(
        scope_for(ctx.member),
        ctx.member |> browser_session() |> elem(1),
        push_subscription_params("https://push.site.test/e")
      )

    stub_push_service()
    message_fixture(ctx.channel, ctx.author, %{body: "hi @#{ctx.member.username}"})
    await_pushes()

    assert_received {:push, "push.site.test", "/e"}
  end

  test "an unfollowed thread alerts on a direct mention only", ctx do
    starter = message_fixture(ctx.channel, ctx.member, %{body: "a thread"})
    thread = thread_fixture(ctx.channel, starter, ctx.member)
    :ok = Chat.unfollow_thread(scope_for(ctx.member), thread.id)

    refute Map.has_key?(
             alerted(message_fixture(thread, ctx.author, %{body: "@everyone"})),
             ctx.member.id
           )

    direct = message_fixture(thread, ctx.author, %{body: "hi @#{ctx.member.username}"})
    assert alerted(direct)[ctx.member.id].mentioned?
  end

  test "a followed thread takes its parent's level", ctx do
    starter = message_fixture(ctx.channel, ctx.member, %{body: "a thread"})
    thread = thread_fixture(ctx.channel, starter, ctx.member)
    level(ctx.member, ctx.channel, :all_messages)

    assert Map.has_key?(
             alerted(message_fixture(thread, ctx.author, %{body: "plain"})),
             ctx.member.id
           )

    level(ctx.member, ctx.channel, :nothing)
    message = message_fixture(thread, ctx.author, %{body: "hi @#{ctx.member.username}"})

    refute Map.has_key?(alerted(message), ctx.member.id)
  end

  test "a pin line alerts no one", ctx do
    level(ctx.member, ctx.channel, :all_messages)
    message = message_fixture(ctx.channel, ctx.author, %{body: "pin me"})
    :ok = Topics.subscribe_user(ctx.member.id)

    {:ok, _} = Chat.pin_message(scope_for(ctx.author), message.id)

    refute_receive {:alert, _}
  end
end
