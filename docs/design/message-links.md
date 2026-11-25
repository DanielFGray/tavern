# Message links

Status: built.

A link can open one message in place. The chat page loads the messages around it, scrolls it to
the middle of the view and flashes it. Search results, pins, reply previews and alerts all use
this link.

## The link

`/?channel=<slug>&message=<id>`, `/?channel=<parent slug>&thread=<id>&message=<id>` for a
message in a thread, or `/?dm=<id>&message=<id>` for a message in a direct message
(docs/design/direct-messages.md). `TavernWeb.ServerLive.MessageJump.message_path/3` builds it on the chat
page. `Tavern.Chat.Alerts` builds the same URL for desktop and push alerts, because the domain
cannot call the web layer.

- A search result, a row in the Pins drawer and a reply's "Replying to" line each send
  `open_message` or patch to the link. A click on a pin also closes the drawer.
- A reply preview is a button inside the row's `toggle_message_controls` area. LiveView fires
  only the closest `phx-click`, so the click does not also toggle the row's controls.

## The window

A pane (the channel transcript, or the open thread's) holds one of two things:

- **The newest page.** The newest 50 messages. New messages join the end, and the conversation
  is marked read.
- **A window.** Up to 25 messages before the linked message, the message, and up to 25 after
  it (`Chat.list_messages/3` with `around:`). `Pane.newer_cursor` is set while newer messages
  exist past the window.

While a pane holds a window:

- A new message does not join the stream, because there would be a gap before it. The header
  count still goes up.
- Nothing marks the conversation read. `mark_channel_read/3` writes the marker as given, so a
  window would move it back. A window whose last row is the newest message marks it read, as
  the newest page does.
- "Load newer messages" under the last row loads the next page. `MessageListHook` presses it
  when the reader scrolls down to it.
- "Jump to present" sticks to the bottom of the scroll box. A page that loads under it would
  otherwise move it away from the pointer.

A pane loads the window when it opens with a `message` in the URL (`MessageJump.target/3`), and
again when the URL names another message (`MessageJump.follow/1`). A URL without a message
leaves the window in place, so opening or closing a thread, or browser Back, keeps the reader's
place. The reader returns to the newest page with "Jump to present" or by sending a message
(`MessageJump.present/2`), which also drops `message` from the URL.

A message the conversation does not list (deleted, hidden, or in another conversation) shows
the newest page and one flash, "That message is not available", the same for each reason.

## Threads

In a text channel the open thread renders inside its starter's row. So a link to a message in
a thread also loads the channel pane around the starter, without the flash. A forum lists its
posts instead of a transcript, so only the thread pane loads a window.

## One load per render

A stream reset keeps the rows inserted earlier in the same render. So the pane reads the URL's
target when it first loads, instead of loading the newest page and then the window. For the
same reason a re-render of a row (`State.rerender_messages/2`, and a broadcast change to a
message) uses `update_only: true`: a row outside the loaded pages stays out, instead of joining
the end of the transcript. `State.rerender_active_thread_panel/1` is the one insert that adds a
row: the open thread's starter, so the thread shows even when its starter is outside the pages.

## Browser side

`MessageListHook` handles `message:focus`:

- With an id, it scrolls the row to the middle of the channel scroll box in the next frame,
  after any scroll that `updated()` queued for the same patch. Then it flashes the row with the
  Web Animations API, which a patch of the row does not cut short. Only the outermost list
  acts, because a thread's list sits inside the channel's.
- With no id, the pane returned to the present: it scrolls to the bottom and follows new
  messages again.
- While the list holds a window it never sticks to the bottom.

## Not built

- A "Copy link" action on a message.
- Opening a thread from the sidebar when its starter is older than the loaded pages still adds
  the starter at the end of the transcript, not in its place.
