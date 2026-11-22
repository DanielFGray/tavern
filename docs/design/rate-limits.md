# Rate limits

Tavern has one rate-limit mechanism, `Tavern.RateLimit`. Each limit is a small module that names its buckets and calls it. A **bucket** is `{key, limit, window_seconds}`: at most `limit` hits in a window.

## The mechanism

- **Fixed windows.** A window starts at the bucket's first hit and lasts `window_seconds`. The count lives in Valkey (`Ephemeral.increment_rate_limit/3`: `INCR`, then `EXPIRE ... NX`), so it holds across nodes, and a retry inside the window does not extend it. Every key sits under `rate_limit:`.
- **All buckets count, and a refusal spends no allowance.** `RateLimit.hit/2` counts one hit in each bucket of a call. When any bucket is over its limit, it returns `{:error, {:rate_limited, seconds}}`, where `seconds` is the longest wait among the buckets that are over, and hands the hit back to each bucket that was within its limit. So a script that keeps hammering does not use up a bucket that still had room, and the wait it gets is the real one.
- **A bucket over its limit keeps its count.** The extra count admits nothing more in a fixed window. Handing it back would race the window's end: a `DECR` that lands after the key expired starts the next window at −1 and admits one hit too many. A one-second window, such as the bot edit cap, would meet that race often.
- **Concurrent hits cannot overshoot.** `INCR` is atomic, and a hit is admitted only when its own increment is within the limit. A hit that is handed back never lowers the count below the hits that were admitted.
- **A hung Valkey costs at most 250 ms.** The rate-limit calls in `Tavern.Ephemeral` carry a 250 ms timeout instead of the client's default 5 s, because the message check runs inside the send's transaction. A timeout is an outage, and the limit's outage policy applies.
- **The outage policy is part of each limit.** When Valkey cannot be reached:
  - `:refuse` returns `{:error, :unavailable}`. Use it for actions that must not ride an outage.
  - `:count_locally` counts in this node's ETS table instead (owned by the `Tavern.RateLimit` process). Use it for actions that Valkey must not be able to stop. Each node then counts on its own, so a member gets up to one allowance per node until Valkey returns.
- `RateLimit.release/1` hands back a hit for an admitted action that did not happen. `RateLimit.clear/1` ends one bucket's window. `RateLimit.reset!/1` clears a namespace, for tests.

## The limits

| Limit | Module | Buckets | Outage | Why that outage policy |
| --- | --- | --- | --- | --- |
| Messages | `Tavern.Chat.SendLimit` | per member: 10 per 10 s, 120 per 5 min | count locally | Valkey must not stop the chat |
| Login attempts | `Tavern.Accounts.LoginRateLimiter` | per IP: 20 per 5 min; per IP and email: 5 per 5 min | count locally | Valkey must not stop logins |
| Email-link mail | `LoginRateLimiter.check_email_link/1` | per account: 3 per 15 min | count locally | as for logins |
| Invite requests and invite mail | `Tavern.Chat.InviteRequestLimits` | see invite-requests.md | refuse | a stranger's form must not become mail by riding an outage |
| Bot edits | `Tavern.Bots.EditLimit` | per message: `message_edits_per_second` per 1 s | refuse | an edit can wait; nothing breaks without it |

The message windows live in `config :tavern, Tavern.Chat.SendLimit, windows: [{messages, seconds}]`, so they can be tuned without code. The test environment raises them (`config/test.exs`), because fixtures and the e2e seed commands send dozens of messages from one author in a second; the send-limit tests set their own windows.

## The message limit

**One allowance per member.** A person and a bot are both members, and every message they write counts against one allowance, in any channel or thread. The key is the member's user id.

**One enforcement point.** Every message write goes through `Tavern.Chat.Messages.write_message/3`: `Chat.create_message/3` (the browser composer, the bot API `POST /api/v1/channels/:id/messages`, the bot `send_message` command, and the user API `POST /api/v1/user/channels/:id/messages`), questions (`Questions.create_question/3`, through `send_message/4`) and forum posts (`Forums.create_post/3`). `write_message/3` counts the hit first, before its own queries, so a refused message or question costs one Valkey round trip and no insert. A forum post inserts its thread before `write_message/3` runs; the refusal rolls back the caller's transaction, so a refused post leaves no thread.

**What counts.** A send counts once it passes the visibility, permission and slowmode checks that come before `write_message/3`. A send that fails after the count (an invalid body, a reply to a message elsewhere, a refused mention) still counts: the count is of attempts, and handing it back would need a second Valkey round trip on every failure.

**The numbers.** A fast typist sends a burst of short lines ("yes", "lol", "one sec") at about one a second, and a busy conversation rarely holds more than a dozen messages a minute for long. A script sends many a second.

- 10 messages per 10 seconds allows a typist's burst. A script reaches it in its first second.
- 120 messages per 5 minutes (24 a minute) allows a long lively conversation. It holds a script that keeps the burst pace (60 a minute) to about 24 a minute on average.

**The answer.** A refusal is `{:error, {:rate_limited, seconds}}`. The browser flashes "You are sending messages too fast. You can send again in Ns." and keeps the draft in the composer. The bot API, the bot command endpoint and the user API answer 429 `rate_limited` with `retry_after` and a `Retry-After` header, the same shape as a refused bot edit.

**Slowmode is separate.** Slowmode (`Tavern.Chat.Slowmode`) is a rule one channel sets, and members with `:bypass_slowmode` are exempt. The send limit applies to every member everywhere; no permission bypasses it.

## Not tested

The tests use windows of an hour or more and finish inside one, so no test depends on the clock. The end of a window is Valkey's `EXPIRE`, which no test drives. The outage policies are tested by stopping the `Tavern.Valkey` client (`test/tavern/rate_limit_test.exs`). The browser refusal is tested in LiveView (`test/tavern_web/send_limit_test.exs`), not in Playwright: the e2e server shares the raised test windows, because e2e specs seed dozens of messages from one author.
