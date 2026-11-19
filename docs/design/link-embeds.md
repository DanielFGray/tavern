# Link embeds

Status: built. Task: "Link embeds: page previews and click-to-play YouTube, fetched by the server".

## Rule

A message with links shows one card per link under its body, at most five, in the order the links are written:

- A **link card** shows the page's site name, its title (linked to the page), two lines of description and its image.
- A **video card** is for a YouTube link. It shows the title, the channel name and the stored thumbnail with a play button. A click replaces the thumbnail with the player from `https://www.youtube-nocookie.com/embed/<id>?autoplay=1`. Nothing loads from YouTube before the click.

The server fetches each link once, in the background, after the message write commits, and stores the preview. A viewer's browser never contacts the linked site. The server copies card images into the object store at fetch time, and `/uploads` serves them.

Terms:

- **Embed**: one stored preview, a row of `message_embeds`.
- **Wanted links**: the links in a message body that get an embed (`Tavern.Embeds.Links.embeddable/1`). A link in angle brackets (`<https://...>`) or in a code span or block is not wanted. A deleted message and a message whose embeds were removed want none.
- **Suppression**: removing a message's embeds. It sets `messages.suppress_embeds`, so later edits fetch nothing.

## Data

`message_embeds` holds `message_id`, `position` (the link's index in the wanted links), `url`, `kind` (`link` or `video`), `provider` (`youtube` or none), `title`, `description`, `site_name`, `image_asset_id`, `video_id` and `fetched_at`. `(message_id, url)` is unique. For a video, `description` holds the channel name that oEmbed gives as `author_name`.

An embed image is a `media_assets` row of kind `embed`, stored under `embeds/<uuid>.<ext>` with provider `s3`, like an emoji upload. The embed points at the asset; deleting a message's embeds deletes their asset rows in the same transaction and their objects after the commit.

## Flow

1. `create_message` and `update_message` commit, broadcast, then call `Embeds.schedule/2` with the links that already have an embed. A write with no new wanted link starts no task.
2. The task runs under `Tavern.Embeds.TaskSupervisor` (at most 50 at once; a write over the limit gets no embed). It fetches the new links concurrently (`Tavern.Embeds.Unfurl`), then writes each image to the object store.
3. One transaction stores the result. It decides `:embed_links` for the author's scope (`Visibility.authorize_write`, which takes the author's membership row), locks the message row, recomputes the wanted links from the current body and keeps the previews of wanted links that have no embed yet. The message may have been edited, suppressed or deleted while the fetch ran, so the decision reads the state as of the lock.
4. After the commit, the task deletes the objects it did not store and broadcasts `{:message_updated, message}` on the channel topic. Open `ServerLive` views and the bot event stream take it as any other message update.

A failed fetch, a refused permission and a link with nothing to show store nothing and broadcast nothing.

An edit runs `Embeds.prune/1` inside its own transaction. The prune deletes the embeds of links the edit removed and renumbers the rest to the new link order. The task then fetches only the links the edit added. A deletion and a suppression run the same prune, which wants none.

The store transaction decides `embed_links`, not the message write, because the fetch takes seconds, and a role or overwrite change in that time must apply. Deciding in the store transaction also puts the decision and the write under one lock, as every other write does (see `scoped-reads.md`).

The task acts as the author with `%Scope{user_id: author_id}`, which sees no more than the author does (see "Scope" in `scoped-reads.md`).

The fetch uses no job library. The project has none, and a lost fetch costs only a missing card. A restart drops running fetches; an edit of the message fetches again.

## Who may remove embeds

`Chat.suppress_embeds/2` has the same rule as deleting. The author, or a member with `manage_messages` in the channel may remove the embeds of a message that is not deleted, in a thread that is not closed. The decision is `Visibility`'s `:suppress_embeds` and runs in the write's transaction.

## Fetch safety

All requests go through `Tavern.Embeds.SafeHTTP`, which guards against server-side request forgery (SSRF), a link that points the server at itself or its private network:

- Only http and https, only ports 80 and 443, and no user info in the URL.
- The server resolves the host itself. If any address is loopback, private (RFC 1918), link-local, CGNAT `100.64.0.0/10` (the tailnet), unique-local, multicast, reserved or unspecified, the fetch is refused. An IPv6 address that carries an IPv4 address (mapped, compatible, NAT64, 6to4) is judged by the IPv4 address. Every address must pass, so a DNS answer that mixes public and private addresses is refused.
- The connection goes to the checked address (`Tavern.Embeds.PinnedAdapter`, a Req adapter over one Mint connection), with the host name for TLS verification, SNI and the Host header. A second DNS answer cannot redirect it.
- Redirects are followed by hand, at most three, and each hop is checked again. So is the image URL.
- One five-second budget covers all hops of one fetch. The HTML is read up to 1 MB and parsed truncated. Images are refused over 5 MB and accepted only as PNG, JPEG, GIF or WebP by their magic bytes, whatever the Content-Type says.
- Requests send `User-Agent: TavernBot (+link previews)`, ask for no compression and are not retried.
- Stored text is made valid UTF-8, stripped of control characters, put on one line and capped (title 256, description 350, site name 100 characters).

The adapter is custom because Req's Finch adapter pins an address only through `connect_options: [hostname: ...]`, and it starts one Finch pool per distinct option set. Users choose the hosts, so the pools would grow without bound.

`lazy_html` parses pages. It was already a test dependency, it is a full HTML5 parser (lexbor), and it ships precompiled for linux-gnu on x86_64 and aarch64, which covers the Debian release image. It is now a dependency in every environment. Hostile HTML reaches its native code; the input is capped at 1 MB.

The test environment sets `:resolver` to `Tavern.TestDNS` (a fixed table of `.test` hosts and two YouTube hosts) and `:req_options` to a `Req.Test` stub, which replaces the adapter. `PinnedAdapterTest` drives the adapter itself against a loopback listener under a host name that does not resolve, so a response there proves the pin. No test reaches a real DNS server or the internet.

## YouTube

A link is a video when its host is exactly `youtube.com`, `www.youtube.com` or `m.youtube.com` with `/watch?v=<id>` or `/shorts/<id>`, or `youtu.be/<id>`. The id must match `[A-Za-z0-9_-]{11}`; the server checks it before storing, the template before rendering the player, and the hook before building the iframe URL. The title and channel come from `https://www.youtube.com/oembed`; the thumbnail is `https://i.ytimg.com/vi/<id>/hqdefault.jpg`, stored like any card image. A video oEmbed does not know (private, removed) gets no card.

The player is a colocated hook (`.YouTubePlayer` in `TavernWeb.ServerComponents.Embeds`) on an element with `phx-update="ignore"`, so a re-render of the message does not stop playback. The browser policy allows frames only from this origin and `https://www.youtube-nocookie.com` (`frame-src` in the router's `:browser` pipeline).

## Limits

- A link to an image file, or to any page that is not HTML, gets no card.
- Pages in an encoding other than UTF-8 show replacement characters where bytes are invalid.
- Deleting a channel removes its messages and embeds by cascade, but not the embed image assets or objects.
