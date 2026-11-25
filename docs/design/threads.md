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

The follow writes run inside the transaction of the event that causes them: `insert_thread` for `:created`, and `Chat.Messages.write_message/3` (the insert step of `Chat.create_message/3` and of a forum post) after the mentions are stored for `:posted` and `:mentioned`. A post and its follow commit together or not at all.

## What following changes

- **Sidebar.** The followed, unarchived threads the member may view appear under their parent channel, newest activity first, with an unread count. At most 5 show per channel; "N more" opens the thread browser on that channel.
- **Notifications.** A followed thread alerts like a channel, under the member's level and settings. A thread whose own level is `:default` takes its parent channel's level, so muting a channel mutes its threads. A thread the member does not follow alerts on a direct mention only. `Tavern.Chat.Alerts` decides this once per message (docs/design/push-notifications.md, "The alert rule").

## Last activity

There is no activity column. A thread's last activity is its newest listed message's `inserted_at`, or the thread's own `inserted_at` when it has none. Its reply count is its listed messages (`Message.listed?/1`: not deleted, and not a closed permission request, questions.md) other than its starter. A forum post's starter is inside the post and is not a reply; a text-channel starter is in the parent and was never counted. `Threads.replies_query/1` holds this rule; the browser, the channel summaries and the open thread pane all count with it.

## The thread browser

The Threads button in the header of a thread-hosting channel (`Channel.thread_host?/1`: text, announcement, forum) opens a drawer with Active and Archived tabs. Each lists the channel's threads by last activity, newest first, with a search, reply count, last activity and a Follow toggle. The search splits its text on spaces: a word that starts with `#` is a tag and matches the thread's hashtags exactly (forums.md); each other word must appear in the title (case-insensitive substring). `browse_threads/3` also takes `sort: :created`, which a forum uses.

Both tabs load 25 at a time, paged by keyset on `(last_activity, id)`, or `(inserted_at, id)` when sorted by creation. Paging in SQL is exact because the query is limited to the visible thread ids before it pages, so a page is never short because a row was filtered out afterwards.

The cursor stays on the server, in the LiveView's `:thread_browser` assign; the client sends only "load more".

## The thread pane

An open thread renders under its starter message as a flat region (`Threads.thread_panel`, `#thread-panel-<starter id>`): a left rule and indentation, no card. A forum post shows the same region in place of the post list.

- **Header**: title, reply count, a bell that follows or unfollows (`#toggle-follow-thread-*`), and a close button (`#close-thread-*`). Archive or Unarchive and Lock or Unlock sit in a ⋯ menu (`#thread-actions-*`), shown only when the member may do one of them. Locked and Archived show as text badges.
- **Rows**: the thread's messages render with the channel's row, `Messages.message_item`. A row takes the rights of the conversation that holds it (`Helpers.message_rights/2`): the open thread's for a thread message, the channel's for any other. A thread row has no thread chip and no Start thread action. In a text channel the thread's rows are inside the starter's stream item, so re-rendering a thread row re-inserts the starter too (`State.rerender_messages/2`, `State.stream_update_message/2`).
- **No inner scroll box**: the region grows inside the channel's message list, because a row's reaction picker and action menu are popovers that a clipping box would cut.
- **One composer**: while a thread is open the channel composer and its typing indicator are hidden, and the thread's composer (`Composer.composer`, target `:thread`) is the only one. Both targets share `:reply_to_message`. Reply on a channel message while a thread is open closes the thread first.
- **URL**: `?channel=<slug>&thread=<id>` opens the thread inline, and the region scrolls into view when it mounts. Closing the thread patches the URL back to the channel, so a reload does not reopen it.

## Live updates

A session subscribes to the topics of the channels it lists, plus its open channel and open thread (`State.sync_channel_subscriptions/1`). It does not subscribe to every thread. Thread activity reaches it on the parent channel's topic instead:

1. `{:message_created, message}` on the thread's topic, as for any message.
2. `{:thread_message_created, message}` on the parent's topic. A session bumps a followed thread to the top of its sidebar, counts the message unread unless the thread is open or the member wrote it. Alerts do not come this way: they arrive on the member's own topic.
3. `{:thread_followers_changed, thread_id, user_ids}` on the parent's topic, when the message made new followers, and after every manual follow or unfollow. A session whose member is named reloads its followed threads from the database.

The message event goes before the follow event. A session that reloads on the follow event therefore already sees the message in its unread count, and never counts it twice.

Why the parent's topic: a member who may view a thread may view its parent, so every session of an affected member already listens there. Subscribing each session to every thread would grow with the number of threads on the server.

A session may list a parent and still not see a thread under it. So an alert is decided on the server, which checks each member's view of the thread with their own scope before the alert carries a message body.

`Topics` broadcasts skip the calling process, so the session that posts, creates, follows or unfollows reloads its own sidebar after the call.

Archiving, unarchiving, creating and deleting threads, and role changes broadcast on the server topic. Each makes every session reload its followed threads. A delete arrives as `{:channel_deleted, thread}` ("Deleting a thread" below).

## Known limits

- A message that reopens an archived thread is broadcast before the reopen (`:channel_updated` on the server topic), so the reload the reopen causes already counts it. Until that reload the thread is not in the sidebar, so the message notifies as in an unfollowed thread: on a direct mention only.
- Opening a thread whose starter message is older than the loaded page of its channel appends the starter at the end of the message list, so the thread pane has a host. This came before this work.

## Forum channels

A forum post is a thread: see forums.md. The follow code, the sidebar and the browser select threads by `Channel.thread?/1` and hosts by `Channel.thread_host?/1`, which includes `:forum`.

## Deleted messages

A deleted message is hidden, not shown as a tombstone. It keeps its row (`deleted_at`, body replaced) so the event log, a reply's quote line and a cursor still resolve, but no list, count or unread total includes it, live or after a reload. It takes no action: edit, reaction, delete, thread start and a new reply to it all fail (a reply with a `reply_to_id` error, the others `{:error, :not_found}`; scoped-reads.md). `Chat.list_messages/3` leaves it out of channel and thread pages, the bot API's `GET /api/v1/channels/:id/messages` included. A cursor may still name it (bot-api.md). The `message.deleted` event stays.

- **Live delete.** A delete removes the row from every open view (`State.stream_update_message/2` calls `stream_delete`). `State.rerender_messages/2` skips deleted messages, so no later re-render brings the row back.
- **Replies.** A reply keeps its quote line when the quoted message is deleted, and shows "Original message deleted" (`#reply-deleted-<reply id>`) in place of the body. The read still preloads the reply target. A viewer who already has the reply open sees the old quote until the row renders again.
- **Starters.** Deleting a starter never deletes its thread or its replies. In a text channel the starter's row becomes a tombstone that reads "Original message was deleted", with no author, body or message actions. The thread chip and panel hang under it as they do under a live starter. A tombstone is listed only while its thread is live (`Message.where_transcript/1`); a deleted message that starts no thread leaves the channel. Live updates follow the same rule: deleting a starter turns its row into the tombstone in every open session. A thread whose starter was deleted and that has no name is titled "Deleted message", drawn muted and italic in the sidebar, the thread browser, the panel header and the forum post list; no part of the deleted text is shown as a title or searched as one. A forum post whose first message was deleted stays a post (forums.md), with that title.

## Deleting a thread

A thread is deleted by its own action, never by deleting its starter. A member with `manage_messages` in the parent channel (the thread creator holds no right to it) picks "Delete thread" in the thread panel menu and confirms. The confirm step is client-side: the menu item swaps for "Delete" and "Cancel" buttons.

- `Chat.delete_thread/2` (`Channels.delete_thread/2`) runs through the channel write path: it takes the tree lock, decides `:delete_thread` (`Visibility`: a thread, viewable, with `manage_messages` in its parent), sets `deleted_at` on the thread row and inserts a `thread_deleted` audit entry in one transaction. The thread keeps its messages, which `Visibility` hides with it. A forum post takes the same action under the same rule. `Channels.delete_channel/2` still refuses a thread.
- It broadcasts `{:channel_deleted, thread}` on the server topic. `Navigation.handle_info/2` handles it for threads: a session that has the thread open leaves it with the flash "Thread deleted.", then every session reloads its channels, followed threads, thread browser and forum post list, and refreshes the reply pill under the starter. The deleter's own session runs the same handler, because `Topics` skips the calling process.
- A deleted thread is not restorable: `:restore_channel` refuses threads, so the deleted-channels list never offers one.
- The thread panel menu shows the item when `Chat.can_delete_thread?/2` holds, so a manager sees it even when the thread is locked or archived.
