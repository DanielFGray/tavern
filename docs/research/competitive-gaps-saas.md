# SaaS chat capability survey: Slack, Microsoft Teams, Discord

**Sources accessed:** 2026-11-24.

**Source rules:**
- Primary sources only: vendor help centres, pricing and licensing pages, developer docs, and vendor blogs and press pages.
- "unverified" means this pass found no primary source for the fact.
- "unverified (absence)" means no vendor page offers the feature, but no vendor page says it is missing either.

**Columns:** offered is yes / partial / no / n.a. (n.a. = not applicable to a SaaS product).

**How a source was read:**
- **(x):** I saw only a search-engine extract of the official page.
- **F:** fetched in full (Discord table only).
- **X:** extract only (Discord table only).
- support.discord.com refuses automated fetches (HTTP 403).
- For Teams, the www.microsoft.com pricing pages could not be fetched. Prices marked "(snippet)" come from search-result text.

## Slack

**Plan names:** Slack sells Free, Pro, Business+ and Enterprise+. Help pages call the org-level tier "Enterprise" (formerly Enterprise Grid). "Enterprise" below means Enterprise / Enterprise+.

| id | offered | plan tier | note | source |
|---|---|---|---|---|
| ID1 | yes | all | Email code or passkey; password sign-in documented only for Frontline Members. | [s-signin] |
| ID2 | partial | all | "Continue with Google/Apple"; customer OIDC IdP unverified. | [s-signin] |
| ID3 | yes | Business+, Enterprise | Free/Pro only with a connected Salesforce org; Multi-SAML on Enterprise+. | [s-saml], [s-plans] |
| ID4 | unverified | — | No LDAP in the SAML/SCIM docs; sync goes through the IdP plus SCIM. | [s-saml] |
| ID5 | yes | Business+, Enterprise | Free/Pro only with a connected Salesforce org. | [s-scim] |
| ID6 | yes | all | TOTP or SMS; no U2F keys; passkey sign-in; admins can mandate 2FA. | [s-2fa], [s-mand2fa](x) |
| ID7 | yes | paid | Single- and multi-channel guests; none on Free. | [s-guests] |
| ID8 | partial | all | One email signs in to many workspaces; each account is org-controlled. | [s-signin] |
| ID9 | yes | all | Admins and owners deactivate; Primary Owner deletes profiles. | [s-deact], [s-delprofile](x) |
| ID10 | yes | all; custom roles Enterprise+ | Primary Owner/Owner/Admin/member/guest; system and custom roles on Enterprise. | [s-deact], [s-plans] |
| ID11 | yes | all | Private channels; posting permissions; Channel Managers on paid plans. | [s-posting](x) |
| ID12 | yes | Enterprise | One org dashboard applies settings to every workspace. | [s-orgadmin] |
| ID13 | yes | all; org dashboard Enterprise | Web admin pages; org-level dashboard on Enterprise. | [s-orgadmin] |
| ID14 | yes | all; Atlas add-on Business+ | Custom profile fields "Available on all plans". | [s-profile] |
| MSG1 | yes | all | `channels.json` in export. | [s-export-fmt] |
| MSG2 | yes | all | `groups.json` in full export. | [s-export-fmt] |
| MSG3 | yes | all | `dms.json`. | [s-export-fmt] |
| MSG4 | yes | all | `mpims.json`. | [s-export-fmt] |
| MSG5 | yes | all | Threads. | unverified |
| MSG6 | partial | all | Canvases and lists, not forum posts. | [s-plans] |
| MSG7 | yes | all | Reactions in the export format. | [s-export-fmt] |
| MSG8 | yes | all; user groups paid | User groups on Pro and up. | [s-plans] |
| MSG9 | yes | all | Export records edits and deletes as subtypes. | [s-export-fmt] |
| MSG10 | yes | all | `pinned_to`, `is_starred` in the export. | [s-export-fmt] |
| MSG11 | partial | all | No built-in poll; emoji polls or Marketplace apps. | [s-poll] |
| MSG12 | yes | all | Free: files visible 90 days. | [s-limits] |
| MSG13 | unverified | — | | — |
| MSG14 | yes | all | mrkdwn in messages and Block Kit. | [s-webhooks] |
| MSG15 | yes | all; Free 90 days | from:, in:, before:/after:/on:/during:. | [s-search](x), [s-limits] |
| MSG16 | yes | all | Mark unread. | [s-reminder](x) |
| MSG17 | unverified | — | | — |
| MSG18 | yes | all | Scheduled send; /remind and personal reminders. | [s-reminder](x) |
| MSG19 | unverified | — | Status scheduling mentioned only in a changelog extract. | — |
| MSG20 | partial | AI translation: plan unclear | "Translate message" AI feature. | [s-ai](x) |
| AV1 | no | — | Huddles are ad hoc. | [s-huddles] |
| AV2 | yes | Free 2 people; paid 50 | | [s-huddles] |
| AV3 | yes | paid | 25 cameras; 2 screen sharers at once. | [s-huddles] |
| AV4 | no | — | 50-person cap; no webinar mode found. | [s-huddles] |
| AV5 | partial | paid | Clips with transcripts; huddles have live English captions only. | [s-clips](x), [s-huddles] |
| AV6 | n.a. | — | SaaS. | — |
| CL1 | yes | all | Web app. | unverified |
| CL2 | yes | all | Mac, Windows, Linux. | [s-downloads] |
| CL3 | yes | all | | [s-downloads] |
| CL4 | yes | all | | [s-downloads] |
| CL5 | yes / n.a. | all | Push run by the vendor; self-host relay question n.a. | unverified |
| CL6 | unverified | — | | — |
| CL7 | yes | all | NVDA, JAWS, VoiceOver, TalkBack; no VPAT found. | [s-a11y](x) |
| INT1 | yes | all | Web API, Events API, Socket Mode. | [s-socket](x) |
| INT2 | partial | all | Incoming webhooks; outgoing webhooks are legacy. | [s-webhooks], [s-outgoing](x) |
| INT3 | yes | all | Slash commands with trigger_id and response_url. | [s-slash](x) |
| INT4 | yes | Free capped at 10 apps | Marketplace; unlimited apps on paid plans. | [s-limits], [s-pricing] |
| INT5 | yes | all | Marketplace apps. | [s-pricing] |
| INT6 | yes | all | Slack defines the format. | [s-webhooks] |
| INT7 | yes | all | Block Kit buttons, modals, view_submission. | [s-modals](x) |
| CMP1 | yes | Enterprise | Audit Logs API; logs kept up to 2 years. | [s-audit] |
| CMP2 | yes | Free: 90 days or 1 year; custom on paid | Admin per-channel overrides on Business+ and Enterprise. | [s-retention] |
| CMP3 | yes | Enterprise | Keeps edits and deletes; excludes Slack Connect. | [s-legalhold] |
| CMP4 | yes | Enterprise | Discovery API; partners include Smarsh and Global Relay. | [s-discovery] |
| CMP5 | partial | admin: by plan (see export); user: none | No member self-export; requests go to the Primary Owner. | [s-export], [s-datamgmt](x) |
| CMP6 | partial | all | Primary Owner deletes profiles; messages remain. | [s-delprofile](x), [s-deact] |
| CMP7 | yes | Enterprise | Native DLP on text, files and canvases; partner DLP through the API. | [s-dlp], [s-discovery] |
| CMP8 | no | — | No E2EE in the docs; EKM add-on instead. | [s-ekm] |
| CMP9 | yes | all; EKM add-on Enterprise | "Encrypted at rest and in transit by default". | [s-security], [s-ekm] |
| CMP10 | yes | HIPAA Enterprise; FedRAMP Moderate needs Enterprise plus add-on | SOC 2/3, ISO 27001/17/18/701/42001, FINRA. | [s-compliance], [s-plans] |
| CMP11 | n.a. | residency: Business+, Enterprise | 12 regions; no air-gapped install (SaaS). | [s-residency] |
| OPS1 | n.a. | — | SaaS. | — |
| OPS2 | n.a. | — | SaaS. | — |
| OPS3 | n.a. | — | SaaS. | — |
| OPS4 | n.a. | — | SaaS. | — |
| OPS5 | n.a. | — | SaaS. | — |
| OPS6 | n.a. | — | SaaS. | — |
| OPS7 | n.a. | — | SaaS. | — |
| OPS8 | n.a. | — | Proprietary. | — |
| MOD1 | partial | all | Remove from a channel, deactivate an account; no timeout. | [s-remove](x), [s-deact] |
| MOD2 | partial | Enterprise | DLP only; no community automod. | [s-dlp] |
| MOD3 | partial | Free | High-volume sending may be throttled; no admin slowmode found. | [s-limits] |
| MOD4 | partial | Enterprise | Flag content to Content Admins; guests cannot flag. | [s-flag] |
| MOD5 | unverified | — | No account-age or phone gates found. | — |
| MOD6 | yes | Free, Pro, Business+ | Links last 30 days, 400 uses, editable expiry; hidden when SSO is on. | [s-invite] |
| MOD7 | unverified | — | | — |
| MOD8 | partial | Enterprise | Audit logs record admin actions. | [s-audit] |
| COM1 | unverified (absence) | — | | — |
| COM2 | unverified (absence) | — | | — |
| COM3 | partial | all | Posting-restricted announcement channels; no cross-org follow. | [s-posting](x) |
| COM4 | partial | all | Profiles with custom fields; no per-server profile. | [s-profile] |
| COM5 | partial | all | Custom emoji; GIFs if allowed. | [s-huddles] |
| MIG1 | yes | Free, Pro, Business+ | Slack-to-Slack import; Enterprise imports via a separate workspace. | [s-tools] |
| MIG2 | unverified (absence) | — | No Discord import documented. | [s-tools] |
| MIG3 | partial | Free, Pro, Business+ | Generic CSV/text import: channels, messages, users only. | [s-csv] |
| MIG4 | unverified (absence) | — | No first-party bridges found. | — |
| MIG5 | yes | channels: paid on both sides; DMs: all | Slack Connect; up to 250 orgs per channel. | [s-connect] |

[s-plans]: https://slack.com/help/articles/115003205446-Slack-plans-and-features-
[s-pricing]: https://slack.com/pricing
[s-signin]: https://slack.com/help/articles/212681477-Sign-in-to-Slack
[s-saml]: https://slack.com/help/articles/203772216-Set-up-SAML-single-sign-on-for-Slack
[s-scim]: https://slack.com/help/articles/212572638-Manage-members-with-SCIM-provisioning
[s-2fa]: https://slack.com/help/articles/204509068-Set-up-two-factor-authentication
[s-mand2fa]: https://slack.com/help/articles/212221668-Mandatory-workspace-two-factor-authentication-
[s-guests]: https://slack.com/help/articles/202518103-Multi-Channel-and-Single-Channel-Guests
[s-deact]: https://slack.com/help/articles/204475027-Deactivate-a-members-account
[s-delprofile]: https://slack.com/help/articles/360000360443-Delete-profile-information-from-Slack
[s-posting]: https://slack.com/help/articles/360004635551-Manage-channel-posting-permissions
[s-orgadmin]: https://slack.com/help/articles/115005594006-Guide-to-the-Slack-admin-dashboard
[s-profile]: https://slack.com/help/articles/212281478-Customize-member-profiles
[s-poll]: https://slack.com/help/articles/229002507-Conversations--Create-a-poll-in-Slack
[s-search]: https://slack.com/help/articles/202528808-Search-in-Slack
[s-reminder]: https://slack.com/help/articles/208423427-Set-a-reminder
[s-limits]: https://slack.com/help/articles/115002422943-Usage-limits-for-free-workspaces
[s-ai]: https://slack.com/help/articles/25076892548883-Guide-to-AI-features-in-Slack
[s-huddles]: https://slack.com/help/articles/4402059015315-Use-huddles-in-Slack
[s-clips]: https://slack.com/help/articles/4406235165587-Record-audio-and-video-clips-in-Slack
[s-downloads]: https://slack.com/downloads
[s-a11y]: https://slack.com/help/articles/4455747966739-Accessibility-in-Slack
[s-socket]: https://docs.slack.dev/apis/events-api/using-socket-mode/
[s-webhooks]: https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks
[s-outgoing]: https://docs.slack.dev/legacy/legacy-custom-integrations/legacy-custom-integrations-outgoing-webhooks/
[s-slash]: https://docs.slack.dev/interactivity/implementing-slash-commands/
[s-modals]: https://docs.slack.dev/surfaces/modals/
[s-audit]: https://slack.com/help/articles/360000394286-Audit-logs-in-Slack
[s-retention]: https://slack.com/help/articles/203457187-Customize-data-retention-in-Slack
[s-legalhold]: https://slack.com/help/articles/4401830811795-Create-and-manage-legal-holds
[s-discovery]: https://slack.com/help/articles/360002079527-A-guide-to-Slacks-Discovery-APIs
[s-export]: https://slack.com/help/articles/201658943-Export-your-workspace-data
[s-datamgmt]: https://slack.com/trust/data-management
[s-dlp]: https://slack.com/help/articles/12914005852819-Slack-data-loss-prevention
[s-ekm]: https://slack.com/help/articles/360019110974-Slack-Enterprise-Key-Management
[s-security]: https://slack.com/trust/security
[s-compliance]: https://slack.com/trust/compliance
[s-residency]: https://slack.com/help/articles/360035633934-Data-residency-for-Slack
[s-remove]: https://slack.com/help/articles/201898668-Remove-someone-from-a-channel
[s-flag]: https://slack.com/help/articles/25113429335955-Flag-content-in-Slack
[s-invite]: https://slack.com/help/articles/201330256-Invite-new-members-to-your-workspace
[s-tools]: https://slack.com/help/articles/204897248-Guide-to-Slack-import-and-export-tools
[s-csv]: https://slack.com/help/articles/360035354694-Move-data-to-Slack-using-a-CSV-or-text-file
[s-connect]: https://slack.com/help/articles/115004151203-Slack-Connect-guide--Work-with-external-organizations
[s-export-fmt]: https://slack.com/help/articles/220556107-How-to-read-Slack-data-exports

## Microsoft Teams

**Plan names:**
- **Bus:** M365 Business Basic, Standard or Premium.
- **Ent:** Teams Enterprise or M365/O365 E3/E5.
- **Ess:** Teams Essentials.
- **Prem:** the Teams Premium add-on.

Suites are now sold both "with Teams" and "no Teams", next to a standalone Teams Enterprise licence. The date of the worldwide unbundling is unverified.

| id | offered | plan tier | note | source |
|---|---|---|---|---|
| ID1 | yes | all | Cloud-only Entra ID accounts with password. | https://learn.microsoft.com/en-us/microsoftteams/identify-models-authentication |
| ID2 | partial | all | Entra ID is the IdP; external OIDC workforce IdP unverified. | https://learn.microsoft.com/en-us/microsoftteams/teams-security-guide |
| ID3 | partial | all | Entra federates to a SAML 2.0 IdP; Teams not on the supported-client list. | https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-fed-saml-idp |
| ID4 | yes | all | Entra Connect syncs on-premises AD DS; AD FS federation. | https://learn.microsoft.com/en-us/microsoftteams/identify-models-authentication |
| ID5 | partial | Entra ID P1/P2/Governance | Inbound SCIM-schema /bulkUpload API; 2,000 calls/day on P1. | https://learn.microsoft.com/en-us/entra/identity/app-provisioning/inbound-provisioning-api-concepts |
| ID6 | yes | any plan with Teams | SMS, call, Authenticator app; passkeys unverified. | https://learn.microsoft.com/en-us/microsoftteams/identify-models-authentication |
| ID7 | yes | Bus Standard, Enterprise, Education named | Entra B2B guests; Entra External ID billing applies. | https://learn.microsoft.com/en-us/microsoftteams/guest-access |
| ID8 | no | — | Identity is per tenant; cross-org only by external access or guests. | https://learn.microsoft.com/en-us/microsoftteams/trusted-organizations-external-meetings-chat |
| ID9 | yes | all | Org owns Entra accounts; admin disables, removes, resets. | https://learn.microsoft.com/en-us/microsoftteams/teams-security-guide |
| ID10 | yes | all | Team owner/member/guest roles plus M365 admin roles. | https://learn.microsoft.com/en-us/microsoftteams/identify-models-authentication |
| ID11 | yes | all | Private channels (5,000 members) and shared channels. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| ID12 | yes | all | Up to 500,000 teams per tenant. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| ID13 | yes | all | Teams admin center, M365 admin center, PowerShell. | https://learn.microsoft.com/en-us/microsoftteams/trusted-organizations-external-meetings-chat |
| ID14 | partial | all | Profiles live in Entra ID; org chart and custom fields unverified. | https://learn.microsoft.com/en-us/microsoftteams/teams-security-guide |
| MSG1 | yes | all | Standard channels. | https://learn.microsoft.com/en-us/office365/servicedescriptions/teams-service-description |
| MSG2 | yes | all | Private channels. | same |
| MSG3 | yes | all | 1:1 chat. | same |
| MSG4 | yes | all | Group chat up to 250; some features turn off above 20. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| MSG5 | yes | all | Channel reply chains. | https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/import-messages/import-external-messages-to-teams |
| MSG6 | unverified | — | | — |
| MSG7 | partial | all | Reactions yes; custom emoji unverified. | https://learn.microsoft.com/en-us/microsoftteams/export-teams-content |
| MSG8 | yes | all | Team/channel mentions blocked in teams over 10,000 members. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| MSG9 | yes | all | Users can edit and delete; retention keeps copies. | https://learn.microsoft.com/en-us/microsoftteams/retention-policies |
| MSG10 | unverified | — | | — |
| MSG11 | partial | Ent | Polls confirmed in events; chat polls unverified. | https://learn.microsoft.com/en-us/microsoftteams/plan-events |
| MSG12 | yes | all | Chat attachment 100 MB; SharePoint file 250 GB. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| MSG13 | unverified | — | | — |
| MSG14 | yes | all | Rich text, code snippets, quotes. | https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/import-messages/import-external-messages-to-teams |
| MSG15 | unverified | — | User search filters not checked; admin Content Search exists. | https://learn.microsoft.com/en-us/microsoftteams/security-compliance-overview |
| MSG16 | unverified | — | | — |
| MSG17 | unverified | — | | — |
| MSG18 | unverified | — | | — |
| MSG19 | yes | all | Typing indicator and status; off in chats over 20. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| MSG20 | partial | Prem | Live translated captions; message translation unverified. | https://learn.microsoft.com/en-us/microsoftteams/plan-events |
| AV1 | no | — | Channel meetings, not persistent voice rooms. | https://learn.microsoft.com/en-us/microsoftteams/overview-meetings-events |
| AV2 | yes | all | Calls from chat up to 20 people. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| AV3 | yes | all | Video and screen sharing. | https://learn.microsoft.com/en-us/office365/servicedescriptions/teams-service-description |
| AV4 | yes | Bus/Ess 300; Ent 1,000; add-on up to 100,000 | Plus 10,000 view-only; events up to 100,000 with add-on. | https://learn.microsoft.com/en-us/microsoftteams/plan-events |
| AV5 | yes | all; recap needs Prem or Copilot | Recording up to 4 h or 1.5 GB per file; transcripts. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| AV6 | n.a. | — | SaaS. | — |
| CL1 | yes | all | Edge, Chrome, Firefox, Safari. | https://learn.microsoft.com/en-us/microsoftteams/teams-client-system-requirements |
| CL2 | yes | all | Windows and macOS; Linux gets web/PWA only. | same |
| CL3 | yes | all | Last two major iOS versions. | same |
| CL4 | yes | all | Last four major Android versions. | same |
| CL5 | yes / n.a. | all | Microsoft runs push; self-host relay question n.a. | same |
| CL6 | partial | all | Linux PWA; offline mode unverified. | same |
| CL7 | yes | all | Tested with JAWS, NVDA, Narrator; WCAG conformance reports. | https://learn.microsoft.com/en-us/compliance/regulatory/offering-wcag-2-1 |
| INT1 | yes | all | Bots through Teams SDK or Azure Bot Framework. | https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/what-are-webhooks-and-connectors |
| INT2 | yes | all | O365 connectors retired May 2026; Workflows webhooks; outgoing webhooks per team. | same |
| INT3 | unverified | — | Bot commands exist; Slack-style slash commands unverified. | — |
| INT4 | yes | all (not GCC-High/DoD) | Teams Store and org app catalog. | https://learn.microsoft.com/en-us/microsoftteams/platform/overview |
| INT5 | yes | all | Store apps (e.g. Zendesk); Jenkins connector. | https://learn.microsoft.com/en-us/microsoftteams/migrate-slack-to-teams |
| INT6 | no | — | Adaptive Card or MessageCard payloads, not Slack format. | https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/what-are-webhooks-and-connectors |
| INT7 | yes | all | Adaptive Cards with actions; dialogs. | same |
| CMP1 | yes | Audit Standard: Bus, E3; Premium: E5 | Premium keeps 1 year; 10 years needs an add-on. | https://learn.microsoft.com/en-us/office365/servicedescriptions/microsoft-365-service-descriptions/microsoft-365-tenantlevel-services-licensing-guidance/microsoft-purview-service-description |
| CMP2 | yes | O365/M365 E3/E5, Business Premium | Per user or team; deletion can lag 7 days. | https://learn.microsoft.com/en-us/microsoftteams/retention-policies |
| CMP3 | yes | E3 holds; E5 Premium | Hold a user or a team in an eDiscovery case. | https://learn.microsoft.com/en-us/microsoftteams/security-compliance-overview |
| CMP4 | yes | eDiscovery Standard E3; Premium E5 | Export API partners include Smarsh and Proofpoint. | https://learn.microsoft.com/en-us/microsoftteams/export-teams-content |
| CMP5 | partial | Teams licence (conflict: Purview page says E5) | Admin export through the Graph Export API; user self-export unverified. | same |
| CMP6 | unverified | — | | — |
| CMP7 | yes | E5 or Information Protection & Governance add-on | DLP for Teams; Communication Compliance needs E5. | Purview service description (CMP1 link) |
| CMP8 | partial | 1:1 calls all plans; meetings need Prem | Calls and meetings only; chat and files never E2EE. | https://learn.microsoft.com/en-us/microsoftteams/teams-encryption |
| CMP9 | yes | all; Customer Key licensed separately | TLS 1.2+, AES-256, BitLocker, service encryption. | same |
| CMP10 | yes | all | ISO 27001/27018, SOC 1/2, HIPAA, EU Model Clauses, CSA. | https://learn.microsoft.com/en-us/microsoftteams/security-compliance-overview |
| CMP11 | n.a. | Advanced Data Residency add-on | 27 countries; EU Data Boundary. | https://learn.microsoft.com/en-us/microsoft-365/enterprise/advanced-data-residency |
| OPS1 | n.a. | — | SaaS. | — |
| OPS2 | n.a. | — | SaaS. | — |
| OPS3 | n.a. | — | SaaS. | — |
| OPS4 | n.a. | — | SaaS. | — |
| OPS5 | n.a. | — | SaaS. | — |
| OPS6 | n.a. | — | SaaS. | — |
| OPS7 | n.a. | — | SaaS. | — |
| OPS8 | n.a. | — | Proprietary. | — |
| MOD1 | partial | all | Owners remove members; Teams Free "Remove & Block"; no timeout found. | https://support.microsoft.com/en-us/office/invite-and-manage-community-members-in-microsoft-teams-free-3d46a6b9-a762-45a5-af36-9ec792105d18 |
| MOD2 | partial | E5 | Communication Compliance flags offensive language; not an automod. | https://learn.microsoft.com/en-us/microsoftteams/security-compliance-overview |
| MOD3 | no | — | Only tenant-level external messaging limits. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| MOD4 | partial | Defender for Office 365 | Users report suspicious messages; admins remove phishing. | https://learn.microsoft.com/en-us/microsoftteams/teams-security-guide |
| MOD5 | partial | all | Guest one-time passcode; trial tenants blocked; meeting lobby. | https://learn.microsoft.com/en-us/microsoftteams/trusted-organizations-external-meetings-chat |
| MOD6 | partial | Teams Free; meetings all | Join links and QR codes; meeting links expire after 60 days. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |
| MOD7 | unverified | — | A Teams Free community standards page exists. | https://support.microsoft.com/en-us/teams/free/communities/learn-more-about-microsoft-teams-free-community-standards |
| MOD8 | partial | Audit Standard | Purview audit records member changes; no moderator log. | https://learn.microsoft.com/en-us/microsoftteams/guest-access |
| COM1 | partial | Teams Free | Communities can be made discoverable; enterprise directory unverified. | https://support.microsoft.com/en-us/teams/free/communities/what-are-communities-and-channels-in-microsoft-teams-personal |
| COM2 | yes | Ent; Bus Standard/Premium | Events with registration. | https://learn.microsoft.com/en-us/microsoftteams/plan-events |
| COM3 | partial | all | Town halls and channel announcements; no cross-org follow. | https://learn.microsoft.com/en-us/office365/servicedescriptions/teams-service-description |
| COM4 | unverified | — | | — |
| COM5 | partial | all | Stickers yes; GIF search and soundboard unverified. | Graph import page (MSG5 link) |
| MIG1 | partial | Teams licence plus Graph app | Graph import keeps timestamps; 5 req/s per channel; inline images only. | https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/import-messages/import-external-messages-to-teams |
| MIG2 | partial | — | No Discord importer; the generic Graph import API applies. | same |
| MIG3 | n.a. | — | This is Teams; Export APIs get data out. | https://learn.microsoft.com/en-us/microsoftteams/export-teams-content |
| MIG4 | unverified (absence) | — | No first-party Matrix/IRC/Slack/Discord bridge found. | — |
| MIG5 | yes | all (shared channels not in GCC-High/DoD) | External access open by default; shared channels take Entra work accounts only. | https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams |

**Teams source conflicts:**
- **MIG1:** the 2019 Slack migration guide (https://learn.microsoft.com/en-us/microsoftteams/migrate-slack-to-teams) says no DM import and a 200-channel limit. The Graph import page (updated 2026-11-03) includes 1:1 and group chats; the limits page gives 1,000 channels per team. The newer pages were used.
- **Export API licence:** the Purview service description lists the Teams Export APIs under E5. The Export API page says a Teams licence is enough.

## Discord

**Fetch column:** F = fetched in full; X = search extract only.

| id | offered | tier | note | source | fetch |
|---|---|---|---|---|---|
| ID1 | yes | free | Email/phone plus password. | https://support.discord.com/hc/en-us/articles/360057027354-How-to-Login-to-your-Account | X |
| ID2 | no | — | No customer SSO; Discord OAuth2 signs users in to third-party apps only. | https://docs.discord.com/developers/discord-social-sdk/development-guides/account-linking-on-web | X |
| ID3 | no | — | No SAML. | unverified (absence) | – |
| ID4 | no | — | No LDAP/AD. | unverified (absence) | – |
| ID5 | no | — | No SCIM; admins cannot provision accounts. | unverified (absence) | – |
| ID6 | yes | free | TOTP, SMS, security keys/passkeys; server can require 2FA for mods. | https://support.discord.com/hc/en-us/articles/25966860846231-Security-Keys-Passkeys-and-Passwordless-Login-on-Discord | X |
| ID7 | partial | free | No guest accounts; "temporary membership" invites (unverified). | https://support.discord.com/hc/en-us/articles/208866998-Invites-101 | X |
| ID8 | yes | free | One global user-owned account; per-server nicknames. | https://support.discord.com/hc/en-us/articles/219070107-Server-Nicknames | X |
| ID9 | no | — | Admins kick or ban only; no reset, deactivate or takeover. | https://support.discord.com/hc/en-us/articles/360004066391-How-Do-I-Disable-My-Account | X |
| ID10 | yes | free | Roles with granular permissions. | https://discord.com/community/permissions-on-discord-discord | X |
| ID11 | yes | free | Per-channel permission overwrites; private channels. | same | X |
| ID12 | n.a. | free | User joins many servers; per-account server cap unverified. | https://support.discord.com/hc/en-us/articles/33694251638295-Discord-Account-Caps-Server-Caps-and-More | X |
| ID13 | partial | free | Server Settings in the client; no separate admin console. | unverified | – |
| ID14 | partial | free / Nitro | Per-server avatar/banner/bio needs Nitro; no custom fields. | https://support.discord.com/hc/en-us/articles/4409388345495-Per-Server-Profiles | X |
| MSG1 | yes | free | Text channels. | unverified | – |
| MSG2 | yes | free | Through permission overwrites. | see ID11 | X |
| MSG3 | yes | free | Non-friend DMs go to Message Requests for teen/unconfirmed users. | https://discord.com/blog/safer-for-teens-same-discord-for-adults | F |
| MSG4 | yes | free | Group DMs. | same | F |
| MSG5 | yes | free | Threads. | https://support.discord.com/hc/en-us/articles/4403205878423-Threads-FAQ | X |
| MSG6 | yes | free | Forum channels with tags. | https://support.discord.com/hc/en-us/articles/6208479917079-Forum-Channels-FAQ | X |
| MSG7 | yes | free / boost | Custom emoji slots grow with boost level. | https://support.discord.com/hc/en-us/articles/360028038352-Server-Boosting-FAQ | X |
| MSG8 | yes | free | @everyone/@here/@role; AutoMod caps mention spam. | https://support.discord.com/hc/en-us/articles/4421269296535-AutoMod-FAQ | X |
| MSG9 | yes | free | | unverified | – |
| MSG10 | partial | free | Pins yes; saved items unverified. | unverified | – |
| MSG11 | yes | free | Polls; per-role Create Polls permission. | https://support.discord.com/hc/en-us/articles/22163184112407-Polls-FAQ | X |
| MSG12 | yes | free / Nitro | 20 MB free, 50 MB Basic, 1 GB Nitro. | https://support.discord.com/hc/en-us/articles/25444343291031-File-Attachments-FAQ | X |
| MSG13 | yes | free | Link embeds. | unverified | – |
| MSG14 | yes | free | Markdown and code blocks. | unverified | – |
| MSG15 | yes | free | from:, in:, mentions:, has:, date filters. | https://support.discord.com/hc/en-us/articles/115000468588-How-to-Use-Search-on-Discord | X |
| MSG16 | yes | free | | unverified | – |
| MSG17 | yes | free | | unverified | – |
| MSG18 | no | — | No native scheduled messages or reminders. | unverified | – |
| MSG19 | yes | free | | unverified | – |
| MSG20 | partial | free | UI localized; message translation unverified. | unverified | – |
| AV1 | yes | free | Voice channels, user limit up to 99. | https://docs.discord.com/developers/resources/channel | X |
| AV2 | yes | free | DM and group DM calls. | unverified | – |
| AV3 | yes | free / Nitro | Video; Go Live 50 viewers; free 720p30. | https://support.discord.com/hc/en-us/articles/360040816151-Go-Live-and-Screen-Share | X |
| AV4 | yes | free / boost | Stage: audience up to 10,000, 5 cameras. | https://support.discord.com/hc/en-us/articles/1500005513722-Stage-Channels-FAQ | X |
| AV5 | no | — | No native recording or transcription. | unverified | – |
| AV6 | n.a. | — | SaaS. | – | – |
| CL1 | yes | free | | unverified | – |
| CL2 | yes | free | | unverified | – |
| CL3 | yes | free | | unverified | – |
| CL4 | yes | free | | unverified | – |
| CL5 | yes / n.a. | free | Push run by Discord; relay question n.a. | unverified | – |
| CL6 | no | — | No offline/PWA mode. | unverified | – |
| CL7 | partial | free | Accessibility settings, TTS; no WCAG level stated. | https://support.discord.com/hc/en-us/articles/1500010454681-Accessibility-Settings-Tab | X |
| INT1 | yes | free | Gateway plus REST; verification required above 100 servers. | https://docs.discord.com/developers/events/gateway | F |
| INT2 | yes | free | Incoming webhooks; app webhook events; no per-channel outgoing hooks. | https://docs.discord.com/developers/resources/webhook | F |
| INT3 | yes | free | Slash, user and message commands; 100 global slash commands. | https://docs.discord.com/developers/interactions/application-commands | F |
| INT4 | yes | free | OAuth2 apps; App Directory; user-installable apps. | https://support.discord.com/hc/en-us/articles/21334461140375-Using-Apps-on-Discord | X |
| INT5 | partial | free | Native GitHub webhook endpoint; others through third-party bots. | https://docs.discord.com/developers/resources/webhook | F |
| INT6 | partial | free | `/slack` webhook endpoint; no `channel`, `icon_emoji`, `mrkdwn`. | same | F |
| INT7 | yes | free | Buttons, selects, modals. | https://docs.discord.com/developers/components/overview | – |
| CMP1 | yes | free | Server audit log kept 45 days. | https://docs.discord.com/developers/resources/audit-log | X |
| CMP2 | no | — | No admin retention policies. | unverified (absence) | – |
| CMP3 | no | — | No legal hold. | unverified (absence) | – |
| CMP4 | no | — | No eDiscovery or compliance export. | unverified (absence) | – |
| CMP5 | partial | free | User Data Package (own messages only); no server export. | https://support.discord.com/hc/en-us/articles/360004957991-Your-Discord-Data-Package | X |
| CMP6 | yes | free | Deletion after 15–30 day hold; sent messages kept, detached from account. | https://support.discord.com/hc/en-us/articles/5431812448791-How-long-Discord-keeps-your-information | X |
| CMP7 | partial | free | AutoMod keyword/regex; sensitive-media filter; no DLP. | https://support.discord.com/hc/en-us/articles/4421269296535-AutoMod-FAQ | X |
| CMP8 | partial | free | DAVE voice/video E2EE enforced 2026-03-01; Stage excluded; text not E2EE (unverified). | https://discord.com/blog/every-voice-and-video-call-on-discord-is-now-end-to-end-encrypted | X |
| CMP9 | unverified | — | | – | – |
| CMP10 | unverified | — | No public certification page found. | – | – |
| CMP11 | n.a. | — | SaaS. | – | – |
| OPS1 | n.a. | — | SaaS. | – | – |
| OPS2 | n.a. | — | SaaS. | – | – |
| OPS3 | n.a. | — | SaaS; 25 million member server cap (see limits). | – | – |
| OPS4 | n.a. | — | SaaS. | – | – |
| OPS5 | n.a. | — | SaaS. | – | – |
| OPS6 | n.a. | — | SaaS. | – | – |
| OPS7 | n.a. | — | SaaS. | – | – |
| OPS8 | n.a. | — | Proprietary. | – | – |
| MOD1 | yes | free | Kick, ban, timeout up to 28 days. | https://docs.discord.com/developers/resources/guild | F |
| MOD2 | yes | free | AutoMod: keywords, regex, mention spam, ML spam filter. | https://support.discord.com/hc/en-us/articles/4421269296535-AutoMod-FAQ | X |
| MOD3 | yes | free | Slowmode up to 6 h per user. | https://support.discord.com/hc/en-us/articles/360016150952-Slowmode-FAQ | X |
| MOD4 | partial | free | Reports go to Discord Trust & Safety; reports to mods need modmail bots. | https://discord.com/safety/using-modmail-bots | X |
| MOD5 | yes | free | Levels: verified email, account >5 min, member >10 min, phone. | https://docs.discord.com/developers/resources/guild | F |
| MOD6 | yes | free | Expiry 30 min to never; max uses. | https://support.discord.com/hc/en-us/articles/208866998-Invites-101 | X |
| MOD7 | yes | free (Community servers) | Rules Screening, Onboarding, Apply to Join. | https://support.discord.com/hc/en-us/articles/29729107418519-Server-Member-Applications | X |
| MOD8 | yes | free | Audit log kept 45 days. | https://docs.discord.com/developers/resources/audit-log | X |
| COM1 | yes | free | Discovery needs 1,000+ members, 8 weeks age, mod 2FA. | https://support.discord.com/hc/en-us/articles/360030843331-Enabling-Server-Discovery | X |
| COM2 | yes | free | Scheduled events. | unverified | – |
| COM3 | yes | free (Community) | Announcement channels; Follow/Publish across servers. | https://support.discord.com/hc/en-us/articles/360028384531-Channel-Following-FAQ | X |
| COM4 | yes | free / Nitro | Nicknames free; per-server profiles need Nitro. | https://support.discord.com/hc/en-us/articles/4409388345495-Per-Server-Profiles | X |
| COM5 | yes | free / boost | Sticker and soundboard slots grow with boost level. | https://support.discord.com/hc/en-us/articles/360028038352-Server-Boosting-FAQ | X |
| MIG1 | no | — | No official Slack import. | unverified (absence) | – |
| MIG2 | n.a. | — | | – | – |
| MIG3 | no | — | No official Teams import. | unverified (absence) | – |
| MIG4 | partial | free | No official bridges; Slack-format webhook endpoint. | https://docs.discord.com/developers/resources/webhook | F |
| MIG5 | partial | free | Announcement-channel following only; no shared channels or federation. | https://support.discord.com/hc/en-us/articles/360028384531-Channel-Following-FAQ | X |
| EXTRA1 | yes | free | Discoverable servers get public web pages from 2026-11-16; public messages from mid-Dec 2026. | https://support.discord.com/hc/en-us/articles/44049845164823-Discoverable-Server-Web-Presence | X |
| EXTRA2 | yes | free | Age checks gate age-restricted channels, servers and app commands. | https://discord.com/safety/age-assurance-on-discord-vendors-methods-and-your-data | F |

## Pricing and limits

### Slack

Prices are USD per user per month, from https://slack.com/pricing.

| plan | annual billing | monthly billing |
|---|---|---|
| Free | $0 | $0 |
| Pro | $7.25 | $8.75 (promo shown: $4.38 for 3 months) |
| Business+ | $15 | $18 (promo shown: $9 for 3 months) |
| Enterprise+ | $45 | not listed |
| Enterprise (Grid) | not listed | not listed |

- **Free history limit:** you can view and search the last 90 days of messages and files. "Messages and files more than one year old will be permanently deleted", on a rolling basis from 2024-08-26. Free also caps apps at 10, huddles at 2 people, and Slack Connect at 1:1 DMs. ([s-limits], [s-plans])
- **Huddles:** 50 people on paid plans, 25 cameras, 2 screen sharers at once. ([s-huddles])

#### Slack export by plan

Sources: [s-export], [s-tools].

| plan | public channels | private channels and DMs | who |
|---|---|---|---|
| Free | self-serve JSON; file links only; files from last 90 days | Conflict: the export article says "Not available" (private Salesforce channels only, by application). The tools guide says owners may apply, and Slack approves only with "(a) valid legal process, or (b) consent of members, or (c) a requirement or right under applicable laws". | Workspace Owners/Admins |
| Pro | self-serve JSON; file links | same conflict as Free | Workspace Owners/Admins |
| Business+ | yes | Self-serve tool. The Owner applies and the Primary Owner approves. Recurring exports can be scheduled. | Workspace Owners |
| Enterprise | yes, per workspace | The Org Owner requests access through Support. Then export by member, conversation type or workspace. Single-user export includes files in TXT only. Discovery API. | Org Owners |

**Answer to the brief:** yes, Free and Pro self-serve exports hold public channels only. DMs and private channels need Business+ or Enterprise with approval. Free and Pro may also get them through a case-by-case legal application to Slack, according to one of Slack's two pages.

#### Slack export format (what an importer reads)

Source: https://slack.com/help/articles/220556107-How-to-read-Slack-data-exports

- **Top-level files:**
- `users.json` (`org_users.json` on Enterprise), `channels.json`, `integration_logs.json`, `canvases.json`.
- Full exports add `groups.json` (private channels), `dms.json` and `mpims.json` (group DMs).
- Enterprise exports add `content_flags.json` when content flagging is on.
- Canvas comments are referenced through `file_conversations.json`.
- **Conversation folders:** one folder per channel (by name) or DM (by conversation id). Each folder holds one JSON file per date, containing that day's messages. The page does not state the filename pattern (unverified). Dates with no messages have no file.
- **Message fields:**
- `type`, `user`, `text`, and `ts` (a Unix timestamp).
- Optional: `attachments`, `files`, `reactions` (`name`, `count`, `users`; `users` may be incomplete), `pinned_to`, `is_starred`.
- `subtype` marks non-standard messages: `bot_message`, `channel_join`, `file_share`, `message_changed`, `message_deleted`.
- Edits and deletes carry `previous`, `original_ts` and `editor_id`, if retention kept them.
- **Files:** "Slack export files in JSON format do not contain any files from the workspace." Messages hold file links, and canvas `url_private_download` links carry a `t=` token. Links stop working once the file, channel or workspace is deleted. An importer must therefore download the files while the source workspace still exists.

### Microsoft Teams

Prices are USD per user per month with an annual commitment, effective 2026-07-01. Source: https://www.microsoft.com/en-us/licensing/news/2026-m365-packaging-pricing-updates (fetched in full).

| plan | with Teams | no Teams | no Teams, monthly billing |
|---|---|---|---|
| Business Basic | $7.00 | $5.40 | $6.48 (snippet) |
| Business Standard | $14.00 | $10.79 | $12.95 (snippet) |
| Business Premium | $22.00 | $18.79 | $22.55 (snippet) |
| Office 365 E1 | $10.00 | n/a | n/a |
| Office 365 E3 | $26.00 | $17.45 | n/a |
| Microsoft 365 E3 | $39.00 | $30.45 | n/a |
| Microsoft 365 E5 | $60.00 | $51.45 | n/a |

The monthly-billing snippets are from https://www.microsoft.com/en-us/microsoft-365/business/no-teams-plans-and-pricing.

**Standalone licences:**
- **Teams Essentials:** $4.00 with annual billing (snippet; https://www.microsoft.com/en-us/microsoft-teams/essentials). Meetings up to 30 h and 300 people.
- **Teams Enterprise:** $8.55 (snippet; https://www.microsoft.com/en-us/microsoft-365/enterprise/office-365-plans-and-pricing).
- **Teams Premium add-on:** $10.00 (snippet; https://www.microsoft.com/en-us/microsoft-teams/premium).
- **Licensing change:** since 2026-04-01, some former Premium event features are included in Teams Enterprise (https://learn.microsoft.com/en-us/microsoftteams/plan-events).

**Limits.** Source: https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams (updated 2026-11-09).
- **Teams:** 25,000 members per team. Org-wide teams hold 10,000, and a tenant can have 5 of them. A user can join 1,000 teams. A team can have 1,000 channels.
- **Private and shared channels:** a private channel holds 5,000 members. A shared channel holds 5,000 direct members and can be shared with up to 50 teams.
- **Chats and calls:** a group chat holds 250 people; a call started from a chat holds 20.
- **Meetings:**
- 300 interactive attendees on Business plans and Essentials; 1,000 on E3/E5.
- Up to 10,000 more can join view-only.
- Meetings last up to 30 h.
- **Events:**
- Teams Enterprise events allow 1,000 interactive attendees, 3,000 with large-event chat, or 10,000 view-only.
- The Attendee Capacity Pack add-on raises this to 100,000.
- Live events retired 2026-06-30. Live events scheduled before that date run until 2027-02-28.

### Discord

- **Prices:** Nitro Basic $2.99/month; Nitro $9.99/month, which includes 2 server boosts. The page shows no yearly prices. (https://discord.com/nitro, F)
- **Uploads:** 20 MB free (raised from 10 MB in August 2026), 50 MB Nitro Basic, 1 GB Nitro. Boost Level 2 gives a server 50 MB and Level 3 gives 100 MB. (File Attachments FAQ, X; Server Boosting FAQ, X)
- **Boost levels:** Level 1 = 2 boosts, Level 2 = 7, Level 3 = 14.
- Audio bitrate: 128, 256 and 384 kbps.
- Go Live: 720p60 at Level 1, 1080p60 at Level 2.
- Discord says it adjusts the requirements from time to time. (Server Boosting FAQ, X)
- **Server members:** the default cap is 25 million members (September 2025; previously 500K, then 2.5M in July 2025). (https://discord.com/blog/discord-patch-notes-september-3-2025, X)
- **Online members:** `max_presences` is null for most guilds; no numeric online cap is published. (guild docs, F)
- **Voice channels:** user limit up to 99, or unlimited.
- **Video:** the pages conflict: 25 participants on the Video Calls page (https://support.discord.com/hc/en-us/articles/360041721052-Video-Calls, X), up to 50 on the Go Live page.
- **Stage:** audience up to 10,000 depending on boosts, 5 cameras. (Stage FAQ, X)
- **Go Live:** 50 viewers. Free users stream at 720p30. Pages disagree on the Nitro ceiling: 1080p60 or 4K60.

## Discord identity model

### Account model

- **One global account across servers:** the user owns it. Per-server nicknames are free; a per-server avatar, banner and bio need Nitro. (Server Nicknames and Per-Server Profiles, X)
- **What admins can do:** kick, ban, or time out for up to 28 days (guild docs, F). They cannot reset, deactivate or take over an account.
- **Account deletion:** the user must first transfer any servers they own. Discord holds the account 15–30 days, then detaches the user's messages from it and keeps them. (Disable Account and retention articles, X)
- **Ownership transfer when an owner goes inactive:** Discord transfers ownership only when all of these hold:
- the server has 100 active members;
- the owner has been offline for at least a month;
- the requester is an active mod or admin;
- the server is not monetized;
- the owner consents or does not reply within 7 days.

(https://support.discord.com/hc/en-us/articles/26286635870359-Requesting-a-Transfer-of-Server-Ownership, X)

### Age assurance (Discord's own pages)

- **2025-07-21, UK (Online Safety Act):** teen-safe defaults for everyone. To unblur sensitive content, enter age-restricted spaces or change Message Requests, adults verify through the vendor k-ID, by face estimation or by ID. (https://discord.com/safety/adapting-discord-for-the-uk-online-safety-act, F)
- **2025-12-09, Australia:** the same teen-by-default model. (https://discord.com/safety/introducing-new-teen-by-default-experiences-for-australian-users, F)
- **2026-02-09:** global teen-by-default announced, rollout planned for early March 2026. The page is now marked out of date. (https://discord.com/press-releases/discord-launches-teen-by-default-settings-globally, F)
- **2026-02-24:** the global rollout was delayed to the second half of 2026. Discord dropped a UK test of the vendor Persona and now requires face estimation to run on the device. Brazil age checks started 2026-03-09. (https://discord.com/blog/getting-global-age-assurance-right-what-we-got-wrong-and-whats-changing, F)
- **2026-09-22:** from about 2026-09-23, Discord infers each account's age group (teen, adult or unconfirmed) from account signals.
- Discord says more than 90% of users are never asked to confirm their age.
- Unconfirmed users get the teen restrictions.
- (https://discord.com/blog/safer-for-teens-same-discord-for-adults, F)
- **Methods and data (2026-09-22):**
- k-ID runs the checks, using Veratad for ID scans and Stripe for card checks.
- Other routes: face estimation on the device, AgeKey (a passkey), Google Wallet, app stores.
- Discord says it receives only the age result, and vendors must delete the data after the check.
- (https://discord.com/safety/age-assurance-on-discord-vendors-methods-and-your-data, F)
- **Vendor breach (dated 2025-10-03, updated 2025-10-09):**
- Discord's support vendor 5CA was breached. About 70,000 users may have had government-ID photos exposed; these were images submitted for age appeals.
- Also exposed: names, emails, IP addresses, limited billing details, support messages.
- Discord says its age-check vendors were not involved.
- (https://discord.com/press-releases/update-on-security-incident-involving-third-party-customer-service, F)

### Bot limits a community admin hits

- **Verification:** an app needs verification to grow past 100 servers. The team owner verifies identity through Stripe and must be 16 or older. (https://support-dev.discord.com/hc/en-us/articles/23926564536471-How-Do-I-Get-My-App-Verified, X)
- **Privileged intents:** restricted data access (`GUILD_MEMBERS`, `GUILD_PRESENCES`, `MESSAGE_CONTENT`) needs approval for verified apps. Above 10,000 users an app needs a review, renewed each year. (https://docs.discord.com/developers/events/gateway, F)
- **Gateway limits:** 120 events per 60 seconds; 1,000 IDENTIFY calls per day.
- **REST limits:** 50 requests per second per bot. An IP is banned after 10,000 invalid requests in 10 minutes. (https://docs.discord.com/developers/topics/rate-limits, F)
- **Command limits:** 100 global slash commands; 200 command creations per day per guild. (application-commands docs, F)
- **Self-bots:** automating a user account is forbidden and can get the account terminated. (https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots, X)

### Data export limits a community admin hits

- **No server export:** admins cannot export a server.
- **Data Package:** the only export is the user's own Data Package. It holds that user's sent messages with links to attachments, for servers the user is in or recently left. (Data Package article, X)
- **Developer Policy:** rule 20 forbids mining or scraping Discord data. Rule 21 forbids training AI on message content without permission. (https://support-dev.discord.com/hc/en-us/articles/8563934450327-Discord-Developer-Policy, X)
- **Developer Terms:** section 5(b) requires deleting API data once the app no longer needs it.
- **Effect on migration:** an archiving or migration bot needs the approved Message Content intent and may keep only the data its approved function needs.

### Pending policy change

New Terms of Service and Privacy Policy take effect 2026-12-15. Their content was not reviewed. (https://discord.com/safety/important-policy-updates, X)

---

**Cleanup:** the Teams fork left a temp folder, /tmp/claude-1000/teamsfork, that holds only Microsoft "request blocked" HTML pages. You can delete it.