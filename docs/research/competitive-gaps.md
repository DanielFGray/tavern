# What stops groups from choosing Tavern

Desk research, 2026-11-24. The question: what stops a small hobby group (the Discord job) or a company
of hundreds to thousands of people (the Slack and Teams job) from choosing Tavern as a self-hosted
alternative. The load test and the timed fresh install were deferred; see "Not yet checked".

Source notes, each with its own citations:

- `competitive-gaps-inventory.md`: Tavern today, read from the code (91 capability rows).
- `competitive-gaps-saas.md`: Slack, Teams and Discord, by plan tier.
- `competitive-gaps-selfhosted.md`: Mattermost, Zulip, Rocket.Chat and Element, with what each sells
  only in a paid edition.
- `competitive-gaps-procurement.md`: the CSA CAIQ v4 and Shared Assessments SIG questions a
  security review asks, answered for Tavern.

Row ids such as `MSG3` refer to the inventory table.

## Bottom line

1. **Two blockers stop both segments before any feature counts.**
   - **No licence.** The repo has no LICENSE file, so nobody else may legally run it (OPS8).
   - **No install path but the author's own.** Deploys go through the author's private platform.
     Mail works only through the Cloudflare Email API, and voice only through Cloudflare Realtime
     (OPS1, CMP11, AV6).
2. **Both segments then hit the same four gaps in the core chat:**
   - no mobile app and no push notifications (CL3–CL6);
   - no direct messages (MSG3, MSG4);
   - no file uploads in messages (MSG12);
   - no search over message text (MSG15).

   Every competitor surveyed has all four. Users treat them as basic parts of chat, so a missing
   one rules a product out; having them earns no credit.
3. **Companies have a further gate:** single sign-on (SSO), multi-factor authentication (MFA),
   automatic deprovisioning, retention and export, high availability, and a visible security
   process. Each competitor except Zulip charges for most of these. That shows companies pay for
   them.
4. **Recommendation: build the shared core first.** The hobby segment's dealbreakers are a subset
   of the company segment's. Close the licence, install, mobile/push, DM, upload and search gaps
   first; they serve both. Then add OIDC sign-in and MFA, which are cheap and unlock small
   companies. Leave SCIM, legal hold and clustering until a real company asks.

## Terms

- **Dealbreaker:** a missing capability that stops a group from adopting at all.
- **Kano classes:** a way to rank features by how users react to them.
  - **must-have:** expected; its absence rules the product out, its presence earns nothing.
  - **performance:** the more of it, the better.
  - **delighter:** unexpected, so it wins favour.
- **SSO:** single sign-on, one company login for every app.
- **OIDC and SAML:** the two common SSO protocols.
- **SCIM:** a standard that lets a company's directory create and remove accounts in each app on its
  own.
- **Push relay:** a vendor server that forwards notifications to Apple's (APNs) and Google's (FCM)
  push services.

## Where the two segments conflict

1. **Who owns an account.**
   - A Discord user owns one global account that joins many servers (`competitive-gaps-saas.md`,
     "Discord identity model").
   - A company owns its staff accounts through its identity provider.
   - Tavern today follows the company model. A deployment is one server, and it holds every account
     on it (ID8, ID12, "Architecture facts").
   - So a hobbyist in five Tavern communities needs five accounts. That friction is real, but a
     preference rather than a dealbreaker: Discord users join new servers often, but they can live
     with separate logins.
   - The proposed user@server federation (`docs/research/federation.md`) can serve both. The home
     server owns the identity: for a company that is its own deployment, and a hobbyist picks one.
     Matrix uses this model. Build it after the shared core.
2. **Delete versus keep.**
   - Hobby groups and EU privacy law want people's data deleted.
   - Companies want retention and legal hold, which keep it.
   - Neither blocks the other when retention, hold and deletion are settings of each deployment, as
     Zulip, Rocket.Chat and Mattermost do it (CMP2–CMP4 in `competitive-gaps-selfhosted.md`).
3. **What to charge for.**
   - Mattermost, Rocket.Chat and Element hold back clustering, compliance tools and directory sync
     for paid editions. Zulip's self-hosted server holds back nothing (Apache-2.0) and charges only
     for push above 10 users, plus support.
   - Free-tier caps cause the most anger. The most-reacted open Mattermost issue is the free Entry
     tier's 10,000-message history cap (120 reactions). Rocket.Chat Community stops at 100
     concurrent users (`competitive-gaps-selfhosted.md`, "Summary").
   - The licence choice in Bottom line item 1 decides which segment trusts Tavern. Zulip's model
     keeps hobby groups and charges companies only for services.
4. **Mobile push needs someone to run a relay.**
   - Apple and Google accept a push only from whoever holds the keys built into the store app. So a
     self-hosted server reaches phones only through the app vendor's relay.
   - All four self-hosted competitors run one, and each charges for it or caps it. Zulip is free up
     to 10 users, then $3.50 per user per month. Rocket.Chat Community gets 10,000 pushes a month.
     Mattermost's production relay needs a paid licence (`competitive-gaps-selfhosted.md`, "Mobile
     push from a self-hosted server").
   - Tavern must choose one of three routes:
     - run and pay for a relay;
     - send Web Push from an installable web app (PWA);
     - support UnifiedPush, which Element X uses on Android.
   - Whether Web Push reaches iOS reliably enough is **unverified** in these sources. Check it before
     choosing the PWA route.

## Ranked dealbreakers: hobby groups (Discord job)

| rank | gap | Tavern | what the alternatives do |
|---|---|---|---|
| 1 | Licence | none (OPS8) | Zulip Apache-2.0; Mattermost AGPL/MIT; Rocket.Chat MIT; Element AGPL |
| 2 | Install a hobby admin can do | private platform only; no app compose file; Cloudflare-only mail and voice (OPS1, CMP11, AV6) | Zulip: installer, Docker Compose, Helm; Mattermost: APT packages and tarball (inventory OPS1 in `competitive-gaps-selfhosted.md`) |
| 3 | Phone access and push | no native app, no PWA, no push; the "Push alerts" setting sends nothing (CL3–CL6) | every competitor has iOS and Android apps with push |
| 4 | Direct and group messages | none (MSG3, MSG4) | all have them free |
| 5 | Images and files in messages | link previews only (MSG12) | all have them free; Discord free allows 20 MB |
| 6 | Message search | thread and forum titles only (MSG15) | all have it; Discord supports from:, in:, has: and dates |
| 7 | Reports and automod | schema only, planned (MOD2, MOD4) | Discord has both free |

**Tavern is already level with Discord, or close, on:**
- voice channels with video and screen share (AV1, AV3);
- threads and forums (MSG5, MSG6);
- roles with per-channel overrides (ID10, ID11);
- polls (MSG11) and a bot API (INT1);
- invite links with use limits, an invite tree and invite requests (MOD6);
- numbered moderation cases (MOD8).

**Preferences, not blockers:** onboarding and rules screen (MOD7), events (COM2), stickers, GIFs and
soundboard (COM5), custom status (MSG19), and one account across servers (ID8).

**A Discord importer is not a differentiator.** None of the six products has one. Discord gives
admins no server export, and its Developer Policy forbids scraping (`competitive-gaps-saas.md`,
"Data export limits a community admin hits").

**Timing.** Discord now gives unconfirmed users teen limits, and adults confirm their age through a
vendor. A support-vendor breach (notice 2025-10-03) may have exposed about 70,000 ID images
(`competitive-gaps-saas.md`, "Age assurance"). Communities that want to leave over this need the
first six rows closed.

## Ranked dealbreakers: companies (Slack and Teams job)

| rank | gap | Tavern | what the alternatives do |
|---|---|---|---|
| 1 | Licence a legal team can approve | none (OPS8) | as above |
| 2 | SSO: OIDC, then SAML | email and password only (ID2, ID3) | Slack SAML on Business+; Mattermost on paid and Entry; Zulip self-hosted free; Element OIDC free |
| 3 | MFA | none (ID6) | Slack, Teams and Discord all have it; Mattermost and Rocket.Chat TOTP |
| 4 | Same core gaps: mobile and push, DMs, uploads, search | see hobby rows 3–6 | — |
| 5 | Deprovisioning and account control | no SCIM or LDAP; admins can only kick or ban, with no deactivate or password reset (ID4, ID5, ID9) | Slack SCIM on Business+; Zulip SCIM free self-hosted; Mattermost has LDAP sync but no SCIM |
| 6 | A security process a reviewer can see | no SECURITY.md, no advisories, no versioned releases, no CI in the repo, no dependency scanning (`competitive-gaps-procurement.md` rows 42–48) | not compared in these notes; the gap is the reviewer's question, whatever competitors do |
| 7 | Retention, export, legal hold | none (CMP2–CMP5); logins and failed logins are not audited, and the app can edit its own audit rows (procurement rows 18, 21) | Slack legal hold and eDiscovery on Enterprise; Mattermost on Enterprise; Zulip retention and compliance export free |
| 8 | Scale and high availability for thousands | runs as one node; k6 scripts are broken and no results are recorded (OPS2, OPS3) | Mattermost publishes reference architectures up to 200,000 concurrent users; Rocket.Chat "above 5,000" |
| 9 | Move from Slack | no importer (MIG1) | Mattermost, Zulip and Rocket.Chat import Slack exports; Slack puts private channels and DMs in exports only on Business+ and Enterprise |
| 10 | Meetings and calls | voice channels hold 25 people at most; no ad hoc calls (AV2, AV4) | Slack huddles; Teams meetings and webinars |

**Preferences, not blockers:** guest accounts (ID7), several teams in one deployment (ID12), shared
channels with other companies (MIG5), webhooks and ready-made integrations (INT2, INT5), and
localisation (MSG20).

Companies in regulated fields will also ask where voice and video media goes. Today it passes
through Cloudflare, so an air-gapped install loses voice (AV6, CMP11).

## Order of work

The ranks above say what blocks adoption. The order below also counts what each gap unblocks, so
they differ:

1. Licence, and a self-host install path: a compose file, SMTP mail, and voice optional.
2. File uploads, DMs, message search: the work is planned in existing tasks.
3. Mobile: an installable PWA with Web Push first. Decide on a push relay once the iOS question is
   answered.
4. OIDC sign-in, then TOTP MFA, then admin account controls (deactivate, reset).
5. A security process: SECURITY.md, tagged releases, CI with dependency audit, and auth events in
   the audit log.
6. Retention and export, Slack import, then SCIM, legal hold and multi-node, when a company asks.

## Not yet checked

- **Load test.** Not run: the k6 scripts cannot log in, and the target hardware is undecided.
- **Fresh install time.** Not measured: there is no generic install path to time yet.
- **Real admins.** The check that would prove this list right has not run. Show it to two
  hobby-community admins and two company IT admins, and ask what would stop them from switching.
  The list passes if each dealbreaker they name is already near the top. It fails if they name one
  that is missing.
- **Source caveats.**
  - The SIG domain list comes from a 2023 public PDF, because the SIG Lite question set is paid.
  - A few competitor cells are marked "unverified" or "CONFLICT" in their source notes.
  - Web Push reliability on iOS is unverified.
