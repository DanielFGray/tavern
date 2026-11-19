# Forums: posts as threads, hashtag tags, list and gallery

Status: built. Task: "Forum channels: posts as threads, hashtag tags, list and gallery".

A forum is a channel of kind `:forum`. It shows a list of posts, not a message transcript. A post is a public thread under the forum (threads.md), so following, the sidebar, the thread browser, archive, lock and slowmode work on posts as on any thread. `Tavern.Chat.Forums` holds the post operations; `Tavern.Chat.Hashtags` holds the tag rule.

## A post

A post is a `:thread_public` channel row whose parent is the forum. Its name is the post title. Its first message is in the thread itself, and the thread's `starter_message_id` points at it. In a text channel the starter is in the parent; that is the one difference, and `Threads.replies_query/1` absorbs it: a starter is never a reply.

`Forums.create_post/3` takes `title` (at most 40 characters, the thread name rule) and `body` (at most 4000). It runs in one transaction:

1. Authorize `:create_public_threads` on the forum (`Visibility.authorize_write`), so a forum the scope may not view answers `{:error, :not_found}`.
2. Lock the forum row. A channel that is not a forum answers `{:error, :not_found}`.
3. Apply the forum's slowmode to posts: the author's newest post in the forum must be older than `slowmode_seconds`, unless the author may `:bypass_slowmode`. A refusal is `{:error, {:slowmode, seconds_left}}`.
4. Insert the thread and follow it as its creator (`:created`).
5. Write the first message with `Chat.write_message/3`, which stores mentions and follows as a normal message does. Step 1 already decided the send right: creating a public thread needs `:send_messages` in the host (`Visibility`), so the poster needs both rights.
6. Set `starter_message_id` and the hashtags.

After the commit it broadcasts `{:channel_created, thread}` on the server topic, then the message events. The new thread is in every session's channel list before its message arrives.

A forum takes no top-level messages. `Visibility` answers false for `:send_messages` on a `:forum` channel, so `Chat.create_message/3` there is `{:error, :forbidden}`, and the composer and typing indicator do not show. Inside a post the thread rules apply.

## Tags

Tags are hashtags in the title and the first message. `Hashtags.extract/2` reads them with one regex:

- `#` followed by 1 to 50 letters, digits, `_` or `-` (Unicode letters and digits count).
- The `#` must not follow a letter, digit, `_`, `-`, `/`, `&` or `#`. This skips URL fragments (`page#top`) and HTML entities (`&#39;`).
- Tags are lowercased and deduplicated, title first. At most 10 are kept.

They are stored in `channels.hashtags`, a `text[]` with a GIN index, so the exact-tag filter (`hashtags @> ARRAY[...]`) uses the index.

The tags are written when a thread is created, and again when its starter message is edited (`Chat.update_message/3` calls `Threads.retag_started_thread/1` in its transaction, and broadcasts `{:channel_updated, thread}` when they changed). This applies to every public thread, not only posts: a text-channel thread takes its tags from its name and its starter. Threads made before this change have empty tags until their starter is edited; there is no backfill.

## Listing and search

`Forums.list_posts/3` checks that the scope may view the forum, then reads through `Threads.browse_threads/3` with the `:tab` of the post list (`:active` by default, or `:archived`), so a list holds one tab and every row passed `Visibility`. A search runs within that tab. It adds to each entry the first message (with author), the first message's top reaction with its count, and `image_url`.

- **Sort**: `:activity` (newest reply, or creation; the default) or `:created`. Both page by keyset, 25 at a time.
- **Search**: the forum search and the thread browser share one parser, `Hashtags.split_query/1`. A word that starts with `#` filters by exact tag; every tag must match. Each other word must appear in the title.
- **Top reaction**: the reaction with the most members on the first message; the oldest wins a tie.
- **Gallery image**: the first link-preview image of the first message. Message attachments are not built yet, so a post has no uploaded image to show; when attachments exist the gallery should prefer the first attached image.

## Remembered view

Each member's sort and layout (`:list` or `:gallery`) per forum live on `channel_memberships` (`post_sort`, `post_layout`). `Forums.set_post_view/3` upserts only the keys it is given; a member with no row sees the defaults.

## The LiveView

`ServerLive.ForumNav` keeps the `:forum` assign: the forum, its view, the search, the loaded entries, the cursor and the New post form. It is nil when the open channel is not a forum. The list is a plain assign, not a stream, because a sort, layout or search change replaces it whole, and a page is at most 25 rows plus the pages the member loaded.

The list reloads when a post is created or changes (`:channel_created`, `:channel_updated`), when a message lands in one of its posts, and when the member closes a post. The top reaction is not pushed live; it updates on the next reload.

Opening a post patches the URL to `?channel=<forum>&thread=<post>`. The forum view then renders the thread pane with the first message as its host, instead of the list.

DOM ids: `#forum-view`, `#forum-search`, `#forum-sort` and `#forum-layout` (each option `#forum-sort-<value>`, `#forum-layout-<value>`), `#new-forum-post`, `#forum-post-form`, `#forum-posts`, `#forum-post-<id>`, `#forum-post-tag-<id>-<tag>`, `#forum-empty`, `#forum-more`.

## Known limits

- No attachments in the New post form, and no uploaded gallery image (see Listing).
- A forum's sidebar unread count stays at zero: its messages are all in posts.
- Out of this build: moderator-defined tags, required tags and post guidelines.

## Active and archived posts

The post list shows active posts only. An Active/Archived switch (`#forum-tab`, beside the sort and layout switches) selects the archived ones, with the same unarchive control in the open post's ⋯ menu. The tab is per view, not remembered. The search, the sort and paging all run within the selected tab, and an empty tab says so. A post that is archived, unarchived or reopened by a reply moves between the tabs when the forum reloads on `:channel_updated`. The list has no "Archived" badge, because an archived post can no longer appear in it.

## Deleted first messages

A deleted message is hidden from every list (threads.md). A post whose first message was deleted stays a post: it keeps its row in the list (no excerpt or author line), and the first message's row inside the open post is hidden like any deleted message.
