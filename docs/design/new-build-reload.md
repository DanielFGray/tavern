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
from one while its socket reaches the other, which reports a change again. The client records the
bundle it reloaded for in `sessionStorage` and reloads at most once a minute for the same bundle.
When storage is unavailable it does not reload, since the guard cannot hold.

A voice call belongs to the LiveView process that joined it (`voice.md`), and a deploy stops that
process, so the reload ends no call that the deploy had not ended already. Nothing rejoins on load;
the person joins again by hand.

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
