# Threads: following, the sidebar and the thread browser

Status: built. Task: "Thread following, sidebar threads and a thread browser".

A public thread is a channel row of a thread kind whose parent is the channel that hosts it. In a text or announcement channel it starts from a message in that channel (`Tavern.Chat.Threads.create_public_thread/3`). In a forum it is a post, and its first message is inside the thread (forums.md). A thread is visible exactly when the scope may view it under `Tavern.Chat.Visibility` (scoped-reads.md). This document covers who follows a thread, what following changes, and how a session learns about thread activity.

## Follow rules

A member follows a thread when:

| Event | `source` |
|---|---|
| They create it | `:created` |
| They post in it | `:posted` |
| A message in it mentions them by name, and they may view the thread | `:mentioned` |
| They press Follow | `:manual` |

They stop following when they press Unfollow.

The state lives in `thread_followers`, one row per thread and member: `source`, `followed_at`, and `unfollowed_at` (nil while following).

- The automatic sources (`:created`, `:posted`, `:mentioned`) insert a row only when the member has none. A member who already has a row keeps it unchanged.
- Unfollow sets `unfollowed_at` on the row, or inserts a row with it set. Because the row stays, a later post or mention finds a row and changes nothing: a manual unfollow sticks.
- Follow clears `unfollowed_at` and records `source: :manual`. It is the only way back.
- A role mention or `@everyone` follows no one. A mass mention would otherwise put the thread in every member's sidebar.
- An edit that adds a mention follows no one. Only a new message does, so editing an old message does not pull people in.
- Follow and unfollow are domain operations: scope first, decided with `:view_channel` on the thread inside the write's transaction. A thread the scope may not view answers `{:error, :not_found}`.

The follow writes run inside the transaction of the event that causes them: `insert_thread` for `:created`, and `Chat.write_message/3` (the insert step of `Chat.create_message/3` and of a forum post) after the mentions are stored for `:posted` and `:mentioned`. A post and its follow commit together or not at all.

## What following changes

- **Sidebar.** The followed, unarchived threads the member may view appear under their parent channel, newest activity first, with an unread count. At most 5 show per channel; "N more" opens the thread browser on that channel.
- **Notifications.** A followed thread notifies like a channel, under the member's notification settings: any mention (direct, role or default role) when desktop alerts and mention alerts are on and the effective level is not `:nothing`. A thread whose own level is `:default` takes its parent channel's level, so muting a channel mutes its threads. A thread the member does not follow notifies on a direct mention only.

Channels push only mention alerts today; `notify_on_all_messages` is stored but nothing reads it. Followed threads do the same, so they follow any later change to the channel rule without a separate path.

## Last activity

There is no activity column. A thread's last activity is its newest live message's `inserted_at`, or the thread's own `inserted_at` when it has none. Its reply count is its live (not deleted) messages other than its starter. A forum post's starter is inside the post and is not a reply; a text-channel starter is in the parent and was never counted. `Threads.replies_query/1` holds this rule; the browser, the channel summaries and the open thread pane all count with it.

## The thread browser

The Threads button in the header of a thread-hosting channel (`Channel.thread_host?/1`: text, announcement, forum) opens a drawer with Active and Archived tabs. Each lists the channel's threads by last activity, newest first, with a search, reply count, last activity and a Follow toggle. The search splits its text on spaces: a word that starts with `#` is a tag and matches the thread's hashtags exactly (forums.md); each other word must appear in the title (case-insensitive substring). `browse_threads/3` also takes `sort: :created`, which a forum uses.

Both tabs load 25 at a time, paged by keyset on `(last_activity, id)`, or `(inserted_at, id)` when sorted by creation. Paging in SQL is exact because the query is limited to the visible thread ids before it pages, so a page is never short because a row was filtered out afterwards.

The cursor stays on the server, in the LiveView's `:thread_browser` assign; the client sends only "load more".

## Live updates

A session subscribes to the topics of the channels it lists, plus its open channel and open thread (`State.sync_channel_subscriptions/1`). It does not subscribe to every thread. Thread activity reaches it on the parent channel's topic instead:

1. `{:message_created, message}` on the thread's topic, as for any message.
2. `{:thread_message_created, message}` on the parent's topic. A session bumps a followed thread to the top of its sidebar, counts the message unread unless the thread is open or the member wrote it, and decides a notification.
3. `{:thread_followers_changed, thread_id, user_ids}` on the parent's topic, when the message made new followers, and after every manual follow or unfollow. A session whose member is named reloads its followed threads from the database.

The message event goes before the follow event. A session that reloads on the follow event therefore already sees the message in its unread count, and never counts it twice.

Why the parent's topic: a member who may view a thread may view its parent, so every session of an affected member already listens there. Subscribing each session to every thread would grow with the number of threads on the server.

A session may list a parent and still not see a thread under it. So the unfollowed-thread notification re-reads the thread through the scope (`Chat.get_thread/2`) before it shows a message body. A followed thread is already a visible one: the sidebar list came from a scoped read.

`Topics` broadcasts skip the calling process, so the session that posts, creates, follows or unfollows reloads its own sidebar after the call.

Archiving, unarchiving, creating and deleting threads, and role changes already broadcast on the server topic. Each makes every session reload its followed threads.

## Known limits

- A message that reopens an archived thread is broadcast before the reopen (`:channel_updated` on the server topic), so the reload the reopen causes already counts it. Until that reload the thread is not in the sidebar, so the message notifies as in an unfollowed thread: on a direct mention only.
- Opening a thread whose starter message is older than the loaded page of its channel appends the starter at the end of the message list, so the thread pane has a host. This came before this work.

## Forum channels

A forum post is a thread: see forums.md. The follow code, the sidebar and the browser select threads by `Channel.thread?/1` and hosts by `Channel.thread_host?/1`, which includes `:forum`.
