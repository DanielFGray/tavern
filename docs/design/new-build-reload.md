# Reloading open tabs after a deploy

A deploy restarts the server, and every open tab reconnects its LiveView socket to the new one. The
socket brings fresh HTML, but the tab keeps running the `app.js` and `app.css` it loaded first. Old
hooks then drive new markup until the person reloads.

## Detecting an earlier build

The root layout marks both bundles with `phx-track-static`. On every join the client sends their
URLs, and `static_changed?/1` compares them with the digest manifest that `mix assets.deploy` wrote
into the release. Bundle URLs carry a content hash and pages are served `max-age=0`, so a plain
reload always fetches the new build; nothing needs a hard refresh.

`TavernWeb.ReloadOnNewBuild` runs first in each `live_session`. When the bundles differ it pushes
`static_changed`, and `assets/js/app.js` reloads the page. `static_changed?/1` works only in a
routed LiveView, and only routed LiveViews run session hooks, so the router is where it goes.

During a deploy the old and new servers can both answer for a moment. A reloaded page can then come
from either while its socket reaches the other, which reports a change again whichever build the
page holds, so the bundle URL cannot tell a loop from progress. The client limits by time instead:
it records each reload in `sessionStorage`, reloads at most once a minute, and a change reported
sooner reloads when that minute ends. When storage is unavailable it does not reload, since the
limit cannot hold.

The reload ends a voice call, and nothing rejoins on load; the person joins again by hand. It also
drops text typed in forms other than the composer, such as settings, and files waiting in the
composer (docs/design/attachments.md).

## Keeping drafts

A reload must not lose unsent text, so the composer keeps each draft in `localStorage`
(`assets/js/composer_drafts.js`). The key is the user and the conversation (`Composer.draft_key/2`),
so a channel or a thread each holds its own draft and accounts that share a browser do not see each
other's.

- Every edit saves the draft; an empty editor removes it.
- A channel or thread switch keeps the composer mounted and changes only its `data-draft-key`, so
  the hook's `updated/0` shows the draft of the conversation now open.
- `composer:clear`, pushed when a send succeeds, names the sent conversation's key. The hook removes
  that draft even when the reader has since moved on, and empties the editor only when it shows that
  conversation.
- The draft holds Tiptap document JSON, so mentions and custom emoji come back as nodes. A newer
  build reads what an older one wrote; a document the current schema rejects is removed and the
  editor starts empty.
