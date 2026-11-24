defmodule Tavern.ProductEventsTest do
  @moduledoc """
  Each committed action emits one `[:tavern, :product_event]` with exactly the fields
  `docs/design/observability.md` lists: no message text, email or username, and members only as
  `ProductEvents.pseudonym/1`.

  The handler is global, so each test pins its own member or channel in `assert_receive`.
  """
  use Tavern.DataCase, async: true

  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Questions
  alias Tavern.Chat.UserSession
  alias Tavern.ProductEvents

  # Where an event happened. An event in a thread also has `thread_id`.
  @place [:channel_id, :channel_name, :channel_kind]

  @fields %{
    "member.signed_up" => [:member, :invited],
    "member.verified" => [:member],
    "member.moderated" => [:action, :actor, :member],
    "member.deletion_scheduled" => [:actor, :member],
    "member.rejoined" => [:member],
    "member.deleted" => [:member, :by],
    "session.seen" => [:member],
    "invite.created" => [:actor | @place],
    "upload.created" => [:member, :kind],
    "message.created" => [:member, :author_kind, :message_kind, :question | @place],
    "reaction.added" => [:member, :emoji_kind | @place],
    "reaction.removed" => [:member, :emoji_kind | @place],
    "question.answered" => [:member, :question | @place],
    "question.closed" => [:reason, :question | @place],
    "thread.created" => [:member | @place],
    "channel.created" => @place
  }

  setup do
    Bootstrap.ensure_seed_data!()
    open_registration!()
    ref = :telemetry_test.attach_event_handlers(self(), [ProductEvents.event()])
    on_exit(fn -> :telemetry.detach(ref) end)

    owner = owner_fixture()
    %{ref: ref, owner: owner, general: channel_by_slug!("general")}
  end

  describe "members" do
    test "a sign-up, with or without an invite", ctx do
      user = user_fixture()

      assert_event(ctx, "member.signed_up", %{
        member: ProductEvents.pseudonym(user.id),
        invited: false
      })

      {:ok, invite} = Chat.create_invite(scope_for(ctx.owner), %{"channel_id" => ctx.general.id})

      {:ok, invited} =
        Accounts.register_user(
          %{
            email: "#{unique_username()}@example.com",
            username: unique_username(),
            display_name: "Invited",
            password: "supersecurepass"
          },
          invite_code: invite.code
        )

      assert_event(ctx, "member.signed_up", %{
        member: ProductEvents.pseudonym(invited.id),
        invited: true
      })
    end

    test "a confirmed email", ctx do
      user = unverified_user_fixture()
      :ok = Accounts.deliver_user_confirmation_instructions(user)
      assert_received {:mail_captured, %{text: text}}
      [token] = Regex.run(~r{/users/confirm/(\S+)}, text, capture: :all_but_first)

      {:ok, _confirmed} = Accounts.confirm_user(token)

      assert_event(ctx, "member.verified", %{member: ProductEvents.pseudonym(user.id)})
    end

    test "an email change by a verified member is no new verification", ctx do
      user = user_fixture()

      {:ok, :confirmation_sent} =
        Accounts.update_user_email(user, "supersecurepass", %{
          "email" => "#{unique_username()}@example.com"
        })

      assert_received {:mail_captured, %{text: text}}
      [token] = Regex.run(~r{/users/confirm-email/(\S+)}, text, capture: :all_but_first)

      {:ok, _changed} = Accounts.update_user_email_from_token(token)

      refute_event(ctx, "member.verified", ProductEvents.pseudonym(user.id))
    end

    test "each moderation action, by action", ctx do
      member = user_fixture()
      owner = ProductEvents.pseudonym(ctx.owner.id)
      subject = ProductEvents.pseudonym(member.id)

      {:ok, _subject, _case} = Chat.timeout_member(scope_for(ctx.owner), member.id, 10)
      assert_event(ctx, "member.moderated", %{action: "timeout", actor: owner, member: subject})

      {:ok, _subject, _case} = Chat.kick_member(scope_for(ctx.owner), member.id)
      assert_event(ctx, "member.moderated", %{action: "kick", actor: owner, member: subject})

      {:ok, invite} = Chat.create_invite(scope_for(ctx.owner), %{"channel_id" => ctx.general.id})
      {:ok, _membership} = Chat.rejoin_with_invite(scope_for(member), invite.code)
      assert_event(ctx, "member.rejoined", %{member: subject})

      {:ok, _subject, _case} = Chat.ban_member(scope_for(ctx.owner), member.id)
      assert_event(ctx, "member.moderated", %{action: "ban", actor: owner, member: subject})

      {:ok, _subject, _case} = Chat.unban_member(scope_for(ctx.owner), member.id)
      assert_event(ctx, "member.moderated", %{action: "unban", actor: owner, member: subject})
    end

    test "a kick that schedules the account's deletion", ctx do
      member = user_fixture()

      {:ok, _subject, _case} =
        Chat.kick_member_and_schedule_deletion(scope_for(ctx.owner), member.id)

      expected = %{
        actor: ProductEvents.pseudonym(ctx.owner.id),
        member: ProductEvents.pseudonym(member.id)
      }

      assert_event(ctx, "member.moderated", Map.put(expected, :action, "kick"))
      assert_event(ctx, "member.deletion_scheduled", expected)
    end

    test "a deleted account, once", ctx do
      member = user_fixture()
      subject = ProductEvents.pseudonym(member.id)

      {:ok, _deleted} = Accounts.delete_account(member.id, ctx.owner.id)
      assert_event(ctx, "member.deleted", %{member: subject, by: "moderator"})

      {:ok, _deleted} = Accounts.delete_account(member.id, ctx.owner.id)
      refute_event(ctx, "member.deleted", subject)
    end

    test "a new session, then its use at most once per 5 minutes", ctx do
      member = user_fixture()
      seen = %{member: ProductEvents.pseudonym(member.id)}
      token = Accounts.generate_user_session_token(member)
      assert_event(ctx, "session.seen", seen)

      assert Accounts.get_user_by_session_token(token)
      refute_event(ctx, "session.seen", seen.member)

      from(session in UserSession, where: session.user_id == ^member.id)
      |> Repo.update_all(set: [last_seen_at: DateTime.add(DateTime.utc_now(), -301, :second)])

      assert Accounts.get_user_by_session_token(token)
      assert_event(ctx, "session.seen", seen)
    end
  end

  describe "messages" do
    test "a person's message carries its channel, never its text", ctx do
      member = user_fixture()
      channel = channel_fixture(%{"name" => "Lounge"})
      message_fixture(channel, member, %{body: "secret words"})

      fields =
        assert_event(ctx, "message.created", %{
          member: ProductEvents.pseudonym(member.id),
          author_kind: "person",
          message_kind: "default",
          question: "none",
          channel_id: channel.id,
          channel_name: "Lounge",
          channel_kind: "text"
        })

      refute Enum.any?(
               Map.values(fields),
               &(&1 in ["secret words", member.email, member.username])
             )
    end

    test "a bot's message", ctx do
      bot = bot_fixture(ctx.owner)
      message_fixture(ctx.general, bot)

      assert_event(ctx, "message.created", %{
        member: ProductEvents.pseudonym(bot.id),
        author_kind: "bot"
      })
    end

    test "a thread and its messages count under the thread's channel", ctx do
      member = user_fixture()
      channel = channel_fixture(%{"name" => "Lounge"})
      starter = message_fixture(channel, member)
      thread = thread_fixture(channel, starter, member, %{"name" => "Side talk"})

      place = %{
        thread_id: thread.id,
        channel_id: channel.id,
        channel_name: "Lounge",
        channel_kind: "text"
      }

      assert_event(
        ctx,
        "thread.created",
        Map.put(place, :member, ProductEvents.pseudonym(member.id))
      )

      message_fixture(thread, member)
      assert_event(ctx, "message.created", place)
    end

    test "a repeated request to thread one message counts one thread", ctx do
      member = user_fixture()
      starter = message_fixture(ctx.general, member)
      thread = thread_fixture(ctx.general, starter, member)
      assert_event(ctx, "thread.created", %{thread_id: thread.id})

      assert {:ok, %{id: same_id}} = Chat.create_public_thread(scope_for(member), starter.id)
      assert same_id == thread.id
      refute_event(ctx, "thread.created", ProductEvents.pseudonym(member.id))
    end

    test "a thread is never named by its title or its starter's text", ctx do
      member = user_fixture()
      starter = message_fixture(ctx.general, member, %{body: "secret starter words"})
      thread = thread_fixture(ctx.general, starter, member)
      reply = message_fixture(thread, member)
      {:ok, _message} = Chat.toggle_reaction(scope_for(member), reply.id, "👍")

      for name <- ["thread.created", "message.created", "reaction.added"] do
        fields = assert_event(ctx, name, %{thread_id: thread.id, channel_name: ctx.general.name})
        refute Enum.any?(Map.values(fields), &(is_nil(&1) or (is_binary(&1) and &1 =~ "secret")))
      end
    end

    test "a channel", ctx do
      channel = channel_fixture(%{"name" => "Announcements"})

      assert_event(ctx, "channel.created", %{
        channel_id: channel.id,
        channel_name: "Announcements",
        channel_kind: "text"
      })
    end

    test "a reaction added and removed", ctx do
      member = user_fixture()
      message = message_fixture(ctx.general, member)

      reaction = %{
        member: ProductEvents.pseudonym(member.id),
        channel_id: ctx.general.id,
        emoji_kind: "unicode"
      }

      {:ok, _message} = Chat.toggle_reaction(scope_for(member), message.id, "👍")
      assert_event(ctx, "reaction.added", reaction)

      {:ok, _message} = Chat.toggle_reaction(scope_for(member), message.id, "👍")
      assert_event(ctx, "reaction.removed", reaction)
    end

    test "a poll, its answers and its close", ctx do
      member = user_fixture()

      {:ok, message} =
        Chat.create_question(scope_for(member), ctx.general.id, %{
          "question" => "Lunch?",
          "options" => [%{"label" => "Soup"}, %{"label" => "Salad"}]
        })

      assert_event(ctx, "message.created", %{
        member: ProductEvents.pseudonym(member.id),
        question: "poll"
      })

      [option | _] = message.question.options

      {:ok, _message} =
        Chat.answer_question(scope_for(member), message.id, %{"option_ids" => [option.id]})

      assert_event(ctx, "question.answered", %{
        member: ProductEvents.pseudonym(member.id),
        question: "poll",
        channel_id: ctx.general.id
      })

      {:ok, _message} = Chat.close_question(scope_for(member), message.id)

      assert_event(ctx, "question.closed", %{
        channel_id: ctx.general.id,
        reason: "closed_by_hand",
        question: "poll"
      })
    end

    test "a poll closed by time", ctx do
      member = user_fixture()

      {:ok, _message} =
        Chat.create_question(scope_for(member), ctx.general.id, %{
          "question" => "Lunch?",
          "options" => [%{"label" => "Soup"}, %{"label" => "Salad"}],
          "duration_minutes" => 60
        })

      Questions.close_due(DateTime.add(DateTime.utc_now(), 2, :hour))

      assert_event(ctx, "question.closed", %{channel_id: ctx.general.id, reason: "time"})
    end
  end

  describe "other activity" do
    test "an invite", ctx do
      {:ok, _invite} = Chat.create_invite(scope_for(ctx.owner), %{"channel_id" => ctx.general.id})

      assert_event(ctx, "invite.created", %{
        actor: ProductEvents.pseudonym(ctx.owner.id),
        channel_id: ctx.general.id,
        channel_name: ctx.general.name
      })
    end

    @tag :tmp_dir
    test "an emoji upload", ctx do
      path = Path.join(ctx.tmp_dir, "party.png")
      File.write!(path, Tavern.UploadFixtures.unique_png())
      upload = %{path: path, client_name: "party.png", client_type: "image/png"}

      {:ok, _emoji} = Chat.create_custom_emoji(scope_for(ctx.owner), upload, %{"name" => "party"})

      assert_event(ctx, "upload.created", %{
        member: ProductEvents.pseudonym(ctx.owner.id),
        kind: "emoji"
      })
    end
  end

  test "a pseudonym is stable, and differs per member and from the id" do
    id = Ecto.UUID.generate()

    assert ProductEvents.pseudonym(id) == ProductEvents.pseudonym(id)
    assert ProductEvents.pseudonym(id) != ProductEvents.pseudonym(Ecto.UUID.generate())
    assert ProductEvents.pseudonym(id) =~ ~r/\A[0-9a-f]{32}\z/
  end

  # Waits for the event `name` whose fields include `expected`, checks that it has exactly the
  # documented fields (and `thread_id` when `expected` names one), and returns them. Events of
  # that name that do not match (another test's) go back to the mailbox.
  defp assert_event(ctx, name, expected, skipped \\ []) do
    ref = ctx.ref
    event = ProductEvents.event()

    receive do
      {^event, ^ref, %{}, %{event: ^name} = fields} = received ->
        if Map.take(fields, Map.keys(expected)) == expected do
          Enum.each(Enum.reverse(skipped), &send(self(), &1))
          in_thread = if Map.has_key?(expected, :thread_id), do: [:thread_id], else: []
          documented = [:event | in_thread ++ Map.fetch!(@fields, name)]
          assert Enum.sort(Map.keys(fields)) == Enum.sort(documented)
          fields
        else
          assert_event(ctx, name, expected, [received | skipped])
        end
    after
      1_000 -> flunk("no #{name} event with #{inspect(expected)}")
    end
  end

  # Asserts no event `name` for `member` arrived; earlier ones were consumed by `assert_event/3`.
  defp refute_event(ctx, name, member) do
    ref = ctx.ref
    event = ProductEvents.event()
    refute_received {^event, ^ref, %{}, %{event: ^name, member: ^member}}
  end
end
