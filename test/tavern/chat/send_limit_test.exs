defmodule Tavern.Chat.SendLimitTest do
  @moduledoc """
  The per-member send limit spans every channel and thread and every kind of message write:
  plain messages, polls and forum posts count against one allowance.
  """
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Chat
  alias Tavern.Chat.Message
  alias Tavern.Chat.PermissionBits
  alias Tavern.RateLimit
  alias Tavern.Repo

  @member_bits [
    :view_channel,
    :send_messages,
    :send_messages_in_threads,
    :create_public_threads
  ]

  # Two messages an hour: a test finishes far inside one window, so no count crosses a boundary.
  @windows [{2, 3_600}]

  setup do
    previous = Application.fetch_env!(:tavern, Tavern.Chat.SendLimit)
    Application.put_env(:tavern, Tavern.Chat.SendLimit, windows: @windows)

    on_exit(fn ->
      Application.put_env(:tavern, Tavern.Chat.SendLimit, previous)
      RateLimit.reset!("send:")
    end)

    _owner = owner_fixture()
    role = role_fixture(%{permissions: PermissionBits.combine(@member_bits)})
    [member, other] = for _ <- 1..2, do: user_fixture()
    Enum.each([member, other], &member_role_fixture(&1, role))

    %{
      member: member,
      other: other,
      general: channel_fixture(%{name: "General", slug: unique_slug()}),
      random: channel_fixture(%{name: "Random", slug: unique_slug()}),
      forum: channel_fixture(%{name: "Help", kind: :forum, slug: unique_slug()})
    }
  end

  test "the allowance spans channels, and a refused send stores nothing", ctx do
    scope = scope_for(ctx.member)

    assert {:ok, _} = Chat.create_message(scope, ctx.general.id, %{"body" => "one"})
    assert {:ok, _} = Chat.create_message(scope, ctx.random.id, %{"body" => "two"})

    assert {:error, {:rate_limited, seconds}} =
             Chat.create_message(scope, ctx.general.id, %{"body" => "three"})

    assert seconds in 1..3_600
    refute Repo.get_by(Message, body: "three")
  end

  test "a thread message counts against the same allowance", ctx do
    starter = message_fixture(ctx.general, ctx.member, %{body: "starter"})
    thread = thread_fixture(ctx.general, starter, ctx.member)

    assert {:ok, _} = Chat.create_message(scope_for(ctx.member), thread.id, %{"body" => "in"})

    assert {:error, {:rate_limited, _}} =
             Chat.create_message(scope_for(ctx.member), thread.id, %{"body" => "over"})
  end

  test "a poll and a forum post count, and are refused over the limit", ctx do
    scope = scope_for(ctx.member)

    assert {:ok, _post} =
             Chat.create_forum_post(scope, ctx.forum.id, %{"title" => "Help", "body" => "me"})

    assert {:ok, _poll} =
             Chat.create_poll(scope, ctx.general.id, %{
               "question" => "Lunch?",
               "options" => ["Yes", "No"]
             })

    assert {:error, {:rate_limited, _}} =
             Chat.create_message(scope, ctx.general.id, %{"body" => "over"})

    assert {:error, {:rate_limited, _}} =
             Chat.create_forum_post(scope, ctx.forum.id, %{"title" => "Again", "body" => "me"})

    assert {:error, {:rate_limited, _}} =
             Chat.create_poll(scope, ctx.general.id, %{
               "question" => "Dinner?",
               "options" => ["Yes", "No"]
             })
  end

  test "one member's sends do not use another member's allowance", ctx do
    for _ <- 1..2, do: message_fixture(ctx.general, ctx.member)

    assert {:error, {:rate_limited, _}} =
             Chat.create_message(scope_for(ctx.member), ctx.general.id, %{"body" => "x"})

    assert {:ok, _} = Chat.create_message(scope_for(ctx.other), ctx.general.id, %{"body" => "y"})
  end
end
