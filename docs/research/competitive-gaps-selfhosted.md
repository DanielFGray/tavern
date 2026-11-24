# Self-hosted competitors: capabilities and paid gating

Accessed: 2026-11-24. Sources are vendor docs, vendor pricing pages, and the vendors' GitHub repositories only. "unverified" means no primary source stated the fact.

Method: four readers each covered one product from vendor docs, pricing pages and source code. I re-checked the push, user-cap and Entry-limit quotes with curl against the live pages and code on the access date. Where two vendor sources disagree, the row says "CONFLICT" and the conflict list under that product gives both sides. Code beats marketing pages when they disagree about a gate, because code is what runs.

## Summary

### What all four hold back for payment

Mattermost, Rocket.Chat and Element gate HA, compliance tooling and directory sync behind payment. All four sell support. Zulip self-hosted gates no feature; it sells only push above 10 users, plus support. The table shows each product's gate.

| Capability | Mattermost | Zulip (self-hosted) | Rocket.Chat | Element (ESS) |
|---|---|---|---|---|
| HA / clustering / horizontal scale | Enterprise+ (code flag `cluster`) | free; Zulip supports it at Enterprise | Commercial+ (code module `scalability` stops a second node) | ESS Pro (Synapse Pro); OSS workers have no HA story |
| Compliance: audit log, legal hold, compliance export | Enterprise+ | free; Cloud Plus for audit log | Commercial+ | ESS Pro (AuditBot) |
| Retention policies | Enterprise+ | free; Cloud Standard+ | free | in OSS Synapse; pricing page says Pro (CONFLICT) |
| Directory sync (LDAP/AD group sync, SCIM) | Entry/Enterprise+; no SCIM | free; Cloud Plus | Starter+; no SCIM found | ESS Pro "Advanced IAM" |
| SSO (SAML/OIDC) | Professional+ and Entry; removed from Team Edition | free; Cloud Plus | Starter+; removed from Community in 9.0.0 | OIDC free; LDAP auth paid |
| Content-hidden (ID-only) push | Entry/Enterprise+ (not Professional) | free (E2EE push since 12.0) | premium (code module `push-privacy`) | free (stock apps send event IDs only) |
| Vendor support SLA, LTS, certified builds (FIPS, STIG) | paid tiers | Business/Enterprise sell support for features already present | Commercial/Government/Defense | ESS Pro |
| Air-gapped install | Enterprise Advanced (CONFLICT) | free | Starter/paid; Community goes read-only after 10 days offline | Sovereign plan only |

Zulip is the exception. Its self-hosted server has every feature under Apache-2.0. Its paid self-hosted plans sell push notifications for more than 10 users and support. Zulip Cloud does gate features (SAML, OIDC, SCIM and audit log need Cloud Plus).

The free tiers carry hard caps that users notice:
- Mattermost Team Edition: 200 users soft, 250 hard, in code (`server/channels/app/limits.go`). Mattermost Entry: "10,000 Channel messages history across all channels", in force now.
- Rocket.Chat Starter: "Up to 50 users". Community: "Up to 100 concurrent users" and 10,000 push notifications a month.
- ESS Community: "up to 100 users", "non-commercial community use cases" (ess-helm README).
- Zulip self-hosted Free: push for up to 10 users.

### Mobile push from a self-hosted server

All four use the same mechanism. Apple and Google accept a push only from a holder of the secret that is compiled into the app. So the stock store apps can receive push only through the vendor's relay. To avoid the relay, you build and ship your own app with your own APNs/FCM keys and run the vendor's open-source proxy.

| | Mattermost | Zulip | Rocket.Chat | Element |
|---|---|---|---|---|
| Vendor relay | HPNS (`*.push.mattermost.com`); TPNS (`push-test.mattermost.com`) | Mobile Push Notification Service (`push.zulipchat.com`) | Push Gateway (`gateway.rocket.chat`), needs Cloud registration | Element's Sygnal at `https://matrix.org/_matrix/push/v1/notify` |
| Free? | HPNS: no, Professional/Enterprise only, enforced in code. TPNS: free, "non-commercial", no production SLA | Free up to 10 users; Community plan (non-profit, education, OSS) unlimited; else Basic $3.50/user/month | Community: 10,000 pushes/month, then stops; Starter and paid: unlimited | unverified (no stated price or limit) |
| Content seen by relay | full text unless ID-only push (Entry/Enterprise+, not Professional) | E2EE payload since Server 12.0 (April 2026) | full text unless "Hide message content" (premium only) | event ID only in Element X (`EVENT_ID_ONLY`) |
| Avoid the relay | yes: own app build + `mattermost-push-proxy` (Apache-2.0), no licence check on own proxy | yes: own app build with own APNs/FCM keys (settings comment in `zproject/default_settings.py`); bouncer code is open source | yes: white-label app + own APNs/FCM keys; pricing page calls this "Custom mobile push gateway", not in Community (code has no gate; unverified in practice) | yes: own app build + own Sygnal (AGPL-3.0); Element sells "Custom mobile push gateway" in Sovereign plan only |
| Android without FCM | not researched | not researched | not researched | yes: UnifiedPush in all Element X flavors; F-Droid build |

### Other decision-relevant facts

- Importers: Mattermost, Zulip and Rocket.Chat import Slack exports. Element has no importer, only third-party bridge backfill (mautrix-slack). Nobody imports Discord. Only Zulip imports Teams (beta, no DMs or private channels). Slack's own plan limit applies to all: only Business+ and Enterprise Grid exports contain private channels and DMs.
- Documented scale: Mattermost publishes reference architectures to 200,000 concurrent users (Enterprise Advanced). Rocket.Chat's top tier is "Above 5,000" concurrent users with no ceiling. Zulip documents sharding for "several thousand daily active users". Element claims a "500K+ largest commercial deployment" and Bundeswehr "more than 100,000 active users".
- Licences: Mattermost source is AGPL-3.0, its binaries are MIT, and its `server/enterprise` directory is source-available. Zulip is Apache-2.0. Rocket.Chat is MIT except `ee/` directories under an Enterprise licence. Synapse, Element clients and ESS Community are AGPL-3.0 with a commercial licence option.
- E2EE: Rocket.Chat and Element have message E2EE. Mattermost has none documented. Zulip has push-payload E2EE only; message E2EE is its third most-reacted open issue.

## 1. Mattermost

Abbreviations in this section: D/ = https://docs.mattermost.com/ ; PLANS = https://docs.mattermost.com/product-overview/plans ; PRICE = https://mattermost.com/pricing/ ; GH/ = https://github.com/mattermost/ . Tiers: TE = Team Edition (free, MIT binary, no licence key), EN = Entry (Enterprise binary with no subscription, free with limits), P = Professional, E = Enterprise, EA = Enterprise Advanced. Docs badges never name Team Edition, so TE is "unverified" where a badge is the only source.

### Licence and tiers

- LICENSE.txt (https://github.com/mattermost/mattermost/blob/master/LICENSE.txt): compiled builds are "produced by Mattermost, Inc. under an MIT LICENSE". Source is "Under the Free Software Foundation's GNU AGPL v3.0 ... or ... a commercial license". `server/templates/`, `server/i18n/`, `server/public/` and `webapp/` are Apache-2.0. CONFLICT: https://docs.mattermost.com/product-overview/faq-license says "AGPLv2".
- `server/enterprise/LICENSE` is the "Mattermost Source Available License". Production use needs a "valid Mattermost Enterprise E20 subscription". Some enterprise code is closed (private repo `mattermost/enterprise`).
- Live tier names: Professional, Enterprise, Enterprise Advanced, plus the free Team Edition and Entry. "Free" is no longer a tier name. Enterprise Advanced is new relative to the brief.
- Team Edition: "intended for small teams, hobbyists, or personal use under 250 activated users where single sign-on (SSO) is not required" (https://docs.mattermost.com/product-overview/editions-and-offerings). "SSO is being removed from the Team Edition". Code caps unlicensed servers: `maxUsersLimit = 200`, `maxUsersHardLimit = 250`.
- Entry: "Entry has all features of Enterprise Advanced with the following server-wide limitations and omissions": "10,000 Channel messages history across all channels" (in force now), "1000 Board cards*", "5 Active Playbook runs / month*", "250 Agent queries/ month*", "40-minute Calls*", "10,000 push notifications / month*", "No Compliance features", "No High Availability", "Community support only". "* Limits will take effect in a future release." Entry is "best suited for teams less than 50 users" (guidance, not enforced).
- Professional (PRICE): "SSO (SAML, OIDC, OAuth) with MFA and AD/LDAP sync"; "Channel controls: read-only, restricted, locked"; "Self-hosted group audio calls and screen sharing"; "Guest accounts, custom user groups, and 20 languages"; "DevSecOps integrations: Jira, GitHub, and GitLab"; bring-your-own LLM; next-business-day support; "Up to 250 users".
- Enterprise adds: "Playbooks with automated triggers"; AI agents with search and summaries; "Calls with live transcription and agent summaries"; "Federated channels with Teams and Matrix interop"; "Granular RBAC and AD/LDAP group, team, and channel sync"; "Data retention, legal hold, compliance export"; "FIPS 140-3 validated and STIG-hardened images"; "HA cluster to 50,000 users with Enterprise Search"; 24x7 support.
- Enterprise Advanced adds: attribute-based access control (ABAC); classification banners; "Burn-on-read and cross-classification spillage"; "Air-gapped deployment with offline and DDIL ops"; Intune MAM; "Mission partners: translation and anonymous URLs"; 200,000 concurrent users; add-ons Cross Guard CDS and BYOK encryption.
- Licence feature flags in code (`server/public/model/license.go`, `Features` struct): users, ldap, ldap_groups, mfa, google_oauth, office365_oauth, openid, compliance, cluster, metrics, mhpns, saml, elastic_search, announcement, theme_management, email_notification_contents, data_retention, message_export, custom_permissions_schemes, custom_terms_of_service, guest_accounts, guest_accounts_permissions, id_loaded, lock_teammate_name_display, enterprise_plugins, advanced_logging, cloud, shared_channels, remote_cluster_service, outgoing_oauth_connections, auto_translation, entities, future_features. Tier constants: `ProfessionalTier=10`, `EnterpriseTier=20`, `EntryTier=30`, `EnterpriseAdvancedTier=30`. Entry's omissions come from per-licence Features and Limits (`PostHistory`, `BoardCards`, `PlaybookRuns`, `CallDurationSeconds`, `AgentsPrompts`, `PushNotifications`).

### Mobile push

- Mechanism: "Your Mattermost server sends push notifications to a hosted push proxy server, which relays them via mobile push notification services provided by Apple and Google." Apple and Google "only allow push notifications sent from a service using a key or signature corresponding to a secret compiled into the mobile app itself." (https://docs.mattermost.com/deployment-guide/mobile/mobile-faq)
- HPNS is paid: "Mattermost Enterprise, Professional, and Cloud customers can use Mattermost's Hosted Push Notification Service (HPNS)." (https://docs.mattermost.com/administration-guide/configure/environment-configuration-settings). Code (`server/channels/app/notification.go`): `if model.IsMHPNSEndpoint(pushServer) && !a.Srv().License().HasMHPNS()` logs "Push notifications are disabled - license missing". Whether an Entry licence sets `mhpns`: unverified.
- TPNS: "Non-commercial self-hosted customers can use Mattermost's free, basic Test Push Notifications Service (TPNS)." It "isn't recommended for use in production environments, and doesn't offer production-level update service level agreements (SLAs)." TPNS encryption: unverified. CONFLICT: the docs give port 80 for TPNS; code default is `https://push-test.mattermost.com`.
- ID-only push: "Available on Entry, Enterprise, and Enterprise Advanced plans (not available on Professional)"; "at no time, is the message text visible to Apple or Google". Licence flag `id_loaded`.
- Avoiding the relay: "Customers building their own custom mobile apps must host their own push proxy service" (https://docs.mattermost.com/deployment-guide/mobile/host-your-own-push-proxy-service). "The HPNS only works with pre-built apps." The licence check applies only to Mattermost-hosted endpoints. Proxy: https://github.com/mattermost/mattermost-push-proxy (Apache-2.0, needs an APNs .p8 key and FCM service-account file). App build guide: https://developers.mattermost.com/contribute/more-info/mobile/build-your-own/ ; mobile app is Apache-2.0.

### Importers

- Slack (https://docs.mattermost.com/administration-guide/onboard/migrate-from-slack, tool https://github.com/mattermost/mmetl): public and private channels yes; 1:1 DMs yes; group DMs "Up to 8 members become Mattermost Group Messages; larger groups become private channels"; "Message history and thread replies come with you"; "Files attached to messages come with you"; reactions; users (name, email, title); deactivated users; bots. Not imported: custom emoji, user groups, profile pictures, custom profile fields, canvases, Slack Connect, integrations. Private channels and DMs need Slack Business+ or Enterprise Grid export.
- Rocket.Chat: https://docs.mattermost.com/administration-guide/onboard/migrate-from-rocketchat (mongodump, "validated against Rocket.Chat v8.5").
- Others: https://docs.mattermost.com/administration-guide/onboard/migrating-to-mattermost (Jabber via third-party ETL; Flowdock, Campfire, Chatwork, Hall via Slack format); generic JSONL bulk import at https://docs.mattermost.com/administration-guide/onboard/bulk-loading-data.
- Discord, Teams, HipChat: no importer. mmetl lists only Slack, Slack Enterprise Grid and RocketChat.

### Clustering, HA and scale

- HA: "Available on Enterprise and Enterprise Advanced plans" (https://docs.mattermost.com/deployment-guide/server/high-availability-cluster-based-deployment). "redundant Mattermost application servers, redundant database servers, and redundant load balancers"; shared file storage; gossip on port 8074; read and search replicas; rolling upgrades with "one minor version difference"; Redis for "installations with more than 100,000 users".
- Scale (https://docs.mattermost.com/deployment-guide/scale/scaling-for-enterprise): "user counts refer to the number of concurrent users". Reference tiers are 200, 2k, 15k, 30k, 50k, 80k, 90k, 100k and 200k. The 200k tier is EA only: 14 app nodes (c7i.4xlarge), 1 writer and 6 reader databases, 4 Elasticsearch nodes, 4 proxies, Redis (https://docs.mattermost.com/deployment-guide/scale/scale-to-200000-users). Load-test tool: https://github.com/mattermost/mattermost-load-test-ng.

### Capability table

| id | offered | edition | source URL | note |
|---|---|---|---|---|
| ID1 | yes | free (TE+) | https://docs.mattermost.com/product-overview/plans | Email verification, password rules, lockout |
| ID2 | yes | EN, P, E, EA (not TE) | https://docs.mattermost.com/administration-guide/onboard/sso-openidconnect | OIDC, Google, Entra ID, GitLab; attribute sync E/EA |
| ID3 | yes | EN, P, E, EA (not TE) | https://docs.mattermost.com/administration-guide/onboard/sso-saml | Okta, ADFS, Keycloak guides |
| ID4 | yes | login EN/P/E/EA; group sync EN/E/EA | https://docs.mattermost.com/administration-guide/onboard/ad-ldap | CONFLICT: sync badge excludes P; PLANS includes P |
| ID5 | no | none | https://github.com/mattermost/mattermost/blob/master/docs/main/administration-guide/onboard/sso-saml-faq.mdx | "Currently, we do not support SCIM" |
| ID6 | partial | EN/P/E/EA; TE unverified | https://docs.mattermost.com/administration-guide/onboard/multi-factor-authentication | TOTP only; enforcement paid; WebAuthn/passkeys not found |
| ID7 | yes | EN, P, E, EA (not TE) | https://docs.mattermost.com/administration-guide/onboard/guest-accounts | Guest magic links EN/E/EA |
| ID8 | partial | free (Entry); TE unverified | https://docs.mattermost.com/end-user-guide/preferences/connect-multiple-workspaces | Clients connect to many servers; shared identity unverified |
| ID9 | yes | free (Entry); TE unverified | https://docs.mattermost.com/administration-guide/manage/mmctl-command-line-tool | Deactivate, delete, reset; takeover unverified |
| ID10 | yes | EN/P/E/EA; delegated admin E/EA | https://docs.mattermost.com/administration-guide/onboard/advanced-permissions | Code flag `custom_permissions_schemes` |
| ID11 | yes | private channels free; moderation any licence | https://docs.mattermost.com/administration-guide/onboard/advanced-permissions | Per-channel moderation overrides |
| ID12 | yes | free (Entry); TE unverified | https://docs.mattermost.com/administration-guide/manage/product-limits | Up to 10,000 teams per deployment |
| ID13 | yes | free | https://docs.mattermost.com/administration-guide/configure/environment-configuration-settings | System Console, config.json, env vars |
| ID14 | partial | profiles free; custom attributes EN/E/EA | https://docs.mattermost.com/end-user-guide/preferences/manage-your-profile | Org chart unverified |
| MSG1 | yes | free | https://docs.mattermost.com/product-overview/plans | Core messaging |
| MSG2 | yes | free | https://docs.mattermost.com/product-overview/plans | |
| MSG3 | yes | free | https://docs.mattermost.com/product-overview/plans | |
| MSG4 | yes | free | https://docs.mattermost.com/administration-guide/manage/product-limits | Up to 8 participants |
| MSG5 | yes | free | https://docs.mattermost.com/product-overview/plans | Threads and thread inbox |
| MSG6 | unverified | | | No forum post type found |
| MSG7 | yes | free | https://docs.mattermost.com/product-overview/plans | 50 reactions per post; 6,000 custom emoji |
| MSG8 | yes | @channel/@here free; @group P+ | https://docs.mattermost.com/end-user-guide/collaborate/mention-people | CONFLICT: badge says E/EA; code gates at P |
| MSG9 | yes | free | https://docs.mattermost.com/end-user-guide/collaborate/send-messages | Admins can restrict; version restore paid |
| MSG10 | yes | free (TE unverified) | https://docs.mattermost.com/end-user-guide/collaborate/save-pin-messages | Saved, pinned, 50 channel bookmarks |
| MSG11 | partial | community plugin | https://docs.mattermost.com/administration-guide/upgrade/admin-onboarding-tasks | Docs point to Matterpoll plugin; no native polls |
| MSG12 | yes | free | https://docs.mattermost.com/product-overview/plans | 10 files per post; 100 MB default |
| MSG13 | yes | free | https://docs.mattermost.com/product-overview/plans | Link and media previews; image proxy |
| MSG14 | yes | free | https://docs.mattermost.com/product-overview/plans | Markdown, code, tables |
| MSG15 | yes | core free; Enterprise Search E/EA | https://docs.mattermost.com/end-user-guide/collaborate/search-for-messages | from:, in:, date; core search fits about 2-3M posts |
| MSG16 | yes | free (TE unverified) | https://docs.mattermost.com/end-user-guide/collaborate/mark-messages-unread | |
| MSG17 | partial | free (Entry); TE unverified | https://docs.mattermost.com/end-user-guide/preferences/manage-your-channel-specific-notifications | Mute, per-channel, DND; DND schedules unverified |
| MSG18 | yes | free (TE unverified) | https://docs.mattermost.com/end-user-guide/collaborate/schedule-messages | Reminders: https://docs.mattermost.com/end-user-guide/collaborate/message-reminders |
| MSG19 | yes | free (TE unverified) | https://docs.mattermost.com/end-user-guide/preferences/set-your-status-availability | Typing, presence, custom status |
| MSG20 | partial | UI languages free; auto-translate EA | https://docs.mattermost.com/end-user-guide/collaborate/autotranslate-messages | Auto-translate is beta |
| AV1 | partial | see AV2 | https://docs.mattermost.com/end-user-guide/collaborate/make-calls | Calls start per channel; no always-on rooms |
| AV2 | yes | 1:1 free; group P/E/EA | https://docs.mattermost.com/deployment-guide/calls/calls-deployment-guide | CONFLICT: Entry group calls (PLANS yes; Calls guide 1:1, 40 min) |
| AV3 | partial | as AV2 | https://github.com/mattermost/mattermost-plugin-calls/blob/master/plugin.json | Screen share yes; camera video experimental, DMs only |
| AV4 | partial | scalable calls E/EA | https://docs.mattermost.com/administration-guide/configure/plugins-configuration-settings | Recommended max 50 per call; rtcd above that |
| AV5 | yes | E, EA | https://docs.mattermost.com/end-user-guide/collaborate/make-calls | Recording, live captions, transcription |
| AV6 | yes | free | https://docs.mattermost.com/deployment-guide/calls/calls-deployment-guide | Built-in SFU or rtcd; no third-party media path |
| CL1 | yes | free | https://docs.mattermost.com/end-user-guide/access/client-availability | |
| CL2 | yes | free | https://docs.mattermost.com/deployment-guide/desktop/desktop-app-deployment | Windows, macOS, Linux; Apache-2.0 |
| CL3 | yes | free | https://docs.mattermost.com/end-user-guide/access/install-ios-app | Apache-2.0 app |
| CL4 | yes | free | https://docs.mattermost.com/end-user-guide/access/install-android-app | |
| CL5 | yes | HPNS P/E/EA; TPNS non-commercial; own proxy free | https://docs.mattermost.com/administration-guide/configure/environment-configuration-settings | See Mobile push above |
| CL6 | partial | free | https://docs.mattermost.com/deployment-guide/software-hardware-requirements | PWA install documented; offline mode unverified |
| CL7 | partial | free | https://docs.mattermost.com/product-overview/accessibility-compliance-policy | "committed to following ... WCAG 2.1 Level AA"; VPAT on request |
| INT1 | yes | free | https://docs.mattermost.com/integrations-guide/restful-api | Bot accounts and REST API |
| INT2 | yes | free | https://docs.mattermost.com/integrations-guide/incoming-webhooks | Outgoing: https://docs.mattermost.com/integrations-guide/outgoing-webhooks |
| INT3 | yes | free | https://docs.mattermost.com/integrations-guide/slash-commands | "slash command format is Slack compatible" |
| INT4 | yes | free | https://docs.mattermost.com/administration-guide/configure/manage-plugins | Plugin Marketplace; OAuth 2.0 apps |
| INT5 | yes | free | https://docs.mattermost.com/integrations-guide/popular-integrations | GitHub, GitLab, Jira, MS Calendar, Zoom |
| INT6 | partial | free | https://docs.mattermost.com/integrations-guide/incoming-webhooks | Slack webhook and slash formats; no Slack API |
| INT7 | yes | free | https://docs.mattermost.com/integrations-guide/outgoing-webhooks | Buttons, menus, interactive dialogs |
| CMP1 | yes | E, EA | https://docs.mattermost.com/administration-guide/manage/logging | CONFLICT: audit schema page also lists EN |
| CMP2 | yes | E, EA (not EN) | https://docs.mattermost.com/administration-guide/comply/data-retention-policy | Code flag `data_retention` |
| CMP3 | yes | E, EA | https://docs.mattermost.com/administration-guide/comply/legal-hold | |
| CMP4 | yes | E, EA | https://docs.mattermost.com/administration-guide/configure/compliance-configuration-settings | CSV, Actiance XML, Global Relay EML |
| CMP5 | partial | bulk export EN/P/E/EA; channel export E/EA | https://docs.mattermost.com/administration-guide/manage/bulk-export-tool | Per-user self-export unverified |
| CMP6 | yes | free | https://docs.mattermost.com/product-overview/certifications-and-compliance | `mmctl user delete` removes all user data |
| CMP7 | partial | EN, EA | https://docs.mattermost.com/administration-guide/manage/admin/content-flagging | Manual flag review; no keyword DLP found |
| CMP8 | unverified | | https://docs.mattermost.com/deployment-guide/encryption-options | No E2EE doc found; app does not encrypt DB content |
| CMP9 | yes | free; BYOK add-on EA | https://docs.mattermost.com/deployment-guide/encryption-options | TLS; at rest via disk or S3 encryption |
| CMP10 | partial | vendor | https://mattermost.com/pricing/ | "Supports compliance programs including ISO 27001, SOC 2"; FedRAMP not claimed |
| CMP11 | yes | self-hosted; air-gapped ops EA | https://docs.mattermost.com/deployment-guide/air-gapped-operations | CONFLICT: page lists TE/P/E/EA; PLANS says EN/EA |
| OPS1 | yes | Linux free; Kubernetes EN/E/EA | https://docs.mattermost.com/deployment-guide/server/deploy-server | APT, tarball; Docker Compose "Not supported for production" |
| OPS2 | yes | E, EA (not EN) | https://docs.mattermost.com/deployment-guide/server/high-availability-cluster-based-deployment | Code flag `cluster` |
| OPS3 | yes | 100k E; 200k EA | https://docs.mattermost.com/deployment-guide/scale/scaling-for-enterprise | Reference architectures 200 to 200,000 concurrent |
| OPS4 | yes | free (Entry); TE unverified | https://docs.mattermost.com/deployment-guide/backup-disaster-recovery | Database, config, file store |
| OPS5 | partial | Prometheus EN/E/EA (not P) | https://docs.mattermost.com/administration-guide/scale/performance-monitoring-metrics | OpenTelemetry unverified |
| OPS6 | yes | rolling upgrade E/EA | https://docs.mattermost.com/deployment-guide/server/high-availability-cluster-based-deployment | Schema changes need a short outage |
| OPS7 | yes | free | https://docs.mattermost.com/deployment-guide/software-hardware-requirements | "1 - 1,000 users - 1 vCPU/cores, 2 GB RAM" |
| OPS8 | partial | see Licence | https://github.com/mattermost/mattermost/blob/master/LICENSE.txt | AGPL source, MIT binaries, source-available enterprise |
| MOD1 | partial | free | https://docs.mattermost.com/integrations-guide/built-in-slash-commands | /kick, /remove, deactivate; ban and timeout unverified |
| MOD2 | partial | EN, EA | https://docs.mattermost.com/administration-guide/manage/admin/content-flagging | Manual review queue; no automod found |
| MOD3 | partial | free | https://docs.mattermost.com/administration-guide/configure/environment-configuration-settings | API rate limits; no slowmode |
| MOD4 | yes | EN, EA | https://docs.mattermost.com/end-user-guide/collaborate/flag-messages | "Quarantine messages for review" |
| MOD5 | partial | free | https://docs.mattermost.com/product-overview/plans | Email verification only |
| MOD6 | partial | free; guest magic links EN/E/EA | https://docs.mattermost.com/end-user-guide/collaborate/invite-people | Email invites 48 h, single use |
| MOD7 | partial | custom terms of service E/EA | https://docs.mattermost.com/administration-guide/comply/custom-terms-of-service | Terms with re-acceptance |
| MOD8 | partial | E, EA | https://docs.mattermost.com/administration-guide/manage/logging | Audit log only |
| COM1 | unverified | | | No public server directory found |
| COM2 | partial | EN/P/E/EA | https://docs.mattermost.com/integrations-guide/microsoft-calendar | Calendar plugin; no native events |
| COM3 | partial | read-only channels P+ | https://docs.mattermost.com/product-overview/plans | Read-only channels, banners; no cross-server follow |
| COM4 | partial | free | https://docs.mattermost.com/end-user-guide/preferences/manage-your-profile | One global nickname |
| COM5 | partial | free | https://docs.mattermost.com/administration-guide/configure/integrations-configuration-settings | GIPHY GIF picker; no stickers or soundboard |
| MIG1 | yes | free (Entry); TE unverified | https://docs.mattermost.com/administration-guide/onboard/migrate-from-slack | mmetl; see Importers |
| MIG2 | no | | https://github.com/mattermost/mmetl | Slack, Slack Grid, Rocket.Chat only |
| MIG3 | no | Teams sync EN/E/EA | https://docs.mattermost.com/integrations-guide/microsoft-teams-sync | Interop, not import |
| MIG4 | partial | Matrix bridge paid (README P+, PRICE E) | https://github.com/mattermost/mattermost-plugin-matrix-bridge | IRC and Discord first-party unverified |
| MIG5 | yes | EN/E/EA (badge) | https://docs.mattermost.com/administration-guide/onboard/connected-workspaces | CONFLICT: code `HasSharedChannels` passes P |
| EXTRA Playbooks | yes | EN/E/EA (not P) | https://docs.mattermost.com/end-user-guide/workflow-automation/learn-about-playbooks | Entry: 5 runs/month (future) |
| EXTRA Boards | yes | EN/E/EA (not P) | https://docs.mattermost.com/end-user-guide/project-management/project-management-index | Entry: 1,000 cards (future) |
| EXTRA AI agents | yes | one agent unlicensed; full set EN/E/EA | https://docs.mattermost.com/end-user-guide/agents | "Servers without a license get one agent in direct messages" |
| EXTRA mobile EMM/AppConfig | yes | EN/E/EA; Intune MAM EN/EA | https://docs.mattermost.com/deployment-guide/mobile/deploy-mobile-apps-using-emm-provider | Not on Professional |
| EXTRA ABAC, classification, burn-on-read | yes | EN, EA | https://docs.mattermost.com/product-overview/plans | Code: `MinimumEnterpriseAdvancedLicense` |

### Source conflicts (Mattermost)

1. Read-only channels: PRICE and PLANS say Professional; a docs badge says EN/EA; code needs any licence.
2. AD/LDAP sync: PLANS includes Professional; the sync page badge does not.
3. Connected workspaces: badge EN/E/EA; code passes Professional; PRICE lists Enterprise.
4. Entry group calls: PLANS yes; Calls guide says "1:1 Calls + Screen Sharing (Up to 40 minutes)".
5. Audit logging: logging page E/EA; schema page EN/E/EA.
6. Air-gapped: operations page TE/P/E/EA; PLANS EN/EA.
7. TPNS: docs say port 80; code uses an https URL.
8. Source licence: LICENSE.txt says AGPL v3; faq-license says "AGPLv2".
9. @group mentions: badge E/EA; code gates at Professional.

## 2. Zulip

Abbreviations: RTD/ = https://zulip.readthedocs.io/en/latest/production/ ; H/ = https://zulip.com/help/ ; P = https://zulip.com/plans/ . SH = self-hosted. "sup X+" means Zulip's support team covers the feature from self-hosted plan X up; the feature itself is free. Readthedocs text was read from `zulip/zulip` main, which can be ahead of the stable release.

### Licence and plans

- Licence: `zulip/zulip` LICENSE reads "Apache License Version 2.0, January 2004". Plans page footer: "All plans offer the same 100% open-source software."
- Live names: Cloud Free / Standard / Plus; Self-hosted Free / Basic / Business / Enterprise. "Community" is not a column. It is a free sponsored self-hosted plan with unlimited push, for open-source projects, academic research, "Non-profits with no paid staff", educators and clubs.
- Cloud Free ($0): "10,000 messages of search history"; "File storage up to 5 GB total"; guests; integrations.
- Cloud Standard ($6.67/user/month annual, $8 monthly): "Unlimited search history"; 5 GB per user; "Flexible permissions with custom groups"; "Message retention policies"; logo branding; "Priority commercial support"; "Public access option"; Entra ID SSO; compliance exports; credential reset.
- Cloud Plus ($10 annual, $12 monthly, "10 users minimum"): 25 GB per user; "SSO with SAML (Okta, OneLogIn, etc.)"; "SCIM user and group sync"; "Custom domain"; "Limit user list access for guests"; generic OIDC; SAML group sync; audit log. LDAP sync is "Please inquire".
- Self-hosted Free ($0): "Complete team chat solution, with all Zulip features included". Push for eligible communities, or for up to 10 users otherwise.
- Self-hosted Basic ($3.50/user/month, monthly only): "Unlimited mobile notifications"; basic support.
- Self-hosted Business ($6.67 annual, $8 monthly, "25 users minimum"): "Email and chat support for: SSO with SAML, Microsoft Entra ID; AD/LDAP user sync; Guests with configurable access; Full and compliance data exports; Data retention policies".
- Self-hosted Enterprise (contact sales): "Email, chat and phone support for: SSO with OpenID Connect; SCIM user and group sync; Implementation consulting; Custom feature development; Advanced deployment options"; HIPAA, AI/LLM integration and scalability support.

### Mobile push

Source: https://zulip.readthedocs.io/en/latest/production/mobile-push-notifications.html (curl-checked), https://zulip.com/help/self-hosted-billing.

- Why a relay: Apple and Google need "a secret corresponding to the server" compiled into the app, so "it is impossible for a single app in their stores to receive push notifications from multiple, mutually untrusted, servers."
- Mechanism: the server sends to `ZULIP_SERVICES_URL = "https://push.zulipchat.com"`, which forwards to APNs/FCM. Register with the installer flag `--push-notifications`, or set `ZULIP_SERVICE_PUSH_NOTIFICATIONS = True` and run `manage.py register_server`.
- Cost and limits: "Organizations with more than 10 users must upgrade their plan in order to access the Mobile Push Notification Service." Free up to 10 users; Community unlimited for eligible organizations; Basic $3.50/user/month; 30-day Basic trial; API limit "1000 requests per minute".
- E2EE: "Zulip Server 12.0+ uses end-to-end encryption (E2EE) ... message content and metadata ... are not visible to Apple, Google, or Zulip's Mobile Push Notification Service." Cipher: libsodium `crypto_secretbox_easy` (XSalsa20-Poly1305), per-device key. Older servers or apps use the legacy unencrypted protocol. Stated limit: "Incomplete forward secrecy".
- Avoiding the bouncer: the push doc has no section on it. `zproject/default_settings.py` says "Settings for APNS. Only needed on push.zulipchat.com or if rebuilding the mobile app with a different push notifications server", followed by `APNS_TOKEN_KEY_FILE`, `APNS_TEAM_ID`, `ANDROID_FCM_CREDENTIALS_PATH`. So: own app build with own keys. The bouncer code is open source.

### Importers

Importer source: `zerver/data_import/` holds slack, mattermost, rocketchat, microsoft_teams.

- Slack (https://zulip.com/help/import-from-slack): "Message history, including attachments and emoji reactions"; "Users, including names, emails, roles, avatars, time zones, and custom profile fields"; "Channels, including all user subscriptions"; "Custom emoji". "Slack threads are imported as topics". Not imported: "Message edit history and @user joined #channel_name messages". Private channels and DMs only from Slack Business+ or Enterprise Grid exports. Group DMs: not in the help text; `slack.py` reads `mpims.json`.
- Mattermost (https://zulip.com/help/import-from-mattermost): "all public and private channel messages"; "Direct messages will only be imported from Mattermost workspaces containing a single team"; thread replies imported but not marked as threads.
- Rocket.Chat (https://zulip.com/help/import-from-rocketchat): messages with attachments and reactions, users, channels and discussions, custom emoji, from a mongodump.
- Microsoft Teams (https://zulip.com/help/import-from-microsoft-teams): "This feature is currently in beta"; "Message history, excluding direct messages and messages in private channels".
- Discord, HipChat, Gitter: no importer in source. https://zulip.com/help/moving-from-discord has no import step. Custom import: Cloud Plus "Please inquire"; SH Business "Billed hourly".

### Clustering, HA and scale

Sources: https://zulip.readthedocs.io/en/latest/production/requirements.html#scalability, https://zulip.readthedocs.io/en/latest/production/deployment.html, https://zulip.readthedocs.io/en/latest/production/system-configuration.html, https://zulip.readthedocs.io/en/latest/production/postgresql.html.

- "Zulip has full support for each top-level service living on its own machine." Remote PostgreSQL "with a warm-standby replica for reliability".
- "we recommend a hot spare over load-balancing for most installations desiring extra redundancy." Failover is manual (`pg_ctl promote`).
- "For servers with several thousand daily active users, Zulip supports sharding its real-time-push Tornado service ... by realm/organization ... and by user ID". "A single Tornado instance can usually handle 1000-1500 concurrent active users".
- Sizing: "With 2000+ daily active users 32 GB of RAM, plus 32 GB for the database. Roughly linear scaling beyond that." chat.zulip.org: "12K user accounts (~300 daily actives) ... single-server installation with 16 GB of RAM".
- Marketing: zulip.com/self-hosting says "10,000s of users". Largest named install: unverified.

### Capability table

| id | offered | edition | source URL | note |
|---|---|---|---|---|
| ID1 | yes | free | https://zulip.readthedocs.io/en/latest/production/authentication-methods.html | Email and password backend |
| ID2 | yes | SH free (OIDC sup Enterprise); Cloud: social all, Entra Std+, OIDC Plus | https://zulip.readthedocs.io/en/latest/production/authentication-methods.html | Google, GitHub, GitLab, Apple, any OIDC |
| ID3 | yes | SH free (sup Business+); Cloud Plus | https://zulip.readthedocs.io/en/latest/production/authentication-methods.html | Okta, OneLogin, Entra ID |
| ID4 | yes | SH free (sup Business+); Cloud "Please inquire" | https://zulip.readthedocs.io/en/latest/production/authentication-methods.html | LDAP including Active Directory |
| ID5 | yes | SH free (sup Enterprise); Cloud Plus | https://zulip.readthedocs.io/en/latest/production/scim.html | User and group sync |
| ID6 | no | | https://github.com/zulip/zulip/issues/9521 | 2FA code exists, off by default; passkeys unverified |
| ID7 | yes | free; guest user-list limit Cloud Plus | https://zulip.com/help/guest-users | Guests see only subscribed channels |
| ID8 | no | | https://zulip.com/help/deactivate-your-account | Separate account per organization; apps hold many |
| ID9 | yes | deactivate free; credential reset Cloud Std+ | https://zulip.com/help/deactivate-or-reactivate-a-user | Admin takeover unverified |
| ID10 | yes | free; custom-group permissions Cloud Std+ | https://zulip.com/help/user-roles | Owner, admin, moderator, member, guest |
| ID11 | yes | free | https://zulip.com/help/channel-permissions | Per-channel post, subscribe, topic permissions |
| ID12 | yes | SH free | https://zulip.readthedocs.io/en/latest/production/multiple-organizations.html | Many organizations on one server |
| ID13 | yes | free | https://zulip.com/plans/ | Admin settings inside the web app |
| ID14 | partial | free | https://zulip.com/help/custom-profile-fields | Custom fields; org chart unverified |
| MSG1 | yes | free | https://zulip.com/plans/ | |
| MSG2 | yes | free | https://zulip.com/help/channel-permissions | Shared or private history |
| MSG3 | yes | free | https://zulip.com/help/direct-messages | |
| MSG4 | yes | free | https://zulip.com/help/search-for-messages | Group direct messages |
| MSG5 | yes | free | https://zulip.com/help/introduction-to-topics | Every message has a topic |
| MSG6 | partial | free | https://zulip.com/help/moving-from-discord | Topics "fulfill the role of a forum" |
| MSG7 | yes | free | https://zulip.com/help/custom-emoji | Reactions and custom emoji |
| MSG8 | yes | free | https://zulip.com/help/mention-a-user-or-group | @all, @everyone, @channel, @topic, groups |
| MSG9 | yes | free | https://zulip.com/help/restrict-message-editing-and-deletion | Edit history, time limits |
| MSG10 | partial | free | https://zulip.com/help/star-a-message | Starred messages; no message pins (open issue) |
| MSG11 | yes | free | https://zulip.com/help/create-a-poll | Polls and to-do lists |
| MSG12 | yes | free; Cloud storage tiered | https://zulip.com/help/share-and-upload-files | Cloud Free 5 GB total |
| MSG13 | yes | free | https://zulip.com/help/image-video-and-website-previews | |
| MSG14 | yes | free | https://zulip.com/help/code-blocks | Markdown, highlighting, LaTeX |
| MSG15 | yes | free; Cloud Free 10,000 messages | https://zulip.com/help/search-for-messages | channel, topic, dm filters; no date operator (open issue) |
| MSG16 | yes | free | https://zulip.com/help/marking-messages-as-unread | |
| MSG17 | partial | free | https://zulip.com/help/mute-a-topic | Mute channel/topic/user; DND schedules unverified |
| MSG18 | yes | free | https://zulip.com/help/schedule-a-message | Reminders: https://zulip.com/help/schedule-a-reminder |
| MSG19 | yes | free | https://zulip.com/help/status-and-availability | Typing, presence, emoji status |
| MSG20 | partial | free | https://zulip.com/plans/ | UI in 20+ languages; message translation unverified |
| AV1 | no | | https://zulip.com/help/start-a-call | A call is a provider link in a message |
| AV2 | yes | free | https://zulip.com/help/start-a-call | 1:1 and group via external provider |
| AV3 | partial | free | https://zulip.com/help/start-a-call | Video yes; screen share depends on provider |
| AV4 | unverified | | | Depends on provider |
| AV5 | unverified | | | Depends on provider |
| AV6 | yes | free | https://zulip.readthedocs.io/en/latest/production/video-calls.html | Self-hosted Jitsi, BigBlueButton, Nextcloud Talk |
| CL1 | yes | free | https://zulip.com/plans/ | |
| CL2 | yes | free | https://zulip.com/help/desktop-app-install-guide | Windows, macOS, Linux |
| CL3 | yes | free | https://zulip.com/help/mobile-app-install-guide | |
| CL4 | yes | free | https://zulip.com/help/mobile-app-install-guide | Google Play or APK |
| CL5 | yes | SH free to 10 users; else Basic+ or Community | https://zulip.readthedocs.io/en/latest/production/mobile-push-notifications.html | See Mobile push above |
| CL6 | partial | free | https://zulip.com/help/desktop-app-install-guide | Offline installer; PWA push is an open issue |
| CL7 | partial | free | https://zulip.readthedocs.io/en/latest/subsystems/accessibility.html | Aims for WCAG 2.2 AA; no conformance claim |
| INT1 | yes | free | https://zulip.com/api/ | REST API and bots |
| INT2 | yes | free | https://zulip.com/help/outgoing-webhooks | Incoming and outgoing |
| INT3 | partial | free | https://zulip.readthedocs.io/en/latest/subsystems/slash-commands.html | Built-in commands only |
| INT4 | unverified | | https://zulip.com/integrations/ | No app marketplace found |
| INT5 | yes | free | https://zulip.com/integrations/ | "Over 130 native integrations" |
| INT6 | yes | free | https://zulip.com/integrations/slack_incoming | Slack-compatible incoming webhook |
| INT7 | partial | free | https://zulip.readthedocs.io/en/latest/subsystems/widgets.html | Poll/todo widgets; bot button forms |
| CMP1 | yes | SH free (sup Business+); Cloud Plus | https://zulip.com/plans/ | "Detailed audit log of administrative actions" |
| CMP2 | yes | SH free; Cloud Std+ | https://zulip.com/help/message-retention-policy | Org and per-channel |
| CMP3 | unverified | | | |
| CMP4 | yes | SH free; Cloud Std+ | https://zulip.readthedocs.io/en/latest/production/export-and-import.html | `export_search` compliance export |
| CMP5 | yes | free; full private export Cloud Std+ | https://zulip.com/help/export-your-organization | `export_single_user` per user |
| CMP6 | yes | free | https://zulip.com/help/gdpr-compliance | Delete messages, files, accounts |
| CMP7 | unverified | | | Alert words only |
| CMP8 | partial | free | https://github.com/zulip/zulip/issues/6096 | Push payloads only; message E2EE open issue |
| CMP9 | yes | free | https://zulip.com/security/ | TLS; at rest self-managed |
| CMP10 | partial | HIPAA SH Enterprise | https://zulip.com/plans/ | SOC 2 and ISO 27001 unverified |
| CMP11 | yes | SH free | https://zulip.com/security/ | Air-gapped install possible |
| OPS1 | yes | free | https://zulip.readthedocs.io/en/latest/production/docker.html | Installer, Docker Compose, Helm, cloud images |
| OPS2 | partial | free (sup Enterprise) | https://zulip.readthedocs.io/en/latest/production/requirements.html | Warm standby, manual failover |
| OPS3 | yes | free | https://zulip.readthedocs.io/en/latest/production/requirements.html | Sharding for several thousand daily actives |
| OPS4 | yes | free | https://zulip.readthedocs.io/en/latest/production/export-and-import.html | `backup`, `restore-backup` |
| OPS5 | partial | free | https://zulip.readthedocs.io/en/latest/production/troubleshooting.html | Nagios plugins; Prometheus not documented |
| OPS6 | partial | free | https://zulip.readthedocs.io/en/latest/production/upgrade.html | Downtime "under 30 seconds" |
| OPS7 | yes | free | https://zulip.readthedocs.io/en/latest/production/requirements.html | 2 GB RAM, 10 GB disk |
| OPS8 | yes | Apache-2.0 | https://github.com/zulip/zulip/blob/main/LICENSE | All self-hosted features open source |
| MOD1 | partial | free | https://zulip.com/help/moderating-open-organizations | Deactivate, unsubscribe; timeout unverified |
| MOD2 | partial | free | https://zulip.com/help/moderating-open-organizations | Disposable-email block, waiting period |
| MOD3 | partial | free | https://zulip.com/plans/ | API rate limits; no slowmode |
| MOD4 | yes | free | https://zulip.com/help/report-a-message | Reports go to moderators' channel |
| MOD5 | partial | free | https://zulip.com/help/restrict-permissions-of-new-members | Waiting period, email domains |
| MOD6 | partial | free | https://zulip.com/help/invite-new-users | Expiring links; use limits unverified |
| MOD7 | partial | free | https://zulip.com/help/configure-a-custom-welcome-message | Welcome message, default channels |
| MOD8 | partial | Cloud Plus | https://zulip.com/plans/ | Audit log only |
| COM1 | yes | Cloud | https://zulip.com/help/communities-directory | Self-hosted listing planned |
| COM2 | partial | free | https://zulip.com/integrations/ | Calendar integration only |
| COM3 | partial | free | https://zulip.com/help/channel-posting-policy | Admin-only posting; no federation |
| COM4 | partial | free | https://zulip.com/help/custom-profile-fields | Per-org name via per-org account |
| COM5 | partial | free | https://zulip.com/help/animated-gifs | GIPHY, Tenor, KLIPY; no stickers |
| MIG1 | yes | free | https://zulip.com/help/import-from-slack | See Importers |
| MIG2 | no | custom import paid | https://zulip.com/help/moving-from-discord | No Discord importer |
| MIG3 | partial | free | https://zulip.com/help/import-from-microsoft-teams | Beta; no DMs or private channels |
| MIG4 | partial | free | https://zulip.com/integrations/matrix | IRC, Matrix, Slack bridges |
| MIG5 | no | | https://github.com/zulip/zulip/issues/356 | Federation is the most-reacted open issue |
| EXTRA public access | yes | SH free; Cloud Std+ | https://zulip.com/help/public-access-option | Web-public channels readable without login |
| EXTRA AI/LLM | partial | SH sup Enterprise | https://zulip.readthedocs.io/en/latest/production/ai-integrations.html | Not on Cloud |

## 3. Rocket.Chat

Abbreviations: RD/ = https://docs.rocket.chat/docs/ ; PR = https://www.rocket.chat/pricing ; GH/ = https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/ (develop branch at the access date). The pricing page marks rows that Community or Starter lacks with CSS classes (`nc`, `ns`); the reader decoded them from the stylesheet, so pricing gates are inferred, not stated in words.

### Licence and plans

- LICENSE (https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/LICENSE): content under `apps/meteor/ee/` and `ee/` falls under the EE licence; everything else "is available under the MIT (Expat) license".
- EE licence (https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/apps/meteor/ee/LICENSE): code "may only be used in production, if you ... have a valid Rocket.Chat Enterprise Edition subscription for the correct number of user seats".
- Live names (https://docs.rocket.chat/docs/our-plans, updated 2026-11-19): "three paid plans ... Commercial, Government, and Defense"; "Two free entry points, Starter and Community". "Effective April 29, 2026, the Pro plan moved to legacy status". "Enterprise" is only the pricing page heading. This differs from the brief's Starter/Pro/Enterprise. No prices are published.
- Starter: "Up to 50 users", counted as users added. Community: "Up to 100 concurrent users". From 9.0.0 (2026-11-10), Community loses LDAP, SAML and custom OAuth/OIDC (https://docs.rocket.chat/docs/prepare-for-authentication-changes-in-9-0-0).
- Commercial rows not in Community (pricing markup): AD/LDAP; SSO with SAML, OAuth 2.0, OIDC; LDAP/SAML group mapping; custom roles; DLP; read receipts; Matrix federation; MS Teams bridge; ID-only push; custom push gateway; air-gapped; HA with failover; disaster recovery; multi-instance and microservices; admin security event logging; audit trails; compliance reports and exports; SOC 2 Type 2, HIPAA BAA, FINRA/MiFID II, NIS2/DORA support; Pexip video; white labelling; standard support. Add-ons: voice, native video, governed AI, mission-critical support.
- Government adds FIPS 140-3. Defense adds DISA STIG (planned), ABAC, Iron Bank, "DoW ATO up to IL6", classified networks, XMPP federation.
- Licence modules in code (https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/packages/core-typings/src/license/LicenseModule.ts): auditing, canned-responses, ldap-enterprise, livechat-enterprise, voip-enterprise, omnichannel-mobile-enterprise, engagement-dashboard, push-privacy, scalability, teams-mention, saml-enterprise, oauth-enterprise, device-management, federation, videoconference-enterprise, message-read-receipt, outlook-calendar, hide-watermark, custom-roles, accessibility-certification, unlimited-presence, contact-id-verification, teams-voip, outbound-messaging, abac, fips, experimental-enterprise-features, video-conference-native. Limit kinds (ILicenseV3.ts): activeUsers, guestUsers, roomsPerGuest, privateApps, marketplaceApps, monthlyActiveContacts.

### Mobile push

Source: https://docs.rocket.chat/docs/push-notifications-faq (curl-checked).

- Quota: "Community workspaces are limited to 10,000 push notifications per month"; "Once the monthly quota is exhausted, Rocket.Chat stops sending push notifications". Starter: "Push notifications Unlimited" (https://docs.rocket.chat/docs/our-plans). No price is stated for the gateway itself.
- Registration: "If it isn't registered, the gateway won't work even when Enable Gateway is on"; you must accept the Cloud Service Privacy Terms. Code (https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/apps/meteor/server/configuration/pushNotification.ts) requires `Push_enable_gateway && Register_Server && Cloud_Service_Agree_PrivacyTerms`.
- Privacy: "Hide message content from Apple and Google (and the Gateway, if enabled)" is "Premium plans only"; "When on, Rocket.Chat sends only a message ID". Code: setting `Push_request_content_from_server` has `modules: ['push-privacy']`. CONFLICT: pricing markup puts ID-only push in Starter.
- Avoiding the gateway: "The official mobile apps only work with the Rocket.Chat gateway." Under "Your own credentials": "You publish your own white-labeled version of the mobile app ... Your own APN and FCM credentials". Guides: https://developer.rocket.chat/docs/configuring-push-notifications and https://developer.rocket.chat/docs/mobile-app-white-labeling. CONFLICT: pricing marks "Custom mobile push gateway" as not in Community; the gateway toggle and key settings have no licence flag in code.

### Importers

- Code importers (https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/apps/meteor/server/lib/import/): slack, slack-users, csv, omnichannel-contacts. No HipChat, Mattermost, Discord or Teams.
- Slack (https://docs.rocket.chat/docs/import-from-slack): "Import workspace data including users, channels, and messages." The doc does not list DMs; the code (`SlackImporter.ts`) reads `channels.json`, `groups.json`, `mpims.json`, `dms.json`, `users.json` and maps `thread_ts` to threads. Files stay hidden "until you run Download Pending Files".
- Slack users CSV and generic CSV ZIP: https://docs.rocket.chat/docs/import-from-csv.
- HipChat: "HipChat importer removed" (https://docs.rocket.chat/docs/deprecated-and-phasing-out-features).
- Mattermost: "Rocket.Chat does not currently support Mattermost as a built-in importer" (https://docs.rocket.chat/docs/data-migration).

### Clustering, HA and scale

- https://docs.rocket.chat/docs/reference-architectures: "Up to 500" concurrent users: "Single instance, no high availability". "500 and above": "Multiple instances behind a load balancer, high availability". "Above 5,000": "Microservices with per-service scaling" on "Kubernetes with the official Helm chart"; "ddp-streamer: plan 1 pod per 500 concurrent users". No larger figure.
- Gate: multi-instance and microservices docs are tagged Premium. Code (https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/ee/packages/network-broker/src/licenseEnforcement.ts): "if there is no scalability module enabled, then we should not allow more than one service per environment". Presence broadcast stops above 200 connections without `unlimited-presence` or `scalability` (https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/ee/packages/presence/src/Presence.ts).
- Air-gapped: Community "becomes read-only after a 10-day grace period"; Starter must renew every 90 days (https://docs.rocket.chat/docs/rocketchat-air-gapped-deployment). The same doc allows building a FOSS version "without requiring a license".

### Capability table

| id | offered | edition | source URL | note |
|---|---|---|---|---|
| ID1 | yes | free (Community) | https://docs.rocket.chat/docs/prepare-for-authentication-changes-in-9-0-0 | Local auth available on all plans |
| ID2 | partial | built-in social free; custom OAuth/OIDC Starter+ | https://docs.rocket.chat/docs/openid-connect | Custom OAuth removed from Community at 9.0.0 |
| ID3 | yes | Starter, Commercial, Government, Defense | https://docs.rocket.chat/docs/saml | "not available on Community workspaces" |
| ID4 | yes | Starter and paid | https://docs.rocket.chat/docs/ldap-premium-settings | Advanced sync is premium |
| ID5 | unverified | | | No SCIM in docs, pricing or repo |
| ID6 | partial | TOTP, email 2FA free; per-role enforcement paid | https://docs.rocket.chat/docs/two-factor-authentication-configuration | WebAuthn "Planned for release in 2026" |
| ID7 | yes | Premium (Starter unverified) | https://docs.rocket.chat/docs/guest-users | Guests limited to one room plus DMs |
| ID8 | unverified | | https://docs.rocket.chat/docs/access-your-workspace | Clients can add many workspaces; shared identity unverified |
| ID9 | yes | free | https://docs.rocket.chat/docs/manage-workspace-users | Deactivate, delete, set password, reset 2FA |
| ID10 | yes | RBAC free; custom roles Commercial+ | https://docs.rocket.chat/docs/security-overview | Module `custom-roles` |
| ID11 | partial | private rooms free; ABAC Defense | https://docs.rocket.chat/docs/room-roles | Fixed room roles |
| ID12 | unverified | | | No multi-tenant docs |
| ID13 | yes | free | https://docs.rocket.chat/docs/manage-workspace-users | Workspace admin UI |
| ID14 | partial | free | https://docs.rocket.chat/docs/custom-fields | Custom user fields; directory |
| CMP1 | partial | Commercial+ | https://docs.rocket.chat/docs/audit-logs | Message Auditor; module `auditing` |
| CMP2 | yes | free | https://docs.rocket.chat/docs/configure-retention-policies | Global and per-room |
| CMP3 | unverified | | | |
| CMP4 | partial | Smarsh no plan tag | https://docs.rocket.chat/docs/smarsh | .eml export; Global Relay, Actiance unverified |
| CMP5 | partial | user export free; admin exports paid | https://docs.rocket.chat/docs/user-data-download | |
| CMP6 | partial | free | https://docs.rocket.chat/docs/gdpr | Delete user; message erasure setting |
| CMP7 | partial | DLP Starter+ | https://docs.rocket.chat/docs/data-loss-prevention-dlp-app | Regex rules blur matches |
| CMP8 | yes | free | https://docs.rocket.chat/docs/end-to-end-encryption-specifications | RSA-OAEP 2048, AES-GCM 256 |
| CMP9 | partial | free | https://docs.rocket.chat/docs/security-overview | TLS at proxy; server at-rest unverified |
| CMP10 | partial | vendor | https://www.rocket.chat/pricing | ISO 27001, SOC 2 Type 2, HIPAA BAA, IL6; no FedRAMP |
| CMP11 | partial | self-host free; air-gapped Starter+ | https://docs.rocket.chat/docs/rocketchat-air-gapped-deployment | Community read-only after 10 days offline |
| CL5 | yes | Community 10k/month; Starter+ unlimited | https://docs.rocket.chat/docs/push-notifications-faq | Gateway needs Cloud registration |
| OPS2 | yes | Commercial, Government, Defense | https://docs.rocket.chat/docs/running-multiple-instances | Code module `scalability` enforces it |
| OPS3 | partial | paid | https://docs.rocket.chat/docs/reference-architectures | Top tier "Above 5,000" concurrent |
| MIG1 | yes | free | https://docs.rocket.chat/docs/import-from-slack | Channels, private, DMs, threads, files |
| MIG2 | no | | https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/apps/meteor/server/lib/import/ | No importer |
| MIG3 | no | | https://github.com/RocketChat/Rocket.Chat/blob/d3b097a02abe9ebf997ae5817837f41be5836cf0/apps/meteor/server/lib/import/ | Teams Bridge only |
| MIG4 | yes | SlackBridge free; Teams Bridge Starter+; XMPP Defense | https://docs.rocket.chat/docs/microsoft-teams-bridge | IRC bridge in code |
| MIG5 | yes | Starter and paid | https://docs.rocket.chat/docs/federation-architecture-and-capabilities | Native Matrix homeserver since 7.11 |
| EXTRA omnichannel | partial | core free; extras paid | https://docs.rocket.chat/docs/omnichannel | Modules `livechat-enterprise`, `canned-responses` |
| EXTRA read receipts | yes | Starter and paid | https://docs.rocket.chat/docs/read-receipts | Module `message-read-receipt` |
| EXTRA video | yes | Jitsi, BBB free; Zoom, Meet, Pexip Starter+ | https://docs.rocket.chat/docs/our-plans | Native video is a paid add-on |
| EXTRA device management | yes | Commercial+ | https://docs.rocket.chat/docs/device-management | Module `device-management` |

## 4. Element (Matrix, Synapse, Element Server Suite)

Abbreviations: SY/ = https://element-hq.github.io/synapse/latest/ ; EP = https://element.io/pricing ; ED/ = https://docs.element.io/latest/ . The reader read the tick and cross icons on EP. The page's aria-labels disagree with its icons in places (Helm charts, HA, auto-scaling, S3, air-gapped, push gateway); the icons were used.

### Licence and plans

- Live plan names on EP: Community (ESS Community, AGPL, free, 1-100 users), Enterprise (ESS Pro, self-hosted, "Priced per seat/month") and Sovereign (ESS Pro, air-gapped, "Priced per deployment"). There is also ESS TI-M, an ESS Pro variant for German healthcare. "ESS Enterprise" is not a product name.
- Synapse: `LICENSE-AGPL-3.0` and `LICENSE-COMMERCIAL`; it "can be used either: (1) for free under the terms of the GNU Affero General Public License ... OR (2) under the terms of a paid-for Element Commercial License agreement". EP calls Community Synapse "not for use in production environments". Element X Android/iOS, Element Web, Element Admin and Matrix Authentication Service are AGPL-3.0 (Element Admin also commercial).
- ESS Community (https://github.com/element-hq/ess-helm): "freely available under the AGPLv3 license and tailored to small-/mid-scale, non-commercial community use cases with up to 100 users". Element Call/MatrixRTC is in Community.
- Paid-only on EP (Enterprise and Sovereign): Synapse Pro; security advisories; CRA compliance; SBOMs; accessibility compliance; installation support; LTS; level 3 support; SLA ("4 Business hours"); admin interface; Advanced IAM (LDAP and SCIM, formerly Group Sync); LDAP/AD authentication; auditing and reporting; moderation; retention policies; Secure Border Gateway; OpenShift support; auto-scaling; HA and rolling updates; S3; Element Pro client (custom theme, certificate pinning, MDM, content scanning). Sovereign only: air-gapped deployment, custom mobile push gateway, cross-domain gateway add-on. Add-on for both: white-labelled mobile app.
- ess-helm README Pro additions: Synapse Pro, Secure Border Gateway, Advanced IAM, Content Scanner, AuditBot, AdminBot, LDAP, S3, distroless images.
- Synapse Pro licence: unverified (no public repo).

### Mobile push

- Model: "A client's homeserver forwards information about received events to the push gateway. The gateway then submits a push notification to the push notification provider" (https://spec.matrix.org/latest/push-gateway-api/).
- Stock apps: "The stock Android and iOS Apps will use an Element owned Push Gateway"; "The URL of our push gateway is https://matrix.org/_matrix/push/v1/notify" (https://docs.element.io/latest/element-server-suite-classic/advanced-configuration/notifications-mdm-push-gateway/, curl-checked). Code agrees: Element X Android `PUSHER_HTTP_URL`, Element X iOS `pushGatewayBaseURL = "https://matrix.org"`, classic Element Android `pusher_http_url`.
- Content: Element X Android and iOS register `EVENT_ID_ONLY` pushers. Sygnal docs: with `event_id_only`, "data sent to the notification service (FCM or APNs) is minimal".
- Cost and limits of Element's gateway: unverified. Element says "We recommend that you use the stock Element Apps ... together with the Push Gateway that we as Element host."
- Own gateway: "Sygnal (push gateway) instances are deployed by the owner of the application"; "It is not feasible to allow end-users to configure their own Sygnal instance, because the Sygnal instance needs the appropriate FCM or APNs secrets that belong to the application" (https://github.com/element-hq/sygnal, AGPL-3.0; `matrix-org/sygnal` is archived). Element: "This is why you can not use the stock Element Apps, but will need to upload your own version of the Element App." Classic iOS can set the gateway by MDM AppConfig; "The Android Element App does not support AppConfig currently."
- Android without FCM: Element X Android links Firebase only into the `gplay` flavor and UnifiedPush into all flavors, with an `fdroid` flavor. UnifiedPush default gateway: `https://matrix.gateway.unifiedpush.org/_matrix/push/v1/notify`.
- Paid: EP lists "Custom mobile push gateway" ("Push notifications via your own infrastructure") for Sovereign only. ESS Pro docs have a Sygnal component (https://docs.element.io/latest/element-server-suite-pro/configuring-components/sygnal/configuring/).

### Importers

- No current official Slack, Discord or Teams importer on element.io.
- Element's managed bridges: "The Slack bridge is no longer available for purchase" (https://docs.element.io/latest/element-cloud-documentation/integrations/slack-bridge/). "The Teams bridge is no longer available for purchase. This documentation is for existing customers of the bridge only." (https://docs.element.io/latest/element-cloud-documentation/integrations/teams-bridge/).
- Third-party bridges with history backfill: mautrix-slack (https://github.com/mautrix/slack, AGPL-3.0; roadmap ticks "Reading pre-login message history" and threads). mautrix-discord (https://github.com/mautrix/discord; backfill off by default, `dm: 0`, `channel: 0`). `matrix-org/matrix-appservice-slack` is archived. `matrix-appservice-irc` is active.

### Clustering, HA and scale

- Synapse workers (https://element-hq.github.io/synapse/latest/workers.html): workers "are (eventually) intended to scale horizontally independently"; Redis and PostgreSQL required; event persisters shard "by room ID" experimentally. No HA, failover or user counts in that doc.
- Synapse Pro (https://element.io/server-suite/synapse-pro): "Synapse Pro is part of Element Server Suite Pro (ESS Pro)." "High availability by default, both within a deployment and across multiple data centres"; "memory footprint is 5x smaller"; "up to 50 tenants per shard".
- ess-helm README: ESS Pro is for "more than 100 users up to massive scale in the millions"; Pro adds "In-cluster high availability (HA)" and "Dynamic and automatic scaling".
- Claims (https://element.io/server-suite): "125M+ users worldwide", "100K+ deployments", "50M+ largest public deployment", "500K+ largest commercial deployment". Bundeswehr case study: "more than 100,000 active users" (https://element.io/en/case-studies/bundeswehr).

### Capability table

| id | offered | edition | source URL | note |
|---|---|---|---|---|
| ID1 | yes | free (Synapse, ESS Community) | https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html | Local password database |
| ID2 | yes | free | https://element-hq.github.io/synapse/latest/openid.html | Synapse OIDC; MAS upstream OIDC |
| ID3 | partial | free (legacy Synapse auth) | https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html | MAS "does not support ... SAML" |
| ID4 | partial | LDAP auth and sync ESS Pro | https://element.io/pricing | OSS `matrix-synapse-ldap3` module exists |
| ID5 | yes | ESS Pro (Advanced IAM) | https://element.io/pricing | "LDAP/SCIM (Advanced IAM)" |
| ID6 | unverified | | | No native MFA doc; delegated to IdP |
| ID7 | yes | free | https://spec.matrix.org/latest/client-server-api/#guest-access | Off by default |
| ID8 | partial | free (protocol) | https://spec.matrix.org/latest/appendices/ | ID tied to homeserver; federates across servers |
| ID9 | yes | free | https://element-hq.github.io/synapse/latest/admin_api/user_admin_api.html | Deactivate, reset, lock, suspend, login-as |
| ID10 | yes | free | https://spec.matrix.org/latest/client-server-api/#mroompower_levels | Per-room power levels |
| ID11 | yes | free | https://element.io/pricing | Invite-only rooms, per-room levels |
| ID12 | partial | free | https://spec.matrix.org/latest/client-server-api/#spaces | Spaces group rooms; not isolated tenants |
| ID13 | yes | Admin API free; Element Admin CONFLICT | https://github.com/element-hq/ess-helm | README lists it in Community; EP marks paid |
| ID14 | partial | free | https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html | User directory; custom fields unverified in Synapse |
| CMP1 | partial | ESS Pro (AuditBot) | https://docs.element.io/latest/element-server-suite-pro/configuring-components/auditbot/ | Room events; admin-action log unverified |
| CMP2 | yes | in OSS Synapse; EP marks Pro (CONFLICT) | https://element-hq.github.io/synapse/latest/message_retention_policies.html | Per-room retention experimental |
| CMP3 | unverified | | | |
| CMP4 | partial | ESS Pro | https://docs.element.io/latest/element-server-suite-pro/configuring-components/auditbot/outputs/ | HTTP, Azure, S3, SMTP outputs |
| CMP5 | yes | free | https://element-hq.github.io/synapse/latest/usage/administration/admin_faq.html | `export-data <user_id>` per user |
| CMP6 | yes | free | https://element-hq.github.io/synapse/latest/admin_api/user_admin_api.html | Deactivate with `erase` |
| CMP7 | partial | spam modules free; content scanning Pro | https://element-hq.github.io/synapse/latest/modules/spam_checker_callbacks.html | |
| CMP8 | yes | free | https://element.io/pricing | E2EE by default |
| CMP9 | partial | free | https://spec.matrix.org/latest/server-server-api/ | Federation over HTTPS; at rest unverified |
| CMP10 | yes | vendor | https://element.io/pricing | ISO/IEC 27001:2022, Cyber Essentials Plus; SOC 2 unverified |
| CMP11 | yes | self-host free; air-gapped Sovereign | https://element.io/pricing | |
| CL5 | yes | stock apps: gateway cost unverified; own gateway Sovereign | https://docs.element.io/latest/element-server-suite-classic/advanced-configuration/notifications-mdm-push-gateway/ | Stock apps use matrix.org gateway |
| OPS2 | yes | workers free; HA ESS Pro | https://element-hq.github.io/synapse/latest/workers.html | Synapse Pro claims HA across data centres |
| OPS3 | partial | vendor claims | https://element.io/server-suite | 500K+ largest commercial; Bundeswehr 100,000+ |
| MIG1 | no | | https://docs.element.io/latest/element-cloud-documentation/integrations/slack-bridge/ | Bridge discontinued; no importer |
| MIG2 | no | | https://github.com/mautrix/discord | Third-party bridge backfill only |
| MIG3 | no | | https://docs.element.io/latest/element-cloud-documentation/integrations/teams-bridge/ | Bridge discontinued; no importer |
| MIG4 | partial | third-party OSS | https://github.com/mautrix/slack | Element's managed bridges no longer sold |
| MIG5 | yes | free | https://spec.matrix.org/latest/server-server-api/ | Federation, with allow-list option |

### Source conflicts (Element)

1. Admin console: EP marks it paid; ess-helm README and Synapse docs say "Element Admin as part of ESS Community and Pro".
2. Retention policies: EP marks paid; open-source Synapse has them.
3. EP aria-labels disagree with icons for six rows; icons used.


## 5. Demand data: most-reacted open issues on GitHub

Method: `gh api search/issues` with `sort=reactions`, open issues only, on 2026-11-24. The count is the total of all reaction types. The `+1` count is given beside it.

### zulip/zulip

Zulip labels feature requests `new feature`, and its issue template offers a "Feature or improvement request" form. Its template also sends open-ended feature ideas to a discussion page (https://zulip.readthedocs.io/en/latest/contributing/suggesting-features.html), so GitHub holds the specific proposals. 226 open issues carry `new feature`; 1168 issues are open in total.

Top 15 open issues of any label, by total reactions (the `new feature` label is marked F):

| # | Title | Reactions (total / +1) | F | URL |
|---|---|---|---|---|
| 1 | Federation capability | 79 / 64 | F | https://github.com/zulip/zulip/issues/356 |
| 2 | Add support for pinning topics within a channel | 70 / 51 | | https://github.com/zulip/zulip/issues/19483 |
| 3 | End-to-End Encryption for Group Chat | 48 / 46 | F | https://github.com/zulip/zulip/issues/6096 |
| 4 | Add an option to make web-public channels search indexable | 40 / 40 | | https://github.com/zulip/zulip/issues/21881 |
| 5 | Add support for topics in direct message conversations | 36 / 36 | F | https://github.com/zulip/zulip/issues/1555 |
| 6 | Do we have any plan to support voice message like wechat | 34 / 34 | F | https://github.com/zulip/zulip/issues/10643 |
| 7 | integrations: Add voice chat. | 33 / 33 | F | https://github.com/zulip/zulip/issues/7330 |
| 8 | Allow link previews to be removed from a message | 33 / 29 | | https://github.com/zulip/zulip/issues/19466 |
| 9 | Allow fully deleting bots | 31 / 31 | F | https://github.com/zulip/zulip/issues/10088 |
| 10 | Feature Request: Pinned message | 28 / 26 | F | https://github.com/zulip/zulip/issues/20745 |
| 11 | MermaidJS Rederer Support | 22 / 22 | F | https://github.com/zulip/zulip/issues/16825 |
| 12 | Custom favicons | 21 / 21 | F | https://github.com/zulip/zulip/issues/11752 |
| 13 | Notify message sender about emoji reactions | 19 / 17 | F | https://github.com/zulip/zulip/issues/27327 |
| 14 | Global times not working inside poll | 17 / 17 | | https://github.com/zulip/zulip/issues/16821 |
| 15 | Add Search Operators by Date | 16 / 15 | F | https://github.com/zulip/zulip/issues/25436 |

Next in line: "Make Zulip an OAuth Provider" (16, https://github.com/zulip/zulip/issues/17042), "Improve /todo widget usability" (15), "Demote resolved topics in left sidebar" (14), "Anonymous Polls" (12), "Support PWA Notifications" (11, https://github.com/zulip/zulip/issues/34240), "Remaining TODO items for enabling two-factor authentication" (10, https://github.com/zulip/zulip/issues/9521).

Themes in users' words: federation, E2EE, voice (calls and voice messages), pinning (topics and messages), public search indexing.

### mattermost/mattermost

Mattermost does not take feature requests on GitHub. Its bug template says: "This issue is not a feature request. You can request features and make product suggestions here: https://mattermost.uservoice.com/forums/306457-general/." A label "Move to Feature Ideas forum" exists for redirected requests. So only 631 issues are open, and only 37 carry `kind/feature`. The list below is the top 15 open issues by total reactions, excluding issues labelled `Bug Report/Open` (the label the bug template applies). It is thin demand data. Labels are in brackets.

| # | Title | Reactions (total / +1) | Label | URL |
|---|---|---|---|---|
| 1 | Message limit 10000 team edition | 120 / 110 | kind/license | https://github.com/mattermost/mattermost/issues/34271 |
| 2 | Support dark mode and light mode syncing with OS theme setting | 72 / 72 | Area/End User Feature | https://github.com/mattermost/mattermost/issues/15975 |
| 3 | Matterbridge support | 40 / 28 | kind/feature | https://github.com/mattermost/mattermost/issues/30126 |
| 4 | Hide Upgrade Button added in 7.2.0 | 20 / 20 | kind/packaging | https://github.com/mattermost/mattermost/issues/20835 |
| 5 | Disable tracker to https://pdat.matterlytics.com/v1/track | 12 / 12 | kind/telemetry | https://github.com/mattermost/mattermost/issues/16241 |
| 6 | [Proposal] GraphQL in Mattermost | 10 / 6 | Proposal | https://github.com/mattermost/mattermost/issues/18272 |
| 7 | When will an official arm image be supported. | 10 / 10 | kind/feature | https://github.com/mattermost/mattermost/issues/33799 |
| 8 | New "free edition" label in header (introduced in v9.9) | 7 / 7 | kind/packaging | https://github.com/mattermost/mattermost/issues/28863 |
| 9 | Update emoji from Unicode 13.0 to 15.1 | 6 / 6 | kind/feature | https://github.com/mattermost/mattermost/issues/29437 |
| 10 | Account Setting for disabling GIF and emoji animation | 6 / 6 | Help Wanted | https://github.com/mattermost/mattermost/issues/17740 |
| 11 | mm on pi4(arm)? | 5 / 5 | kind/feature | https://github.com/mattermost/mattermost/issues/23387 |
| 12 | [Features] - Animated Profile Pictures / Avatar Videos | 5 / 0 | none | https://github.com/mattermost/mattermost/issues/35359 |
| 13 | Bitbucket plugin: Support for bitbucket Datacenter/server | 4 / 3 | Enhancement | https://github.com/mattermost/mattermost/issues/24188 |
| 14 | Bringing back SQLite? | 4 / 3 | kind/feature | https://github.com/mattermost/mattermost/issues/30846 |
| 15 | CPU usage of "Mattermost Helper" on Mac Desktop app spikes with animated GIFs in view on Mattermost | 4 / 4 | Help Wanted | https://github.com/mattermost/mattermost/issues/24689 |

The top issue is a licensing complaint, not a feature. A school with "over 2000 active users and 470000 posts" found that after an upgrade, "Messages sent before 26. September 2025 are hidden". A Mattermost collaborator replied: "If you're currently running Mattermost Entry, you can switch to Team Edition ... Team Edition does not include the 10k message visibility limit." Issues 4, 5 and 8 also object to upsell or telemetry. The two most-reacted bug reports, excluded above, are "frequent freezes on firefox" (39, https://github.com/mattermost/mattermost/issues/31018) and "Usage of easyjson library (from mail[dot]ru)" (21, https://github.com/mattermost/mattermost/issues/31193). For a new product, this is a signal that self-hosters react strongly to caps on their own data.
