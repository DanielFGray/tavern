# Message attachments

A member attaches files to a message from the composer. Images show inline under the text; any
other file shows as a card that downloads it. Code: `Tavern.Chat.Attachments` (context),
`TavernWeb.ServerLive.Attachments` (the composer's upload), `TavernWeb.AttachmentController`
(serving), `TavernWeb.ServerComponents.MessageAttachments` (rendering).

## Rules

- **A message holds text, attachments or both.** The body may be empty only when the message has
  attachments (`Message.changeset/2`). The column is NOT NULL, so such a body is `""`. An edit may
  empty the body of a message with attachments.
- **Attaching needs `attach_files`** in the channel or thread, decided inside the send transaction
  with the send itself (`Visibility` `:attach_files`). `@everyone` holds it by default; the
  Unverified role denies it (docs/design/accounts.md). A refusal is
  `{:error, :attach_files_forbidden}`, so the composer can say attaching, not sending, was refused.
- **Limits:** up to 10 files a message, 10 MB each (`Attachments.max_count/0`, `max_bytes/0`).
  The LiveView upload enforces them in the browser; `Attachments.prepare/2` enforces them again.
- **The type comes from the bytes.** PNG, JPEG, GIF and WebP (`MediaAssets.image_type/1`) are
  images, shown inline. Every other file is stored and served as `application/octet-stream`. The
  client's claimed type and the file extension decide nothing.
- **The file name** is the client's, with any directory part and control characters removed,
  and cut to 200 characters.

## Storage

- Each file is a `media_assets` row of kind `:attachment` and a `message_attachments` row naming it
  and its position. The message insert writes both (`put_assoc`), so the rows exist only with the
  message.
- The bytes go to `Tavern.ObjectStore` under `attachments/<uuid>`, inside the send transaction,
  after every other write. A failed put rolls the message back. Objects put before a failed one
  stay in the bucket with no row naming them, which no route serves.
- Deleting a message deletes its attachment and asset rows in the delete transaction, and the
  objects after the commit, as link embeds do (docs/design/link-embeds.md). Channel and thread
  deletes are soft and keep the rows; `fetch/2` refuses them because the channel is no longer
  visible.

## Serving

- `GET /attachments/:id/:filename`, in the signed-in browser pipeline. It answers only a member
  who may view the message now (`Visibility.visible_message/2`), checked on every request. Any
  other request, including a malformed id, is 404, so a URL tells an outsider nothing. A visitor
  who is not signed in is sent to the login page.
- The public `/uploads` route never serves an attachment, even by its storage key
  (`MediaAssets.fetch_upload/1`). An attachment can sit in a private channel, and `/uploads` checks
  no viewer.
- Headers: `content-disposition: inline` for images and `attachment` for every other file, with
  the file name; `cache-control: private, max-age=31536000, immutable`, because the bytes under one
  id never change but a shared cache must not serve them to someone the app would refuse;
  `x-content-type-options: nosniff`; and `content-security-policy: default-src 'none'; sandbox`.
- A browser keeps a file it already fetched in its private cache after the member loses access to
  the channel.

## The composer

- One LiveView upload, `:attachments`, with `auto_upload`, so a file uploads as soon as it is picked
  and the composer shows its progress. Members add files through the + menu's "Upload attachment"
  (a label for the hidden file input), by dropping them on the composer, or by pasting them
  (`RichComposerHook.attachPastedFiles`). Each control exists only where the member holds
  `attach_files`.
- **Files belong to the composer they were added in.** The view shows one composer, the open
  thread's or else the open channel's. When an event changes which conversation that is, the
  waiting files are dropped (`Attachments.follow_composer/2`, wrapped around every `ServerLive`
  callback), so a file picked in one channel is never sent in another.
- A send reads the waiting files with `{:postpone, _}`, so they stay waiting during the send. Only a
  successful send drops them; a refused send (slowmode, rate limit, permission) keeps both the text
  and the files.
- Enter sends an empty editor when files are waiting, so a message can be files alone.
- A page reload drops waiting files. The composer's text survives it
  (docs/design/new-build-reload.md); the files do not, because the browser's copies are gone.

## Not yet built

- Bots cannot fetch attachment bytes or attach files: `/attachments` takes a browser session, not a
  bot token (docs/design/bot-api.md, "Attachments").
- Forum posts take no attachments, and the forum gallery does not use them.
- No video or audio player: `/attachments` reads the whole object into memory and has no Range
  support.
- Images carry no stored width and height, so the transcript shifts as an image loads, as link
  embed images do.
- No malware scanning, per-member storage quota or content filter.
