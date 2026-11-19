# Polls: a question with options, voted in the transcript

Status: built. Task: "Polls".

A poll is a message with a question and 2 to 10 options. Members vote on a card in the transcript, in a channel, a thread or a forum post. Bots create polls through the bot API and receive each vote as an event. An agent question is a poll that one named member answers once. `Tavern.Chat.Polls` holds the operations; `Chat` delegates to it.

## Data

- `polls`: one row per poll message (`message_id`, unique). `multi_select`, `anonymous`, `allow_other`; `closes_at` (nil means the author ends it by hand); `closed_at`; `max_voters` (nil or above 0); `voter_user_ids` and `voter_role_ids` (empty means not narrowed).
- `poll_options`: `position` and `label` (at most 80 characters). Labels are free text, so a bot can use its own words (`once`, `always`, `reject`).
- `poll_ballots`: one row per voter and poll, unique on `(poll_id, user_id)`. It holds `option_ids` and `other_text` (at most 200 characters). A withdrawn vote deletes the row.

The question is the message body. `Message.kind` has no poll value: a message is a poll when it has a `poll` row, and the read preloads load it with its options and ballots. A poll message cannot be edited (`Chat.update_message/3` answers `{:error, :forbidden}`), because a new question would change what the votes answered. Deleting the message deletes the poll.

## Creating a poll

`Polls.create_poll(scope, channel_id, attrs)` validates `change_poll/1`:

- `question`: required, at most 300 characters.
- `options`: trimmed, blanks dropped, duplicates (ignoring case) refused; 2 to 10 must remain.
- `duration_minutes`: 60 to 10080 (1 hour to 7 days), or nil for a poll ended by hand.
- `max_voters`, `voter_user_ids`, `voter_role_ids`, `multi_select`, `anonymous`, `allow_other`.

It sends the message through `Chat.send_message/4`, so the send rules apply unchanged: `Visibility.authorize_write`, timeouts, slowmode, locked and archived threads. A message to an archived thread reopens it, as any message does. The poll rows are written in the same transaction as the message.

## Who may vote

Each vote is decided in its transaction, in this order:

1. `Visibility` decides `:vote_in_poll`: the member may send in the channel, is not timed out, and the thread is not locked or archived. A closed thread refuses a vote as it refuses a reaction: a vote never reopens an archived thread. A channel the member may not view answers `:not_found`.
2. The poll row is locked (`FOR UPDATE`), after the membership and message rows. A vote, a close by hand and the closer all take this lock, so a vote never lands on a closed poll, and a poll closes once.
3. A closed poll refuses with `:poll_closed`.
4. A narrowed poll also requires the member to be in `voter_user_ids` or to hold a role in `voter_role_ids`. The list narrows step 1 and never widens it: a named member who may not send still cannot vote.
5. The choice must name this poll's options. A single-choice poll takes one answer: one option, or the Other text. Other text needs `allow_other`. A refusal is `:invalid_choice`.

A vote with no option and no Other text withdraws the member's vote. Sending a new choice replaces the old one.

## Closing

A poll closes in three ways. Each sets `closed_at` under the poll lock and broadcasts `{:poll_closed, message, reason}`.

- **By hand** (`:closed_by_hand`): `Polls.close_poll/2`. The author, or a member with `manage_messages` in the channel. A locked or archived thread does not block it.
- **After N votes** (`:max_voters`): the vote that brings the number of voters to `max_voters` closes the poll in its own transaction.
- **At its end time** (`:time`): `Tavern.Chat.PollCloser`, a GenServer, wakes at the earliest `closes_at` (and at least every 60 seconds) and calls `Polls.close_due/1`. That locks due polls with `SKIP LOCKED` and sets `closed_at` to `closes_at`. `Poll.closed?/2` also treats a passed `closes_at` as closed, so a vote between the end time and the closer's run is refused. `config :tavern, :poll_closer, false` turns the closer off in tests, which call `close_due/1` directly.

Results stay visible after a poll closes.

## Results

`Polls.results(poll, viewer_id)` is pure. It gives each option's count and voters, the Other answers, the number of voters and the viewer's own ballot. An anonymous poll gives counts only: no option voters, and Other answers without their authors. Counts are per voter, so in a multi-select poll the option counts can add up to more than the voter count.

## Events

After its transaction, a vote broadcasts `{:poll_voted, message, %{user_id, option_ids, other_text}}` on the channel topic. LiveView sessions re-render the card. The bot event stream sends:

- `poll.voted`: `message_id`, `channel_id`, `poll` (the serialized poll with counts) and `vote` (`user_id`, `option_ids`, `options` with `id` and `label`, `other_text`). In an anonymous poll `vote` is null. A withdrawn vote sends `poll.voted` with empty `option_ids` and null `other_text`.
- `poll.closed`: `message_id`, `channel_id`, `reason` (`closed_by_hand`, `max_voters` or `time`) and `poll`.

Every serialized message carries `poll` (null when the message has none).

## Bot API

- `POST /api/v1/channels/:channel_id/polls` with `{"poll": {...}}` takes the `change_poll/1` fields. 201 with the message; 422 `invalid_poll` with the changeset errors; 404 for a channel the bot may not view; 403 when it may not send.
- `GET /api/v1/messages/:message_id/poll` reads the message with its poll. 404 when the message has no poll.
- `POST /api/v1/messages/:message_id/poll/close` ends it. 409 `poll_closed` when it already closed.

Bots do not vote through the API.

An agent question is a poll with `voter_user_ids: [the person]`, `max_voters: 1` and, for a free answer, `allow_other: true`. The bot waits for `poll.voted` or `poll.closed`, and reads the chosen labels and the Other text from the event. Tavern stores no agent-specific fields.

## UI

- **Composer**: a chart button (`#open-poll-button`, or `#thread-open-poll-button` in a thread) opens the poll form (`#poll-form`) above the one composer. The form has the question, option inputs with add and remove, an end time (1 hour to 7 days, or by hand; 24 hours by default) and checkboxes for several answers, an Other answer and hidden voters. The poll goes where the composer writes: the open thread, else the open channel. The form closes when the conversation changes. Narrowed voters and `max_voters` are set only through the context and the bot API.
- **Card** (`#poll-<message id>`, `data-closed`): the question, one button per option with a bar for its share, its count and, unless anonymous, its voters. In a single-choice poll a click picks the option, and a click on the chosen option withdraws the vote. In a multi-select poll a click toggles the option. The Other button opens a text field. The footer shows the voter count, the end time or "Closed", "Only named members can vote" for a narrowed poll, Remove vote, and End poll for the author or a moderator.
- The card enables its buttons only when the server would allow the vote. The role list it uses was loaded at mount and can be stale; the server decides every vote and a refusal shows as a flash.
