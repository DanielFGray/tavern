# Tavern: what a security/procurement review would flag

Date: 2026-11-24. Repository state: `develop` at `c6a7909`. All evidence paths are relative to the repository root.

**Bottom line.** Tavern has strong application-layer controls: server-side authorization, role hierarchy, rate limits, SSRF guard, CSP with nonces, hashed tokens, and redacted telemetry. It has almost none of the evidence and identity features a buyer checks first. There is no licence, no SSO, no MFA, no security policy or disclosure process, no CI, no dependency or static scanning, no versioned or signed releases, and no audit of authentication events. The deploy path is also tied to the author's own platform (roamancer), and a self-hoster gets no install or backup guide.

---

## Part 1. The questionnaires

### CSA Cloud Controls Matrix (CCM) and CAIQ v4

- **CAIQ** (Consensus Assessments Initiative Questionnaire) is the questionnaire for the CCM. A provider answers Yes/No/NA per question, and can publish the answers in the CSA STAR Registry.
- **CCM/CAIQ v4.0**: released 2021-06-07, current artifact v4.0.13. https://cloudsecurityalliance.org/artifacts/consensus-assessments-initiative-questionnaire-caiq-v4-0 . The page shows a login/create-account prompt beside the download, so the spreadsheet probably needs a free CSA account. I did not download it.
- **CCM v4.1**: 207 controls in the same 17 domains. CAIQ v4.1 has 283 questions. Sources: https://cloudsecurityalliance.org/artifacts/ccm-v4-1 and https://cloudsecurityalliance.org/blog/2025/12/02/the-csa-cloud-controls-matrix-v4-1-strengthening-the-future-of-cloud-security
- v4 added the Logging and Monitoring (LOG) domain: https://cloudsecurityalliance.org/press-releases/2021/01/21/cloud-security-alliance-s-new-cloud-controls-matrix-v4-adds-new-log-and-monitoring-domain-and-more-than-60-new-cloud-security-controls/
- **Each CAIQ question has an "SSRM Control Ownership" column.** SSRM means Shared Security Responsibility Model. The column says whether the provider owns the control (CSP-Owned), the customer owns it (CSC-Owned), or both share it (Shared). Source: https://cloudsecurityalliance.org/artifacts/introductory-guidance-to-ccm

Domain codes and names come from CSA's own list: https://cloudsecurityalliance.org/blog/2023/02/01/a-checklist-for-csa-s-cloud-controls-matrix-v4/ . Control counts come from the Introductory Guidance page above. They add up to 207, so they are v4.1 counts.

| Code | Domain | Controls (v4.1) | Who owns it for a self-hosted app (my mapping) |
|---|---|---|---|
| A&A | Audit & Assurance | 6 | Customer; vendor supplies evidence |
| AIS | Application & Interface Security | 8 | **Product** |
| BCR | Business Continuity Management and Operational Resilience | 11 | Shared: customer runs it, product must support it |
| CCC | Change Control and Configuration Management | 9 | Shared: product release and migration discipline |
| CEK | Cryptography, Encryption & Key Management | 21 | Shared: product crypto and TLS support; customer keys and certificates |
| DCS | Datacenter Security | 18 | Customer |
| DSP | Data Security and Privacy Lifecycle Management | 19 | **Product** (retention, deletion, export features) |
| GRC | Governance, Risk Management and Compliance | 8 | Customer; vendor licence and security policy |
| HRS | Human Resources | 13 | Customer (vendor only if vendor staff touch data) |
| IAM | Identity and Access Management | 15 | **Product** |
| IPY | Interoperability and Portability | 4 | **Product** |
| IVS | Infrastructure and Virtualization Security | 9 | Customer |
| LOG | Logging and Monitoring | 14 | Shared: product emits; customer collects and keeps |
| SEF | Security Incident Management, E-Discovery, and Cloud Forensics | 10 | Shared: vendor advisories; customer incident response |
| STA | Supply Chain Management, Transparency and Accountability | 16 | **Product** (dependencies, SBOM, signed builds) |
| TVM | Threat and Vulnerability Management | 12 | **Product** (scanning, patching, disclosure) |
| UEM | Universal Endpoint Management | 14 | Customer |

Unresolved: the summary of the v4.1 Introductory Guidance page gave the infrastructure domain as "Infrastructure Security (I&S)". CSA's 2023 v4 list, and a 2025 CSA article (https://cloudsecurityalliance.org/blog/2025/06/27/implementing-ccm-infrastructure-security-controls), both use "Infrastructure & Virtualization Security (IVS)". I record IVS for v4.0. Check the v4.1 spreadsheet before you quote a v4.1 code.

### Shared Assessments SIG and SIG Lite

- The SIG (Standardized Information Gathering questionnaire) is licensed. SIG Lite is its short form: 128 questions in the 2025 edition, for vendors that need "basic levels of assessment due diligence". Source: Shared Assessments, "2025 SIG" post, https://sharedassessments.org/?p=71801
- SIG Lite draws its questions from the same risk domains as the full SIG. It has no separate domain list.
- sharedassessments.org blocked automated fetches with Cloudflare and a Microsoft Entra sign-in. Its "Guide To Risk Domains" (https://sharedassessments.org/?p=50105) could not be read.
- The domain list below comes from a public Shared Assessments PDF ("Accepting SIG", November 2023): https://sharedassessments.org/wp-content/uploads/sa-uploads/2024/09/Accepting-SIG-November-2023.pdf . It lists 21 domains. A secondary source (Mitratech, https://mitratech.com/resource-hub/blog/sig-2025-key-updates-and-considerations/) says SIG 2025 added no new domains.
- **No public domain codes were found.** The names below are as printed, including the PDF's typo "Suppy".

| SIG risk domain | Who owns it for a self-hosted app (my mapping) |
|---|---|
| Access Control | **Product** (app login, roles) and customer (host access) |
| Application Security | **Product** |
| Artificial Intelligence (AI) | Not applicable: Tavern has no AI features (bots are external programs) |
| Asset and Information Management | Shared: product retention, deletion and classification features |
| Cloud Hosting Services | Customer |
| Compliance Management | Customer |
| Cybersecurity Incident Management | Shared: vendor advisories |
| Endpoint Security | Customer |
| Enterprise Risk Management | Customer |
| Environmental, Social, Governance (ESG) | Customer |
| Human Resources Security | Customer |
| Information Assurance | Shared |
| IT Operations Management | Shared: product releases, migrations, rollback |
| Network Security | Customer (TLS termination, firewalling) |
| Nth Party Management | **Product**: third parties the app sends data to (Cloudflare, YouTube) |
| Operational Resilience | Shared: product HA and backup support |
| Physical and Environmental | Customer |
| Privacy Management | **Product** (erasure, export, minimisation) |
| Server Security | Customer |
| Suppy [sic] Chain Risk Management (SCRM) | **Product** (dependencies, licences, SBOM) |
| Threat Management | **Product** (vulnerability management and disclosure) |

### The product-control split

For self-hosted software the customer runs the hardware, network, OS, database, backups and staff. That covers CCM DCS, IVS, UEM, HRS and most of A&A/GRC, and SIG Cloud Hosting, Endpoint, Network, Physical, Server, HR, ESG, ERM and Compliance. What is left for the software is the **product controls**:

- **Product-owned:** CCM AIS, IAM, DSP, IPY, TVM, STA. SIG Application Security, Access Control, Privacy Management, Threat Management, SCRM and Nth Party.
- **Shared, where the product must give the customer the means:** CCM LOG (emit and export), CEK (TLS to every store, hashing), BCR (HA, backup and restore support), CCC (versioned releases, reversible migrations), SEF (advisories). SIG Operational Resilience, IT Operations, Incident Management, Asset and Information Management.

This split is my mapping. It is not CSA or Shared Assessments text.

---

## Part 2. Tavern's answers to the product-control questions

Answers describe **the software a buyer receives**. The author's own deployment platform (roamancer: Traefik TLS, OpenBao secrets, nightly restic backups, `ops promote`) is not part of the product. Where a doc describes it, the row says "author's platform".

| # | Domain | Question | Answer | Evidence |
|---|---|---|---|---|
| 1 | IAM | SSO with SAML 2.0? | no | `rg -i "saml\|oidc\|oauth\|openid\|ldap\|scim" lib config mix.exs`: no hits. Login is email+password only (`lib/tavern_web/controllers/user_session_controller.ex:10-42`) |
| 2 | IAM | SSO with OIDC / OAuth 2.0? | no | Same search; no OIDC/OAuth dependency in `mix.exs:52-90` |
| 3 | IAM | Multi-factor authentication (TOTP, WebAuthn/passkeys)? | no | `rg -i "totp\|webauthn\|passkey\|two.factor\|2fa\|mfa" lib config assets/js`: only the logger `:mfa` key |
| 4 | IAM | Automated provisioning/deprovisioning (SCIM, directory sync)? | no | Same search; accounts come only from self-registration (`lib/tavern_web/router.ex:93`) |
| 5 | IAM | Enforced password policy and strong hashing? | partial | Length 12 to 72 bytes only (`lib/tavern/chat/user.ex:150-154`), bcrypt (`mix.exs:76`). No breached-password check, no complexity rule |
| 6 | IAM | Brute-force / credential-stuffing protection? | yes | 20 attempts per IP and 5 per IP+email per 5 min (`lib/tavern/accounts/login_rate_limiter.ex:1-19`), checked before the password (`lib/tavern_web/controllers/user_session_controller.ex:16`); `docs/design/rate-limits.md` |
| 7 | IAM | Session timeout (idle and absolute)? | partial | Absolute 30 days (`lib/tavern/accounts.ex:33`, `:774`); remember-me cookie 30 days (`lib/tavern_web/user_auth.ex:12-18`). No idle timeout: `last_seen_at` is stamped (`lib/tavern/accounts.ex:1056`) but never checked at lookup (`lib/tavern/accounts.ex:147-157`). Not configurable |
| 8 | IAM | Sessions revoked on password reset and on removal? | yes | `Accounts.revoke_user_sessions/1` (`lib/tavern/accounts.ex:818`), called after reset (`:730`) and after kick/ban (`lib/tavern/chat/moderation.ex:354`); `docs/design/accounts.md` "Password reset" |
| 9 | IAM | Can a user list and revoke their own active sessions? | no | Settings tabs (`lib/tavern_web/live/settings_live.ex:17-29`) have no sessions tab; no list-sessions function in `lib/tavern/accounts.ex` |
| 10 | IAM | Signed-in password change? | no | `docs/design/accounts.md:219` ("The app has no signed-in password change yet") |
| 11 | IAM | Role-based access control with custom roles? | yes | `docs/design/roles.md`; `lib/tavern/chat/roles.ex`; permission bits in `lib/tavern/chat/permission_bits.ex`; channel overwrites |
| 12 | IAM | Least privilege for admins: no self-escalation, separation of owner and admin? | yes | Four-part authority rule; only the owner grants `administrator` (`docs/design/roles.md:41-50`); escalation via roles and bots closed (`docs/design/roles.md:72`) |
| 13 | IAM | Deprovisioning: removal ends access at once, API tokens revocable? | yes | Kick/ban ends sessions and sockets (`lib/tavern/chat/moderation.ex:347-354`); bot revoke and token revoke (`lib/tavern/bots.ex:215`, `:285`). Manual per user, not tied to a directory |
| 14 | IAM | API credentials hashed at rest, revocable, expirable? | yes | Bot tokens stored as SHA-256 hash (`lib/tavern/chat/bot_token.ex:9`, `lib/tavern/accounts.ex:912`), checked for `revoked_at` and `expires_at` (`lib/tavern/bots.ex:305-317`) |
| 15 | IAM | Account enumeration resistance? | partial | Login error is generic (`user_session_controller.ex:29`); reset reply is the same for every email (`docs/design/accounts.md:194`). Registration's unique-email error (`lib/tavern/chat/user.ex:65`) reveals that an address is registered |
| 16 | IAM | Admin control of who can join (invite only, approval)? | yes | `registration_mode` `:open`/`:invite_only` (`lib/tavern/chat/server_settings.ex:11`); invite requests (`docs/design/invite-requests.md`) |
| 17 | LOG | Audit log of admin/moderator actions? | partial | Recorded: moderation, roles, overwrites, bots, tokens, deletions, invite requests (`lib/tavern/chat/audit_log_line.ex:15-21`). Not recorded: ownership transfer (`lib/tavern/accounts.ex:919`), server settings (`lib/tavern/chat/server_config.ex:38`), invite create/revoke (`lib/tavern/chat/invites.ex:35`, `:121`), channel delete (`lib/tavern/chat/channels.ex:192`), moderator message delete (`lib/tavern/chat/messages.ex:278`); none of these call `AuditLog.record!` |
| 18 | LOG | Audit log of authentication events (login success and failure, logout, reset)? | no | No auth action types in `lib/tavern/chat/audit_log_line.ex:15-21`; a failed login only flashes (`user_session_controller.ex:26-30`). Only a pseudonymous `session.seen` product event exists (`docs/design/observability.md`) |
| 19 | LOG | In-app audit log viewer with filters, gated by permission? | yes | `lib/tavern/chat/audit_log.ex:18-46` (actor, action, date filters; `view_audit_log`); Settings "audit" tab |
| 20 | LOG | Export logs to the customer's SIEM? | partial | Application logs and traces go over OTLP to any `OTEL_EXPORTER_OTLP_ENDPOINT` (`config/runtime.exs:107`, `docs/design/observability.md` "When it exports"). The audit trail is not exported: `AuditLog.record!` emits nothing (`docs/design/observability.md`, "Product events"), and there is no audit export or API |
| 21 | LOG | Tamper evidence / immutability of the audit log? | no | Plain table (`lib/tavern/chat/audit_log_entry.ex`); the runtime role has DELETE and UPDATE on every table (`priv/repo/migrations/20261108031103_grant_visitor_role.exs:16`); no hash chain or signing. `docs/design/event-log.md` is a proposed design and is not built (`lib/tavern/events` does not exist) |
| 22 | LOG | Logs free of secrets and PII? | yes | `Tavern.Observability.Redaction` removes paths, queries, IPs, DB URL and exception text (`docs/design/observability.md`, "Traces" and "Logs"); members are pseudonymised by HMAC |
| 23 | LOG | Configurable audit/log retention? | no | No retention or prune code for audit entries (`rg -i "retention\|purge\|prune" lib` finds only voice presence pruning) |
| 24 | CEK | Encryption in transit to clients and to every backing store? | partial | The app serves plain HTTP and expects a TLS proxy (`config/prod.exs:12`); secure cookies in prod (`config/prod.exs:10`); no `force_ssl`/HSTS. Postgres TLS is commented out (`config/runtime.exs:52`); Valkey defaults to `redis://` (`config/runtime.exs:25`), though Redix accepts a `rediss://` URL (`lib/tavern/valkey.ex:11`). No doc tells a self-hoster how to set any of this |
| 25 | CEK | Encryption at rest? | no | No app-level encryption: messages, emails and profiles are plaintext columns. The customer must supply disk/DB encryption. Passwords (bcrypt) and tokens (SHA-256, `lib/tavern/accounts.ex:912`) are hashed |
| 26 | CEK | Secrets supplied at runtime, none in the repo? | yes | `SECRET_KEY_BASE`, S3 and mail keys read from env (`config/runtime.exs:64`, `:84`, `:114`); `.env` ignored (`.gitignore:42`). The session/LiveView signing salts in `lib/tavern_web/endpoint.ex:10` and `config/config.exs:47` are Phoenix's non-secret defaults |
| 27 | DSP | Configurable data retention (messages, files)? | no | No retention setting or job in `lib/`; messages and uploads stay until someone deletes them |
| 28 | DSP | Right to erasure (GDPR Art. 17)? | partial | `Accounts.delete_account/2` wipes email, name, password and avatars (`lib/tavern/accounts.ex:851`; `docs/design/accounts.md:33-63`). A member cannot request it: the only callers are the moderator kick-and-schedule path (`lib/tavern/chat/moderation.ex:100`, 30-day delay) and the sweeper. Messages stay, as "Deleted user". The prune named in `docs/design/accounts.md:7` has no caller in `lib/` |
| 29 | DSP | Data portability: a user can export their own data (GDPR Art. 20)? | no | `rg -i "export\|takeout\|portab" lib` finds no data-export feature; no Settings tab for it (`lib/tavern_web/live/settings_live.ex:17-29`) |
| 30 | IPY | Admin bulk export of server data in an open format? | partial | No export tool. A bot can page messages per channel over the JSON API (`lib/tavern_web/router.ex:134`; `docs/design/bot-api.md`). Otherwise `pg_dump` by the customer |
| 31 | DSP | Data classification or labelling? | no | No classification fields or labels in the schemas (`lib/tavern/chat/*.ex`) |
| 32 | DSP | Data minimisation in telemetry? | yes | Product events carry no text, email, username, IP or invite code; members appear only as an HMAC pseudonym (`docs/design/observability.md`, "Privacy") |
| 33 | DSP | Third parties that receive data are disclosed and optional? | partial | Optional and off when unset: Cloudflare Email (`config/runtime.exs:111-117`), Cloudflare Realtime SFU/TURN for voice (`config/runtime.exs:133-142`), YouTube no-cookie player after a click (`lib/tavern_web/plugs/content_security_policy.ex:36`), OTLP export. Cloudflare is the only mail provider (`lib/tavern/mailer.ex:61-62`). No subprocessor list |
| 34 | AIS | Server-side authorization on every operation? | yes | Every domain operation takes a `%Scope{}` and decides in its transaction; a hidden row reads as missing (`docs/design/scoped-reads.md`, "Rule") |
| 35 | AIS | CSRF and WebSocket origin protection? | yes | `protect_from_forgery` (`lib/tavern_web/router.ex:9`); `check_origin` defaults to true in prod (`config/runtime.exs:119`) |
| 36 | AIS | CSP and security headers? | partial | Phoenix secure headers (`lib/tavern_web/router.ex:10`); CSP with per-request script nonce, `img-src 'self' data:`, `frame-ancestors 'self'` (`lib/tavern_web/plugs/content_security_policy.ex:35-38`). No `default-src`, `object-src` or `connect-src`; no HSTS |
| 37 | AIS | Rate limiting on abusable endpoints? | yes | Messages, login, email links, invite requests, bot edits (`docs/design/rate-limits.md`, "The limits") |
| 38 | AIS | Input validation and XSS-safe rendering? | yes | Message body 1..4000 (`lib/tavern/chat/message.ex:49`); Markdown sanitised with DOMPurify (`assets/js/chat_hooks.js:40`); HEEx escapes by default |
| 39 | AIS | Upload validation and malware scanning? | partial | Type from magic bytes, images only (`lib/tavern/chat/media_assets.ex:43-51`, `:104-109`); size caps 0.5 to 2 MB (`lib/tavern_web/live/settings_live.ex:40-53`); served with `nosniff` and a sandbox CSP (`lib/tavern_web/controllers/upload_controller.ex:13-24`). No malware scan. `/uploads` is public with no auth; keys are random UUIDs (`lib/tavern_web/router.ex:46`) |
| 40 | AIS | SSRF protection on server-side fetches? | yes | Link-embed fetcher refuses private, loopback, link-local, CGNAT and reserved addresses, and pins the resolved address (`lib/tavern/embeds/safe_http.ex:1-12`, `:122-128`) |
| 41 | AIS | Automated tests? | yes | 106 ExUnit files under `test/`, 29 Playwright files under `tests/`; `mix precommit` runs them (`mix.exs:111`) |
| 42 | AIS | CI on every change, with results a buyer can see? | no | No `.github/`, `.gitlab-ci.yml`, `.forgejo/` or other CI config. The gate is local: `mix precommit` and `scripts/verify` via the author's `ops signoff` (`scripts/verify:1-9`) |
| 43 | TVM | Static analysis (SAST)? | no | No Sobelow or Credo in `mix.exs:52-90`; `scripts/verify` runs compile and format only |
| 44 | TVM | Dependency vulnerability scanning? | no | No `mix_audit`, `mix hex.audit` step, Dependabot or Renovate config; no `npm audit` step |
| 45 | TVM | Independent security review or pen-test report? | partial | The docs record an internal security review and its fixes (`docs/design/roles.md:72`; `docs/design/scoped-reads.md`, "Why"). No report is published |
| 46 | TVM | Vulnerability disclosure policy (SECURITY.md)? | no | `git ls-files \| rg -i security` finds only the CSP plug and its tests; no SECURITY.md, no contact |
| 47 | SEF | Security advisories / CVE process? | no | No advisories, no changelog, no security contact in the repo |
| 48 | CCC | Versioned releases with changelog? | no | `version: "0.1.0"` (`mix.exs:7`); no git tags (`git tag` is empty); no CHANGELOG; "A push to main is the only release" (`README.md`, "Deploy") |
| 49 | CCC | Reversible migrations / rollback tooling? | partial | `Tavern.Release` has `migrate` and `make_owner` only (`lib/tavern/release.ex:8`, `:16`); few migrations have a `down` (`docs/design/backups.md:100-101`) |
| 50 | STA | Signed releases or images? | no | No signing step in `Dockerfile` or `scripts/`; no published image |
| 51 | STA | SBOM? | no | No CycloneDX/SPDX tool or output in the repo |
| 52 | STA | Dependencies pinned? | partial | `mix.lock` and `assets/package-lock.json` are tracked, and the image uses `npm ci` (`Dockerfile:15`). Base images are pinned by tag, not digest (`Dockerfile:3-9`); heroicons comes from a GitHub tag (`mix.exs:65-71`) |
| 53 | STA | Dependency licences compatible with commercial use? | yes | All 63 Hex packages in `deps/*/hex_metadata.config` are Apache-2.0, MIT or BSD. JS: DOMPurify `MPL-2.0 OR Apache-2.0`, highlight.js BSD-3-Clause, markdown-it, tiptap and emoji-mart MIT |
| 54 | GRC | Product licence? | no | No LICENSE file (`git ls-files \| rg -i license`: none); no `licenses` key in `mix.exs`. With no licence, nobody else has the right to use the code |
| 55 | STA | Container runs as non-root, minimal image? | partial | Slim Debian runtime (`Dockerfile:57-61`), but no `USER` line: root in the container, which relies on the author's rootless Podman (`Dockerfile:76-77`) |
| 56 | BCR | High availability / horizontal scaling? | partial | DNSCluster for multi-node (`lib/tavern/application.ex:19`); rate limits shared in Valkey; the deletion sweep is safe on two nodes (`docs/design/accounts.md`, "The sweep"). No documented HA deployment |
| 57 | BCR | Backup and restore support for the self-hoster? | partial | Tavern ships no backup tooling. `docs/design/backups.md` documents the author's platform's nightly `pg_dumpall` and restic, plus a dev restore drill. It names what holds state (Postgres and bucket required; Valkey none), which a self-hoster can reuse |
| 58 | BCR | Health-check endpoint? | yes | `GET /healthz` (`lib/tavern_web/router.ex:43`) |
| 59 | IPY | Documented self-host install for a third party? | no | `README.md` covers a dev checkout and the author's `ops`/`cartridge.json` deploy only; `docker-compose.yml` starts only the dev S3 store |
| 60 | IPY | Documented API for integration? | yes | Bot REST API and SSE event stream (`lib/tavern_web/router.ex:117-152`; `docs/design/bot-api.md`) |

Counts: **yes 20, partial 17, no 23** (60 questions).

---

## Every `no` and `partial`, by domain

### IAM
- no: SAML SSO (1); OIDC SSO (2); MFA (3); SCIM provisioning (4); user can list/revoke own sessions (9); signed-in password change (10).
- partial: password policy is length-only, no breach check (5); 30-day absolute session, no idle timeout, not configurable (7); registration reveals registered emails (15).

### LOG
- no: auth events not audited (18); no tamper evidence, runtime role can delete audit rows (21); no audit retention setting (23).
- partial: ownership transfer, settings, invites, channel and message deletes not audited (17); logs export over OTLP, audit trail does not (20).

### CEK
- no: no encryption at rest at the app level (25).
- partial: plain HTTP behind a proxy, no HSTS, Postgres TLS commented out, Valkey `redis://` default, undocumented (24).

### DSP
- no: no retention policy (27); no user data export (29); no data classification (31).
- partial: erasure exists but no member can request it; messages kept (28); third parties optional but not listed as subprocessors (33).

### IPY
- no: no self-host install guide (59).
- partial: admin bulk export only through the bot API or `pg_dump` (30).

### AIS
- no: no CI (42).
- partial: CSP lacks `default-src`/`object-src`/`connect-src`, no HSTS (36); uploads not malware-scanned and served without auth (39).

### TVM
- no: no SAST (43); no dependency vulnerability scanning (44); no SECURITY.md or disclosure contact (46).
- partial: internal security review recorded, no report (45).

### SEF
- no: no advisory/CVE process (47).

### CCC
- no: no versioned releases or changelog (48).
- partial: no rollback tooling, few reversible migrations (49).

### STA
- no: unsigned builds (50); no SBOM (51).
- partial: base images pinned by tag, not digest (52); container runs as root (55).

### GRC
- no: no licence (54).

### BCR
- partial: multi-node capable but no documented HA (56); backups documented only for the author's platform (57).

Totals in this list: no 23, partial 17, which matches the table.

---

## Buyer blockers

These `no` answers usually end a procurement review or need a written exception:

1. No licence: the buyer has no legal right to run the code (54).
2. No SSO (SAML or OIDC): most enterprise reviews require it (1, 2).
3. No MFA (3).
4. No vulnerability disclosure policy or security contact (46), and no advisory process (47).
5. No versioned releases (48), so there is nothing to pin, patch against, or roll back to.
6. No audit of authentication events (18), and the audit log can be edited by the app's own database role (21).
7. No dependency scanning (44) or SAST (43), and no CI evidence (42).
8. No self-host install guide (59): the only deploy path is the author's private platform.
9. No user data export (29) and no configurable retention (27). These are GDPR blockers for EU buyers, together with the partial erasure in row 28.
