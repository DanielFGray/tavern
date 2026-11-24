# Tavern capability inventory (from code)

Taken from the code on 2026-11-24 (branch develop) as the base for `competitive-gaps.md`. The row
ids are shared with the competitor tables there.

Status: `yes` = shipped and reachable from the UI or API; `partial` = some of it is missing (the
note says what); `no` = absent; `planned` = only in tasks or docs. "Schema only" = a table or
column exists with no write path and no UI. Several old open tasks describe features that the code
already has, so every status here comes from the code, not the task store.

Counts (91 rows): yes 20 · partial 22 · no 34 · planned 15.

| id | status | evidence | note |
|---|---|---|---|
| ID1 email/password | yes | lib/tavern/accounts.ex:170, :654; router.ex:71-94; docs/design/accounts.md | Verification and reset need a mail provider. No password change while signed in. |
| ID2 SSO OIDC/OAuth | no | `rg -i 'oauth\|oidc\|openid' lib assets/js`: nothing | |
| ID3 SAML | no | `rg -i saml`: nothing | |
| ID4 LDAP/AD | no | `rg -i 'ldap\|active.?directory'`: nothing | |
| ID5 SCIM | no | `rg -i scim`: nothing | |
| ID6 MFA | no | only `:mfa` log metadata in observability/redaction.ex:61 | |
| ID7 guest accounts | no | `rg -i guest`: nothing | |
| ID8 one account, many servers | planned | memberships unique on user_id (migration 20260402030328:59); README:3 | Proposed task "Federation identity: server name, signing key and user@server addresses at install". |
| ID9 org-owned accounts | partial | moderation.ex:59/83/100/184; accounts.ex:851, :818 | The deployment holds every account. No admin password reset, deactivate without kick, takeover, or admin email edit. |
| ID10 roles/permissions | yes | chat/permission_bits.ex:6-37; roles.ex:148; docs/design/roles.md | 30 allow/deny bits, ranked roles. |
| ID11 channel overrides | yes | chat/channel_overwrites.ex:96 | Per role and per user, on channels and categories. |
| ID12 many workspaces per deployment | no | server_settings singleton (migration 20260403024043:7,14) | One server per deployment, by design. |
| ID13 admin console | yes | settings_components/shell.ex:31-55 | Server settings sit inside user settings. The first owner registers with the setup invite `bin/migrate` prints. |
| ID14 directory/profiles | partial | server_components/shell.ex:184-202; accounts.ex:86 | Avatar, bio, roles, join date. No custom fields, org chart, directory search. |
| MSG1 public channels | yes | chat/channel.ex:15-28; docs/design/channel-management.md | Text, announcement, forum, voice, category. |
| MSG2 private channels | yes | channel_overwrites.ex:96 | By denying view_channel; no "private" toggle. Private threads cannot be created. |
| MSG3 DMs | planned | `rg -i 'direct.?message\|group_dm'`: nothing | Task "Direct messages and group DMs". |
| MSG4 group DMs | planned | as MSG3 | |
| MSG5 threads | yes | threads.ex:304; docs/design/threads.md | |
| MSG6 forums | yes | forums.ex:51; docs/design/forums.md | |
| MSG7 reactions, custom emoji | yes | messages.ex:308; emojis.ex:51 | |
| MSG8 mentions | yes | chat/mentions.ex:166-196 | @here equals @everyone (not "online only"). |
| MSG9 edit/delete | yes | messages.ex:228, :278 | |
| MSG10 pins/bookmarks | planned | `pinned_at` column only (message.ex:19) | Task "Pinned messages, search, and history pagination". |
| MSG11 polls | yes | questions.ex:160; docs/design/questions.md | |
| MSG12 file uploads | planned | message_attachments table only; uploads only for icon, avatar, emoji (settings_live.ex:40-51) | Task "Attachments, uploads, and media previews". |
| MSG13 link previews | yes | chat/embeds.ex:67; docs/design/link-embeds.md | |
| MSG14 markdown/code | yes | chat_hooks.js:8; code_highlight.js:1 | |
| MSG15 full-text search | partial | `Chat.search_messages/3` and the Search drawer (2026-11-24) | Word-prefix search over readable messages. No `from:`/`in:`/`has:`/date filters, and a result opens its conversation, not the message. |
| MSG16 unread tracking | partial | notifications.ex:77, :86, :154 | No "mark unread". |
| MSG17 notification prefs | partial | settings_components/tabs.ex:231-251; chat_hooks.js:634 | Per-channel level and browser alerts. No mute UI, DND, schedules. |
| MSG18 scheduled/reminders | no | `rg -i 'schedul\|remind'`: only account-deletion schedule | |
| MSG19 typing/presence/status | partial | chat/typing.ex:22; ephemeral.ex:43 | No custom status or manual away. |
| MSG20 localisation | no | priv/gettext `en` only; hard-coded English | |
| AV1 voice channels | partial | lib/tavern/voice.ex:41; docs/design/voice.md | 6 per room by default, 25 max, not editable in UI. Mute/disconnect have no UI. |
| AV2 ad hoc calls | no | no DMs; `:call` message kind is enum only | |
| AV3 video/screen share | partial | voice.md | In voice channels only. |
| AV4 large meetings/stage | planned | limit ≤ 25 (channel.ex:213); `:stage` enum only | Task "Stage-channel controls". |
| AV5 recording | no | nothing found | |
| AV6 self-hosted media | no | voice/cloudflare.ex:18, :28 | Needs Cloudflare Realtime SFU and TURN. |
| CL1 web | yes | LiveView; server_live/events/mobile.ex:9 | Responsive; e2e on desktop Chromium and mobile Safari. |
| CL2 desktop app | no | nothing found | |
| CL3 iOS | no | | |
| CL4 Android | no | | |
| CL5 mobile push | planned | "Push alerts" checkbox sends nothing (tabs.ex:168) | No Web Push/APNs/FCM, no relay. Task "Email and push notification strategy". |
| CL6 PWA/offline | no | no manifest, no service worker | |
| CL7 accessibility | partial | ~107 aria/role attributes | No WCAG target or audit. |
| INT1 bot API | yes | router.ex:117-152; api/bot_controller.ex:130; docs/design/bot-api.md | REST plus SSE events. |
| INT2 webhooks | planned | manage_webhooks bit only | Task "Incoming and outgoing webhooks" (draft). |
| INT3 app slash commands | planned | `/` menu is 4 fixed macros (chat.ex:66-73) | |
| INT4 OAuth apps | no | | Bots and tokens are made by hand. |
| INT5 ready integrations | no | | |
| INT6 Slack-compatible API | no | | |
| INT7 interactive messages | partial | question.ex:20 | Bot prompts with option buttons; no forms or modals. |
| CMP1 audit log | yes | chat/audit_log.ex:27, :76 | |
| CMP2 retention | no | `rg -i 'retention\|purge'`: nothing | |
| CMP3 legal hold | no | | |
| CMP4 compliance export | no | | |
| CMP5 data export | no | | Only platform backups. |
| CMP6 GDPR erasure | partial | accounts.ex:851; moderation.ex:100 | Moderator kick-and-delete wipes personal data; messages stay; no self-service; restored backup brings data back. |
| CMP7 DLP/filters | no | | |
| CMP8 E2EE | no | | |
| CMP9 encryption | partial | TLS at proxy; bcrypt; restic-encrypted backups | No at-rest encryption in app. |
| CMP10 certifications | no | | |
| CMP11 residency/air-gap | partial | mail via Cloudflare Email API only (mailer.ex:5-9); voice via Cloudflare | Air-gapped install loses mail and voice. |
| OPS1 install | partial | Dockerfile; cartridge.json | Deployed by the owner's private platform. No compose for the app, no Helm, no generic install guide. |
| OPS2 HA/cluster | partial | application.ex:19-20 (DNSCluster, PG2 PubSub) | Shared state in Valkey/Postgres, but deployed as one node; no cookie/cluster config. |
| OPS3 documented scale | no | k6 scripts up to 500 VUs, no recorded results; scripts cannot log in | |
| OPS4 backup/restore | partial | docs/design/backups.md | Platform nightly dump + restic; drill 2026-11-20. No PITR. |
| OPS5 metrics | partial | observability.ex:32 | OTLP traces/logs; no metrics endpoint. |
| OPS6 upgrades | partial | rel/overlays/bin/migrate; new-build-reload.md | No schema rollback. |
| OPS7 minimum hardware | partial | cartridge.json 0.5 CPU, 512 MB | Production allocation, not a documented minimum. |
| OPS8 licence | no | no LICENSE; federation.md decision 7 | All rights reserved in practice. |
| MOD1 kick/ban/timeout | yes | moderation.ex:59, :83, :184 | |
| MOD2 automod | planned | | Task "Automod rules and banned-word filters". |
| MOD3 slowmode/rate limits | partial | send_limit.ex:16; slowmode.ex:20 | Slowmode has no field in the channel editor. |
| MOD4 reports | planned | message_reports schema only | Task "User reports and moderation queue". |
| MOD5 verification gates | partial | accounts.ex:434 | Email-verified gate, invite-only mode, invite requests. No account-age/phone gate. |
| MOD6 invite links | yes | invites.ex:35; docs/design/invite-requests.md | Max uses, expiry, invite tree. |
| MOD7 onboarding/rules | planned | | Task "Invites and onboarding flow". |
| MOD8 moderation log | yes | moderation.ex:38 | Numbered cases. |
| COM1 discovery | no | one server per deployment | |
| COM2 events | no | manage_events bit only | |
| COM3 announcements/stage | partial | `:announcement` kind | No cross-server following; stage enum only. |
| COM4 rich profiles | partial | accounts.ex:298 | Banner, nickname, pronouns are schema only. |
| COM5 stickers/GIF/soundboard | planned | stickers table only; `/giphy` text macro | |
| MIG1 Slack import | no | | |
| MIG2 Discord import | no | | |
| MIG3 Teams import | no | | |
| MIG4 bridges | no | | federation.md: possible later Matrix/XMPP bridge. |
| MIG5 federation/shared channels | planned | docs/research/federation.md | Proposed Tavern-to-Tavern protocol; no code. |

## Architecture facts

- **Identity.** An account belongs to one deployment (unique membership per user). Joining several
  Tavern servers needs one account on each. The deployment's owners and moderators control every
  account; there is no admin password reset, impersonation or directory sync.
- **Servers per deployment.** Exactly one (`server_settings` singleton).
- **Clustering.** DNSCluster and the PG2 PubSub adapter exist; Postgres and Valkey hold shared
  state. The deploy declares one service with no cluster query or cookie, so it runs as one node.
  With Valkey down, rate limits fall back to node-local counts.
- **Voice/video.** Browser WebRTC to Cloudflare Realtime SFU; Tavern relays SDP and mints TURN
  credentials. No self-hosted media path. Rooms: 6 default, 25 max.
- **Mobile.** No native app, PWA manifest or service worker. Notifications only through the
  browser Notification API while a tab is open.
- **Licence.** No LICENSE file; all rights reserved in practice.
- **Other dependencies.** Mail only through Cloudflare Email API (no SMTP). Uploads to any S3
  store. Deploy depends on the owner's private platform (cartridge, Nomad, Podman).
