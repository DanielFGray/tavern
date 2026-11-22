defmodule TavernWeb.ServerLiveQuestionsTest do
  @moduledoc """
  Questions in the server view: the composer's poll form sends a poll to the open channel or
  thread, and the poll card votes, changes and withdraws a vote, takes an Other answer, follows
  other members' votes live and shows the closed state. A bot's ask and permission request show
  as their own cards, without a poll's header, counts or voters.
  """
  use TavernWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Message
  alias Tavern.Repo

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    %{conn: conn, me: current_user_from_conn(conn), general: channel_by_slug!("general")}
  end

  test "the composer's poll form sends a poll that shows as a card", ctx do
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    view |> element("#open-poll-button") |> render_click()
    assert has_element?(view, "#poll-form")

    view |> element("#add-poll-option") |> render_click()
    assert has_element?(view, "#poll-option-input-2")

    view
    |> form("#poll-form", %{
      poll: %{
        question: "Where should we meet?",
        options: ["Park", "Library", "Cafe"],
        duration_minutes: "60",
        multi_select: "true"
      }
    })
    |> render_submit()

    refute has_element?(view, "#poll-form")
    message = last_message(ctx.general)
    assert message.question.multi_select
    assert has_element?(view, "#question-#{message.id}", "Where should we meet?")
    assert has_element?(view, "#question-#{message.id}", "Choose any")

    for option <- message.question.options do
      assert has_element?(view, "#question-option-#{option.id}", option.label)
    end
  end

  test "a poll with one option shows the form's error and sends nothing", ctx do
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")
    before = Repo.aggregate(Tavern.Chat.Question, :count)

    view |> element("#open-poll-button") |> render_click()

    view
    |> form("#poll-form", %{poll: %{question: "Yes?", options: ["Yes", ""]}})
    |> render_submit()

    assert has_element?(view, "#poll-form", "distinct options")
    assert Repo.aggregate(Tavern.Chat.Question, :count) == before
  end

  test "picking an option votes, picking another changes it, and the vote can be removed", ctx do
    message = poll_fixture(ctx, %{})
    [park, library] = message.question.options
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    view |> element("#question-option-#{park.id}") |> render_click()
    assert has_element?(view, "#question-option-#{park.id}[aria-pressed=true]")
    assert has_element?(view, "#question-option-count-#{park.id}", "1")
    assert has_element?(view, "#question-option-voters-#{park.id}", ctx.me.display_name)

    view |> element("#question-option-#{library.id}") |> render_click()
    assert has_element?(view, "#question-option-count-#{park.id}", "0")
    assert has_element?(view, "#question-option-count-#{library.id}", "1")

    view |> element("#question-withdraw-#{message.id}") |> render_click()
    assert has_element?(view, "#question-option-count-#{library.id}", "0")
    refute has_element?(view, "#question-withdraw-#{message.id}")
  end

  test "an Other answer is stored with the vote and listed under the poll", ctx do
    message = poll_fixture(ctx, %{"allow_other" => true})
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    view
    |> form("#question-other-form-#{message.id}", %{other_text: "The beach"})
    |> render_submit()

    assert has_element?(view, "#question-other-answers-#{message.id}", "The beach")
    assert has_element?(view, "#question-other-answers-#{message.id}", ctx.me.display_name)
  end

  test "another member's vote updates the card live; an anonymous poll lists no voters", ctx do
    other = member_fixture()
    message = poll_fixture(ctx, %{"anonymous" => true})
    [park, _library] = message.question.options
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    {:ok, _} = Chat.answer_question(scope_for(other), message.id, %{"option_ids" => [park.id]})

    assert has_element?(view, "#question-option-count-#{park.id}", "1")
    refute has_element?(view, "#question-option-voters-#{park.id}")
    assert has_element?(view, "#question-#{message.id}", "Anonymous")
  end

  test "the author ends the poll; the closed card takes no votes", ctx do
    message = poll_fixture(ctx, %{})
    [park, _library] = message.question.options
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    view |> element("#question-close-#{message.id}") |> render_click()

    assert has_element?(view, "#question-#{message.id}[data-closed=true]")
    assert has_element?(view, "#question-status-#{message.id}", "Closed")
    assert has_element?(view, "#question-option-#{park.id}[disabled]")
    refute has_element?(view, "#question-close-#{message.id}")
    refute has_element?(view, "#edit-message-#{message.id}")
  end

  test "a poll that names other voters is shown but not votable", ctx do
    other = member_fixture()
    message = poll_fixture(ctx, %{"answerer_user_ids" => [other.id]})
    [park, _library] = message.question.options
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    assert has_element?(view, "#question-option-#{park.id}[disabled]")
    assert has_element?(view, "#question-#{message.id}", "Only named members can vote")
  end

  test "the thread composer sends a poll into the open thread", ctx do
    starter = message_fixture(ctx.general, ctx.me, %{body: "plan the trip"})
    thread = thread_fixture(ctx.general, starter, ctx.me)
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=general&thread=#{thread.id}")

    view |> element("#thread-open-poll-button") |> render_click()

    view
    |> form("#poll-form", %{poll: %{question: "Which day?", options: ["Sat", "Sun"]}})
    |> render_submit()

    message = last_message(thread)
    assert message.question
    assert has_element?(view, "#thread-panel-#{starter.id} #question-#{message.id}", "Which day?")

    [saturday, _sunday] = message.question.options
    view |> element("#question-option-#{saturday.id}") |> render_click()
    assert has_element?(view, "#question-option-count-#{saturday.id}", "1")
  end

  test "a forum post's composer sends a poll into the post, beside its replies", ctx do
    forum = channel_fixture(%{name: "Help", slug: "help", kind: :forum})

    {:ok, post} =
      Chat.create_forum_post(scope_for(ctx.me), forum.id, %{"title" => "Plan", "body" => "go?"})

    reply = message_fixture(post, ctx.me, %{body: "an earlier reply"})
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/?channel=help&thread=#{post.id}")

    view |> element("#thread-open-poll-button") |> render_click()

    view
    |> form("#poll-form", %{poll: %{question: "Which day?", options: ["Sat", ""]}})
    |> render_change()

    view |> element("#add-poll-option") |> render_click()
    assert has_element?(view, "#poll-option-input-2")

    assert has_element?(
             view,
             "[id^=thread-message-list-] [id$=\"#{reply.id}\"]",
             "an earlier reply"
           )

    view
    |> form("#poll-form", %{poll: %{question: "Which day?", options: ["Sat", "Sun", "Mon"]}})
    |> render_submit()

    message = last_message(post)
    [saturday | _] = message.question.options
    assert has_element?(view, "#question-#{message.id}", "Which day?")

    view |> element("#question-option-#{saturday.id}") |> render_click()
    assert has_element?(view, "#question-option-count-#{saturday.id}", "1")
  end

  test "a bot's ask shows no poll header or counts; the answer closes it and names who gave it",
       ctx do
    message = prompt_fixture(ctx, "ask")
    [staging, _production] = message.question.options
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    assert has_element?(view, "#question-#{message.id}[data-kind=ask]", "Question")
    refute has_element?(view, "#question-#{message.id}", "Poll")
    refute has_element?(view, "#question-option-count-#{staging.id}")
    assert has_element?(view, "#question-status-#{message.id}", "Waiting for an answer")

    view |> element("#question-option-#{staging.id}") |> render_click()

    assert has_element?(view, "#question-#{message.id}[data-closed=true]")
    assert has_element?(view, "#question-option-#{staging.id}[aria-pressed=true][disabled]")

    assert has_element?(
             view,
             "#question-status-#{message.id}",
             "Answered by #{ctx.me.display_name}"
           )

    refute has_element?(view, "#question-option-voters-#{staging.id}")
    refute has_element?(view, "#question-withdraw-#{message.id}")
  end

  test "a multi-select ask sends the checked options and the Other text as one answer", ctx do
    message = prompt_fixture(ctx, "ask", %{"multi_select" => true, "allow_other" => true})
    [staging, production] = message.question.options
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    assert has_element?(view, "#question-#{message.id}", "Choose any")

    view
    |> form("#question-answer-form-#{message.id}", %{
      "option_ids" => [staging.id, production.id],
      "other_text" => "and the docs"
    })
    |> render_submit()

    assert has_element?(view, "#question-#{message.id}[data-closed=true]")
    assert has_element?(view, "#question-option-#{staging.id}[aria-pressed=true]")
    assert has_element?(view, "#question-option-#{production.id}[aria-pressed=true]")
    assert has_element?(view, "#question-other-answers-#{message.id}", "and the docs")
    refute has_element?(view, "#question-answer-form-#{message.id}")
  end

  test "a bot's permission request tints its options by kind and has no counts", ctx do
    message = prompt_fixture(ctx, "permission")
    [allow, reject] = message.question.options
    {:ok, view, _html} = live_hydrated(ctx.conn, ~p"/")

    assert has_element?(
             view,
             "#question-#{message.id}[data-kind=permission]",
             "Permission request"
           )

    assert has_element?(view, "#question-option-#{allow.id}[data-option-kind=allow_once]")
    assert has_element?(view, "#question-option-#{reject.id}[data-option-kind=reject]")
    refute has_element?(view, "#question-option-count-#{allow.id}")
    refute has_element?(view, "#question-close-#{message.id}")

    view |> element("#question-option-#{allow.id}") |> render_click()

    refute has_element?(view, "#question-#{message.id}")
  end

  defp poll_fixture(ctx, attrs) do
    {:ok, message} =
      Chat.create_question(
        scope_for(ctx.me),
        ctx.general.id,
        %{"question" => "Where to?", "options" => ["Park", "Library"]}
        |> Map.merge(attrs)
        |> TavernWeb.ServerComponents.Questions.poll_params()
      )

    message
  end

  # A prompt a bot sends to the logged-in member, as barkeep does.
  defp prompt_fixture(ctx, kind, attrs \\ %{}) do
    owner = owner_fixture()
    bot = bot_fixture(owner)

    {:ok, %{bot_token: token}} =
      Tavern.Bots.create_bot_token(scope_for(owner), bot.id, %{"label" => "agent"})

    options =
      if kind == "permission",
        do: [
          %{"label" => "Allow", "kind" => "allow_once"},
          %{"label" => "Deny", "kind" => "reject"}
        ],
        else: [%{"label" => "Staging"}, %{"label" => "Production"}]

    {:ok, message} =
      Chat.create_question(
        %Tavern.Accounts.Scope{user_id: bot.id, bot_token_id: token.id},
        ctx.general.id,
        %{
          "kind" => kind,
          "question" => "Run the migration on **staging**?",
          "options" => options,
          "answerer_user_ids" => [ctx.me.id]
        }
        |> Map.merge(attrs)
      )

    message
  end

  defp member_fixture, do: user_fixture()

  defp last_message(channel) do
    Message
    |> where([message], message.channel_id == ^channel.id)
    |> order_by([message], desc: message.inserted_at)
    |> limit(1)
    |> preload(question: :options)
    |> Repo.one!()
  end
end
