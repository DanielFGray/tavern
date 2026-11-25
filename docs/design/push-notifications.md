# Alerts and Web Push

Status: built. Push services have accepted the request format (see "Proof so far"), but no push
has yet reached a real device.

A member gets an alert for a message that the alert rule selects. The alert reaches them in two
ways: a desktop alert from an open Tavern tab, and a Web Push notification to each device they
turned push on for. Web Push reaches a phone or a closed browser, so Tavern needs no native app
and no vendor relay. The owner chose this route on 2026-11-24
(`docs/research/competitive-gaps.md`, "Where the two segments conflict", item 4).

Terms:

- **Web Push**: the browser standard for a server to wake a page's service worker with a message
  (RFC 8030). The browser vendor runs the push service (Google FCM, Mozilla autopush, Apple
  APNs). Tavern posts to the URL the browser gives it.
- **Subscription**: one device's push address: the push service URL (the endpoint) and two keys
  the device made (`p256dh`, `auth`).
- **VAPID**: the server's own key pair (RFC 8292). The push service only takes a message signed
  with the key the subscription was made with.
- **Service worker**: `priv/static/sw.js`, the script the browser runs when a push arrives.

## The alert rule

`Tavern.Chat.Alerts.alert?/1` decides one member and one message. Desktop alerts and push use
this one rule. Only the delivery differs.

1. The author's own message never alerts.
2. The member must be able to view the conversation now (`Visibility.can?/3`, `:view_channel`).
3. The level is the member's level for the conversation: its own override, then for a thread its
   parent's. A `:default` level takes the global settings: `:all_messages` when "Notify on all
   messages" is on, `:mentions` when "Notify on mentions" is on, otherwise `:nothing`.
4. In a thread the member does not follow, only a direct mention alerts, and not at `:nothing`.
   A followed thread and a channel alert by the level:
   - `:all_messages`: every message.
   - `:mentions`: a mention that counts.
   - `:nothing`: none.
5. A mention that counts:
   - a direct mention of the member;
   - a mention of one of the member's roles, unless "Suppress role mentions" is on;
   - an @everyone mention (the default role), unless "Suppress @everyone" is on.

Before this rule, the per-channel "All messages" level and the two suppress switches changed
nothing. Rule 3 also changes one case: a member who turned "Notify on mentions" off but set a
channel to "All messages" now gets that channel's alerts, because a choice for one channel is
more specific than the global one.

## Delivery

`Tavern.Chat.Alerts.publish/1` runs in the writer's process after the message's transaction
commits. It builds one notification per recipient, `%{title, body, tag, path}`, and both
deliveries show it as it is: the title (`Ada mentioned you in #general`, or `Ada in #general`
for an `:all_messages` level), at most 140 characters of the message, the tag, and the path that
opens the message in place (docs/design/message-links.md).

- **Desktop alert.** "Desktop alerts" must be on. Each open tab gets the notification on its
  member's PubSub topic (`Topics.subscribe_user/1`), and shows it only while the tab is hidden
  and not for the conversation it shows. A click opens the message in place.
- **Push.** The member must have at least one subscription. "Push alerts" is not a stored
  setting: a device is on while it holds a subscription, and turning push off on a device
  deletes that device's subscription. So each device decides for itself, and a server-wide
  switch would only repeat what the subscriptions say.
- **Duplicates.** Both kinds of alert carry the tag `mention-<message id>`. A browser shows one
  notification per tag, so a desktop browser with a tab open and a push subscription shows one
  alert, not two.
- **An active member still gets push.** Tavern has no signal that a member is reading right now:
  presence updates only when a page authenticates. A push that the service worker hides would
  break the browsers' rule that every push shows a notification. Safari revokes a subscription
  that breaks it ("Violations of the userVisibleOnly promise will result in a push subscription
  being revoked", https://webkit.org/blog/12945/meet-web-push/). So a member with a desktop tab
  open and a phone gets the alert on both.

## Deciding and sending

1. One query finds the candidates: active members with a delivery (desktop alerts on, or a push
   subscription) who could match rule 4 or 5 — mentioned directly, holding a mentioned role, any
   member for an @everyone mention, or holding an `:all_messages` level on the conversation or
   as a global setting. A message with no mention reaches only the `:all_messages` members, so a
   plain message costs one query.
2. Each candidate goes through `alert?/1`, then `Visibility.can?/3` with their own scope.
3. Recipients with a subscription go to `Tavern.WebPush.deliver/1`, which starts one task under
   `Tavern.WebPush.TaskSupervisor` (at most 50 at once; past that the pushes are dropped and
   logged), so the writer never waits on a push service.
4. The task POSTs once to each of their subscriptions, at most 16 at once. The body is
   encrypted to the device (RFC 8291, `aes128gcm`, `Tavern.WebPush.Encryption`), so the push
   service cannot read the message text. Headers: `TTL` 24 hours, `Urgency: high`.
5. A `404` or `410` answer means the subscription is gone: Tavern deletes it. Other failures are
   logged by host only (an endpoint URL is a secret address) and dropped. A push is not retried.

The endpoint is a URL the member's browser chose, so the POST goes through
`Tavern.Embeds.SafeHTTP.post/3`, with the same checks as a link preview: http or https on the
usual ports, every resolved address public, the connection pinned to the checked address, and no
redirect. An endpoint must also be https to be stored. Any push service works, including a
self-hosted UnifiedPush server on a public address.

## Subscriptions

`Tavern.Chat.PushSubscriptions` stores one row per device in `push_subscriptions`: the endpoint
(unique), the two device keys as raw bytes, and the browser session (`user_sessions` row) that
sent it. A member keeps at most ten; a new one past that drops the one least recently renewed.

A push goes only to a subscription whose session is live (`PushSubscriptions.live/0`: not
revoked, not expired). So signing out, a revoked session, a password reset and an expired
session all stop push on that browser, and its notifications stop showing the member's messages
to whoever uses it next. A deleted session deletes the row (foreign key), which also covers
account deletion. The chat page and the Settings card both send the browser's subscription
again when they load, so signing in again on that browser turns push back on, and an endpoint
that a browser keeps after a sign-in as someone else moves to the member signed in now.

## Keys

Tavern makes its VAPID key pair on first use and stores it in the `push_keys` table (one row),
with the server URL it was made for (`TavernWeb.Endpoint.url/0`). A self-hosted server therefore
needs no push setting. The key lives with the subscriptions it signs for, so a database leak
gives no more than the subscriptions alone would. A new key pair voids every subscription;
nothing rotates it.

A server whose URL differs from the stored one sends no push and its Settings card says push is
off. A copy of the database (a staging server, a restore drill) therefore cannot wake real
members' phones. To move a server to a new URL, delete the `push_keys` row; members then turn
push on again on each device.

The VAPID `sub` claim is the server's own URL (`TavernWeb.Endpoint.url/0`), not a mail address.
Apple, Google and Mozilla see it with every push. Apple refuses a token whose `sub` is not a
real public URL: `http://localhost:4000` and `https://tavern.example` got `403 BadJwtToken`,
while `https://example.com` passed the token check. An iPhone needs the server on public https
in any case (a service worker needs a secure origin), so this adds no setting.

The Settings card compares the key a browser's subscription was made with to the server's
current key. When they differ (the `push_keys` row was deleted), it unsubscribes the browser and
offers to turn push on again.

## The browser side

- `GET /manifest.webmanifest` (`TavernWeb.ManifestController`, named after the server) and the
  icons in `priv/static/images/app-icon-*` make Tavern installable. The PNGs are rendered from
  `app-icon.svg` with `rsvg-convert -w <size> -h <size>`. iOS and iPadOS 16.4 and later
  give push only to a web app added to the Home Screen
  (https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/).
- `priv/static/sw.js` handles `push` (show the notification) and `notificationclick` (focus a
  Tavern tab and open the path, or open a new window). It has no `fetch` handler and caches
  nothing, so it cannot serve a stale bundle after a deploy (`docs/design/new-build-reload.md`).
- The Push alerts card in Settings (hook `.PushAlerts`) asks for permission and subscribes in the
  click handler, because Safari and Chrome allow the request only from a user gesture. It
  registers the service worker only then, so a member who never turns push on runs none. Where
  the browser has no Push API, the card says so; on an iPhone or iPad it says to add Tavern to
  the Home Screen first. "Turn off" deletes the row and unsubscribes the browser.

## Proof so far

On 2026-11-25, a probe posted an encrypted payload with a VAPID header through
`SafeHTTP.post/3` (the production adapter, not a test stub) to made-up subscriptions:

- Mozilla (`updates.push.services.mozilla.com`): `404`, an unknown subscription.
- Google (`fcm.googleapis.com`): `410`, an unknown subscription.
- Apple (`web.push.apple.com`): `400 BadWebPushToken` (an unknown device token) once the
  `sub` was a public URL, so Apple accepted the VAPID signature.

The sender deletes a subscription on `404` and `410`. Encryption matches RFC 8291's worked
example byte for byte. Headless Chromium in the e2e suite refuses notification permission, so
no automated test turns push on in a browser.

## Not done

- "Email alerts" is a stored setting with no sender, so Settings no longer shows it.
- A subscription the browser replaces (`pushsubscriptionchange`) is not sent to the server. The
  old one answers `410` and is deleted; the member turns push on again.
- Not yet proven on a real iPhone or Android phone with the app closed.
