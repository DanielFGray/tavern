# Observability: traces, logs and product events in OpenObserve

Status: built. Task: "Send traces, logs and product events to OpenObserve over OpenTelemetry".

A deploy sends traces and log records to the platform's OpenObserve over OTLP/HTTP (protobuf), under the service name `tavern`. Product events (sign-ups, messages, reactions, moderation and so on) are log records with structured fields, one per action, so OpenObserve panels count them with SQL. There is no OpenTelemetry metrics SDK. A checkout and the tests export nothing.

## When it exports

- The platform sets `OTEL_EXPORTER_OTLP_ENDPOINT` (`http://host.containers.internal:4318`) in every job. In a release (`config_env() == :prod`), `config/runtime.exs` then turns the trace exporter on. Without the variable, and in dev and test always, `config/config.exs` keeps `traces_exporter: :none`.
- `Tavern.Observability.setup/0` runs first in `Tavern.Application.start/2`. When `export?/0` is true it attaches the Bandit, Phoenix (with LiveView) and Ecto instrumentation, the product event log writer and the OTLP log handler. Otherwise it attaches nothing, so dev and test create no spans.
- The exporters append `/v1/traces` and `/v1/logs` to the endpoint. `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` and `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` override one path each, as the OpenTelemetry spec says.
- `service.name` is `tavern` (`config :opentelemetry, resource:`). `OTEL_SERVICE_NAME` overrides it.
- Every trace is sampled. Bandit treats the endpoint as public: a caller's `traceparent` becomes a link, not the parent, so a caller cannot turn sampling off.
- The release lists `opentelemetry_exporter` as permanent and `opentelemetry` as temporary (`mix.exs`), so a crashed SDK stops tracing, not Tavern. `bin/migrate` uses `eval`, which starts neither.

## Traces

- One server span per HTTP request, named by its Phoenix route (`GET /users/confirm/:token`).
- One span per LiveView `mount`, `handle_params` and `handle_event` (`TavernWeb.ServerLive.handle_event#send_message`), from `opentelemetry_phoenix`. A LiveView socket lives for hours, so each callback is its own trace. The spans carry no params.
- One span per Ecto query (`tavern.repo.query:messages`), with `db.statement`. The statement holds `$1` placeholders, never the bound values.

`Tavern.Observability.Redaction` decides what leaves Tavern. For spans it is the trace exporter (`traces_exporter: {Tavern.Observability.Redaction, %{}}`): it copies each batch with these removed, then hands it to `opentelemetry_exporter`. Stdout keeps the full detail.

| Removed | Why |
|---|---|
| `url.path` | Holds the email confirmation token on `/users/confirm/:token`. `http.route` keeps the route. |
| `url.query` | Holds invite codes and the LiveView socket's CSRF token. |
| `client.address`, `network.peer.address` | The member's IP address (the peer is the member when no proxy stands in front). |
| `db.url` | `opentelemetry_ecto` copies the Repo URL, password included. |
| `exception.message`, `exception.stacktrace` on an exception event | They print values: a `KeyError` prints the whole map, a function clause error its arguments. `exception.type` stays. |
| The status message | `opentelemetry_ecto` puts the database error there, whose detail can quote a row (`Key (email)=(...) already exists`). The error code stays. |

## Logs

Every `Logger` record at `:info` and above goes to OpenObserve, through one `:logger` filter on the OTLP handler, `Redaction.filter_log_event/2`:

- Phoenix's per-request lines (`GET /users/confirm/<token>`) are dropped: they print the raw path, and the request span already records the request.
- Product event records pass unchanged.
- Every other record keeps only a fixed list of metadata keys (`mfa`, `file`, `line`, `domain`, `application`, `pid`, `request_id`, the trace ids). Other metadata can hold a `Plug.Conn` (Bandit sets `conn`), a crash reason, or whatever a caller passed.
- A crash record (one with `crash_reason`) gets a new message: `crashed: <exception or exit type>` and the code locations of its stacktrace, without arguments. The original prints the process state and its last message, which hold message text, emails and usernames. Stdout keeps the original.
- Any other message goes as written, so a log line names no member input: `Chat.Embeds` names the message of a link preview it could not store, not its URL; `ServerLive` logs at most 40 characters of an unknown event's name; a bounced mail's reason names no address. Cloudflare's own error text is logged as it comes.
- The OTLP log handler comes from `opentelemetry_experimental` (0.6.0), the only Erlang OTLP log handler. Its API may change between minor versions.

## Product events

`Tavern.ProductEvents.record/1` emits `[:tavern, :product_event]` with `:telemetry`. `Tavern.Observability` writes each one as a log record: the body is `product event <name>`, and each field is an attribute.

Where they come from:

- `Tavern.Chat.Topics` passes every server and channel broadcast to `record/1`. Callers broadcast after their transaction commits, and only the writing node broadcasts, so each event is emitted once, for committed data only. Broadcasts that are no product event (typing, re-renders, embeds, sidebar reloads) emit nothing.
- Writes that broadcast nothing call `record/1` after their commit: `Accounts` (sign-up, first verification, sessions, deletion), `Chat.Moderation` (every action through `moderate/4`, scheduled deletion, rejoin), `Chat.Invites.create_invite/2` and `Chat.Emojis.create_custom_emoji/3`.
- `Chat.AuditLog.record!/5` emits nothing: it runs inside the transaction, so a rollback would leave an event for a change that never happened.

Privacy:

- No message text, email, username, display name, invite code or IP address.
- A member appears only as a **pseudonym**: the first 16 bytes, hex encoded, of HMAC-SHA256 of the member id, under a key that is itself HMAC-SHA256 of `secret_key_base`. It is stable while `secret_key_base` is, so a member's events link up, and it cannot be turned back into the id without the secret. `Tavern.ProductEvents.pseudonym/1` computes it, for example in a remote console when a known member must be found.
- Channel ids and names are included.
- A thread appears only by its id (`thread_id`). Its title is text a member wrote, or, until someone names it, the start of its starter message (`Channel.title/1`). Its channel, which always has a name, names it.
- A field with no value is left out, never nil: the OTLP exporter would write `nil` as the string `"nil"`.

Counting starts on the ship date: there is no backfill.

### Events

Every event also has `event`, its name. `member` is the acting member unless the event says otherwise; `actor` is the moderator or manager who acted on `member`.

An event that happens somewhere carries its **place**: `channel_id`, `channel_name` and `channel_kind` (`text`, `forum`, ...) of the channel, and `thread_id` when it happened in a thread or forum post. For a thread, the channel is the thread's parent, so per-channel panels count thread activity under its channel.


| Event | Fields | Emitted when |
|---|---|---|
| `member.signed_up` | `member`, `invited` (bool) | An account registers; `invited` when it used an invite code. |
| `member.verified` | `member` | An account confirms an address for the first time, by its confirmation link or by an email change. A verified member changing address emits nothing. |
| `member.moderated` | `action` (`timeout`, `kick`, `ban`, `unban`), `actor`, `member` | A moderation action commits. |
| `member.deletion_scheduled` | `actor`, `member` | A kick that schedules the account's deletion. A `member.moderated` with `action` `kick` comes with it. |
| `member.rejoined` | `member` | A kicked member rejoins with an invite. |
| `member.deleted` | `member`, `by` (`sweep`, `self`, `moderator`) | An account is deleted. `sweep` is the scheduled deletion running. Deleting an account already deleted emits nothing. |
| `session.seen` | `member` | A member signs in, or uses a session last used 5 or more minutes ago (an HTTP request or a LiveView connect). The member had Tavern open. |
| `message.created` | `member`, `author_kind` (`person`, `bot`, `system`), `message_kind` (`default`, `reply`, `system`, `thread_starter`, ...), `poll` (bool), place | A message is sent, by the web client, a bot or a forum post. A poll is a message with `poll` true. |
| `reaction.added`, `reaction.removed` | `member`, `emoji_kind` (`unicode`, `custom`), place | A reaction toggles on or off. |
| `poll.voted` | `member`, place | A vote, a changed vote or a withdrawn vote. |
| `poll.closed` | `reason` (`closed_by_hand`, `time`, `max_voters`), place | A poll closes. |
| `thread.created` | `member`, place | A thread or forum post starts; `channel_kind` `forum` marks a forum post. A repeated request to thread the same message emits nothing: it returns the existing thread, which `Chat.Threads` does not broadcast. |
| `channel.created` | place | A channel or category is created. |
| `invite.created` | `actor`, place | A manager creates an invite. Invites made by approving an invite request are not counted. |
| `upload.created` | `member`, `kind` (`emoji`) | A custom emoji is uploaded. |

`test/tavern/product_events_test.exs` checks that each event carries exactly these fields.

## Panels

The queries below are OpenObserve SQL over the logs stream. Two things are not yet checked against the live instance, and the agent who builds the dashboard checks them first: the stream name (written here as `"default"`) and how OpenObserve names attribute columns (written here as the attribute name, with `service_name` for `service.name`). `_timestamp` is OpenObserve's record time; `histogram(_timestamp, '1 day')` buckets it.

Messages per day:

```sql
SELECT histogram(_timestamp, '1 day') AS day, count(*) AS messages
FROM "default"
WHERE service_name = 'tavern' AND event = 'message.created'
GROUP BY day ORDER BY day
```

Messages per day per channel, with thread messages under their channel:

```sql
SELECT histogram(_timestamp, '1 day') AS day, channel_name, count(*) AS messages
FROM "default"
WHERE service_name = 'tavern' AND event = 'message.created'
GROUP BY day, channel_name ORDER BY day
```

People against bots, per day:

```sql
SELECT histogram(_timestamp, '1 day') AS day, author_kind, count(*) AS messages
FROM "default"
WHERE service_name = 'tavern' AND event = 'message.created'
GROUP BY day, author_kind ORDER BY day
```

Active members per day (had Tavern open or posted):

```sql
SELECT histogram(_timestamp, '1 day') AS day, count(DISTINCT member) AS active
FROM "default"
WHERE service_name = 'tavern'
  AND (event = 'session.seen' OR (event = 'message.created' AND author_kind = 'person'))
GROUP BY day ORDER BY day
```

Members who posted per day:

```sql
SELECT histogram(_timestamp, '1 day') AS day, count(DISTINCT member) AS posters
FROM "default"
WHERE service_name = 'tavern' AND event = 'message.created' AND author_kind = 'person'
GROUP BY day ORDER BY day
```

Sign-ups, verifications and deletions per day (net member change since the ship date):

```sql
SELECT histogram(_timestamp, '1 day') AS day, event, count(*) AS members
FROM "default"
WHERE service_name = 'tavern'
  AND event IN ('member.signed_up', 'member.verified', 'member.deleted')
GROUP BY day, event ORDER BY day
```

Moderation actions per day, by action:

```sql
SELECT histogram(_timestamp, '1 day') AS day, action, count(*) AS actions
FROM "default"
WHERE service_name = 'tavern' AND event = 'member.moderated'
GROUP BY day, action ORDER BY day
```

Other activity per day (reactions, threads, polls, votes, invites, uploads):

```sql
SELECT histogram(_timestamp, '1 day') AS day,
       CASE WHEN event = 'message.created' THEN 'poll.created' ELSE event END AS activity,
       count(*) AS count
FROM "default"
WHERE service_name = 'tavern'
  AND (event IN ('reaction.added', 'thread.created', 'poll.voted', 'invite.created', 'upload.created')
       OR (event = 'message.created' AND poll = true))
GROUP BY day, activity ORDER BY day
```

Busiest channels this week:

```sql
SELECT channel_name, count(*) AS messages, count(DISTINCT member) AS posters
FROM "default"
WHERE service_name = 'tavern' AND event = 'message.created'
  AND _timestamp >= now() - INTERVAL '7 days'
GROUP BY channel_name ORDER BY messages DESC LIMIT 10
```

## Limits

- The total member count is not an event. Events give sign-ups and deletions from the ship date on; the count before it lives only in Postgres.
- A server icon upload emits no `upload.created`: settings writes broadcast only a cache drop, and the icon change is not visible after the commit.
- App cartridges cannot declare OpenObserve dashboards, so the dashboard is built by hand in OpenObserve from the queries above.
