# Questions: polls and bot prompts on a message

Status: built. Tasks: "Polls" and "Polls and bot prompts as kinds of one Question".

A question is a message with options that members answer on a card in the transcript, in a channel, a thread or a forum post. Its `kind` says what it is for:

- **poll**: members vote. The card shows the counts and the voters. A member may change or withdraw a vote.
- **ask**: a bot asks the members it names. One answer closes it.
- **permission**: a bot asks to run something, such as a shell command. One named member allows or rejects it once.

An ask and a permission request are **prompts**. A prompt is a bot's question to a person, so it is not a poll. Its card has no "Poll" header, no counts and no voter list. Only a bot sends a prompt. The composer sends polls only.

`Tavern.Chat.Questions` holds the operations; `Chat` delegates to it.

## Data

- `questions`: one row per question message (`message_id`, unique). `kind` (`poll`, `ask`, `permission`), `multi_select`, `anonymous`, `allow_other`; `closes_at` (nil means it is closed by hand); `closed_at`; `max_answers` (nil or above 0); `answerer_user_ids` and `answerer_role_ids` (empty means not narrowed).
- `question_options`: `position`, `label` (at most 80 characters) and `kind`. Labels are free text, so a bot can use its own words. `kind` is set only on a permission request's options: `allow_once`, `allow_always` or `reject`, after the permission option kinds of the Agent Client Protocol. The card styles an allow option in the success colour and a reject option in the error colour.
- `question_answers`: one row per answerer and question, unique on `(question_id, user_id)`. It holds `option_ids` and `other_text` (at most 200 characters). A withdrawn answer deletes the row.

The question text is the message body. `Message.kind` has no question value: a message is a question when it has a `questions` row, and the read preloads load it with its options and answers. A question message cannot be edited (`Chat.update_message/3` answers `{:error, :forbidden}`), because new text would change what the answers answered. Deleting the message deletes the question.

## Creating a question

`Questions.create_question(scope, channel_id, attrs)` validates `change_question/1`:

- `kind`: `poll` (the default), `ask` or `permission`. A prompt from a person (a scope with no bot token) is `{:error, :forbidden}`.
- `question`: required. A poll's is at most 300 characters and shows as plain text. A prompt's is at most 4000 characters, the message limit, and renders as Markdown, so a command can sit in a code block.
- `options`: a list of objects, `{"label": "..."}`, with `"kind"` on each permission option and on no other kind's. Labels are trimmed, blanks dropped, duplicates (ignoring case) refused; 2 to 10 must remain.
- Poll-only fields: `anonymous`, `duration_minutes` (60 to 10080, 1 hour to 7 days, or nil for a poll ended by hand) and `max_answers`. A prompt refuses each of them. Tavern sets a prompt's `max_answers` to 1, so its first answer closes it.
- `multi_select`: a poll or an ask. A permission request takes one answer and refuses it.
- `allow_other`, `answerer_user_ids` and `answerer_role_ids`, for every kind.

It sends the message through `Chat.Messages.send_message/4`, so the send rules apply unchanged: `Visibility.authorize_write`, timeouts, slowmode, the per-member send limit (rate-limits.md), locked and archived threads. A message to an archived thread reopens it, as any message does. The question rows are written in the same transaction as the message.

## Who may answer

Each answer is decided in its transaction, in this order:

1. `Visibility` decides `:answer_question`: the member may send in the channel, is not timed out, and the thread is not locked or archived. A closed thread refuses an answer as it refuses a reaction: an answer never reopens an archived thread. A channel the member may not view answers `:not_found`.
2. The question row is locked (`FOR UPDATE`), after the membership and message rows. An answer, a close by hand and the closer all take this lock, so an answer never lands on a closed question, and a question closes once.
3. A closed question refuses with `:question_closed`.
4. A narrowed question also requires the member to be in `answerer_user_ids` or to hold a role in `answerer_role_ids`. The list narrows step 1 and never widens it: a named member who may not send still cannot answer.
5. The choice must name this question's options. A single-choice question takes one answer: one option, or the Other text. Other text needs `allow_other`. A refusal is `:invalid_choice`.

An answer with no option and no Other text withdraws the member's vote in a poll. A prompt refuses it with `:invalid_choice`: it would close the prompt with no answer. Sending a new choice replaces the old one. A prompt closes on its first answer, so only a poll's answers change.

## Closing

A question closes in three ways. Each sets `closed_at` under the question lock and broadcasts `{:question_closed, message, reason}`.

- **By hand** (`:closed_by_hand`): `Questions.close_question/2`. The author (the bot, for a prompt), or a member with `manage_messages` in the channel. A locked or archived thread does not block it. On a prompt the card calls this Dismiss, and the bot reads it as no answer.
- **By its answer limit** (`:answered`): the answer that brings the number of answerers to `max_answers` closes the question in its own transaction. A prompt's limit is 1.
- **At its end time** (`:time`, polls only): `Tavern.Chat.QuestionCloser`, a GenServer, wakes at the earliest `closes_at` (and at least every 60 seconds) and calls `Questions.close_due/1`. That locks due questions with `SKIP LOCKED` and sets `closed_at` to `closes_at`. `Question.closed?/2` also treats a passed `closes_at` as closed, so an answer between the end time and the closer's run is refused. `config :tavern, :question_closer, false` turns the closer off in tests, which call `close_due/1` directly.

A poll's results stay visible after it closes. So does an ask's answer.

A closed permission request leaves every list. A bot asks for many of them while it works, and once they are answered they only hide the conversation around them. `Message.listed?/1` (in memory) and `Message.where_listed/1` (in a query) hold the rule: a list shows a message that is not deleted and is not a closed permission request. The transcript, the message count, thread reply counts and latest replies, unread counts, read markers and the bot API's message history all use it. A read by id (`Chat.get_message/2`, the bot API's `GET /messages/:id/question`) still finds the message, so the bot can read the answer. When one closes, open sessions drop its row from the stream, and a thread's parent channel hears `{:thread_message_unlisted, message}` (`ThreadFollows.broadcast_message_unlisted/1`, also sent for a deleted thread message) so the thread chip's reply count drops.

## Results

`Questions.results(question, viewer_id)` is pure. It gives each option's count and answerers, the Other answers, the number of answerers and the viewer's own answer. An anonymous poll gives counts only: no option answerers, and Other answers without their authors. Counts are per answerer, so in a multi-select poll the option counts can add up to more than the answer count.

## Events

After its transaction, an answer broadcasts `{:question_answered, message, %{user_id, option_ids, other_text}}` on the channel topic. LiveView sessions re-render the card. The bot event stream sends:

- `question.answered`: `message_id`, `channel_id`, `question` (the serialized question with counts) and `answer` (`user_id`, `option_ids`, `options` with `id`, `label` and `kind`, `other_text`). In an anonymous poll `answer` is null. A withdrawn vote sends `question.answered` with empty `option_ids` and null `other_text`.
- `question.closed`: `message_id`, `channel_id`, `reason` (`answered`, `time` or `closed_by_hand`) and `question`.

Every serialized message carries `question` (null when the message has none).

## Bot API

- `POST /api/v1/channels/:channel_id/questions` with `{"question": {...}}` takes the `change_question/1` fields. 201 with the message; 422 `invalid_question` with the changeset errors; 404 for a channel the bot may not view; 403 when it may not send.
- `GET /api/v1/messages/:message_id/question` reads the message with its question. 404 when the message has none.
- `POST /api/v1/messages/:message_id/question/close` closes it. 409 `question_closed` when it already closed.

Bots do not answer through the API. A bot that asks a person sends an `ask` or a `permission` with `answerer_user_ids` or `answerer_role_ids`, waits for `question.answered` or `question.closed`, and reads the chosen options (with their kinds) and the Other text from the event.

## UI

- **Composer**: the + menu's Create poll (`#open-poll-button`, or `#thread-open-poll-button` in a thread) opens the poll form (`#poll-form`) above the one composer. The form has the question, option inputs with add and remove, an end time (1 hour to 7 days, or by hand; 24 hours by default) and checkboxes for several answers, an Other answer and hidden voters. The poll goes where the composer writes: the open thread, else the open channel. The form closes when the conversation changes. Narrowed voters and `max_answers` are set only through the context and the bot API.
- **Cards** (`#question-<message id>`, `data-kind`, `data-closed`) share `question_options/1`: one button per option (`#question-option-<option id>`, `data-option-kind`) and the Other button with its text field.
  - **Poll card**: the "Poll" header, the question, a bar, count and (unless anonymous) voters per option. In a single-choice poll a click picks the option, and a click on the chosen option withdraws the vote. In a multi-select poll a click toggles the option. The footer shows the vote count, the end time or "Closed", "Only named members can vote" for a narrowed poll, Remove vote, and End poll for the author or a moderator.
  - **Ask card**: a "Question" header and the text as Markdown, with no bars, counts or voters. A click on an option answers a single-choice ask. A multi-select ask closes on its first answer too, so a click cannot send each option: the card shows a form (`#question-answer-form-<message id>`) of checkboxes and the Other text, sent as one answer with Send answer (`#question-send-<message id>`). The footer says "Waiting for an answer", then "Answered by <name>" or "Closed without an answer". The answered options stay marked.
  - **Permission card**: a "Permission request" header, the text as Markdown, and options tinted by kind. It shows only while it waits: once closed it leaves the transcript.
  - A prompt's footer has Dismiss for a member with `manage_messages`.
- The card enables its buttons only when the server would allow the answer. The role list it uses was loaded at mount and can be stale; the server decides every answer and a refusal shows as a flash.
