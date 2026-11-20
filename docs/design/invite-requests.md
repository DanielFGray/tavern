# Invite requests

How a stranger asks to join an invite-only server, how a moderator answers, and why.

## Summary

- An invite-only server can turn on **Accept invite requests** (Settings > Server, in the server settings form). The sign-up page then shows a "Request an invite" form that takes only an email address.
- A member who holds `manage_applications` sees the **Requests** queue in Settings > Server. The owner and administrators pass, as for every bit.
- **Approve** binds a one-use invite to the request and mails its link. **Deny** records the decision and mails nothing. **Deny all from this IP** denies every pending request from one address at once. **Resend** mails an approved request's link again.
- `Tavern.Chat.InviteRequests` holds the rules; `Tavern.Chat` delegates to it. `Tavern.Chat.InviteRequestLimits` holds the abuse limits, counted by `Tavern.RateLimit` (rate-limits.md). `Tavern.Mailer` sends the mail.

Terms:

- **Request**: an `invite_requests` row: email (citext), client IP, status `pending | approved | denied`, `requested_at`, `decided_at`, `decided_by_id`, `invite_id`, `delivered_at`, `delivery_error`.
- **Intake limit**: a cap on stored requests. **Send limit**: a cap on invite mail.

## Flow

1. The applicant submits an address on `/register`. `request_invite/2` validates it, checks the intake limits, and stores a pending request. It sends no mail.
2. A moderator opens the queue. `list_invite_requests/2` returns the requests, pending first, each with `ip_request_count`: how many requests came from its IP.
3. `approve_invite_request/2` runs one transaction: `Visibility.authorize_write(scope, :manage_applications, :server)`, lock the request row, check it is still pending, insert a one-use invite (`Invites.insert_single_use!/2`, expiring after `invite_expiry_days`), mark the request approved, and write an `invite_request_approved` audit entry.
4. After the commit, the server reserves a send under the send limits and mails the link `/register?code=<code>`. The outcome goes on the request: `delivered_at`, or `delivery_error`.
5. The link opens the sign-up page with the code filled in. `Accounts.register_user/2` redeems it through the existing invite path, inside its own transaction.

   A link from an email verifies that email: when the invite is bound to an approved request (`invite_requests.invite_id`) and the new account's email equals the request's (`Invites.mailed_to?/2`, case-insensitive), `register_user/2` sets `confirmed_at` in the same transaction and, after the commit, runs the shared first-verification path (`after_email_confirmed/1`: the `{:email_confirmed, user_id}` broadcast and the `member_verified` product event). `UserRegistrationLive` then mails no confirmation link, because that function skips verified accounts. Another address, or an invite made by hand, leaves the account unverified.

## Rules and reasons

- **The form answers the same every time.** A new address, a duplicate pending request, a member's address and a request over an intake limit all get "Request received". Different answers would tell a stranger who is registered and where the limits sit.
- **A request sends no mail.** Only a moderator's Approve or Resend sends mail. Otherwise anyone could make the server mail any address.
- **Intake limits store nothing when exceeded.** Per IP: `requests_per_ip_hour` and `requests_per_ip_day`. Server-wide: `pending_requests_per_day` new pending requests. A duplicate or a member's address does not use the server-wide cap.
- **Send limits never undo a decision.** At most `mails_per_address_day` invite mails per address (Resend included) and `mails_per_day` in all. Over a cap, the approval still stands, the queue shows "not sent: daily limit", and Resend works once the window ends. A send that fails hands its reservation back, so a failed send does not use up the address's allowance.
- **Limits fail closed.** When Valkey cannot be reached, the request is not stored and the mail is not sent. A stranger's form must not become mail by riding an outage.
- **Windows are fixed.** `Ephemeral.increment_rate_limit/3` sets the expiry only on a new key (`EXPIRE ... NX`), so a retry inside the window does not extend it.
- **Mail goes out after the commit.** The decision is committed whatever the mail provider does. A send failure leaves the request approved, with its error shown in the queue and a Resend button.
- **Approval uses its own invite insert.** `Invites.create_invite/2` authorises on `manage_server`; a moderator with only `manage_applications` must still be able to approve. `insert_single_use!/2` trusts the caller's authorisation and must run inside its transaction. The new member starts in `#general`, or else the first text channel.
- **Resend reuses the bound invite.** When that invite was used, revoked or expired, Resend refuses, and the moderator creates a new invite by hand.
- **Requests need mail.** The setting cannot be turned on while `Tavern.Mailer.missing_settings/0` is non-empty, and the form stays closed while mail is not configured, even with the setting on. There is no fallback delivery path.

Every limit number lives in `config :tavern, Tavern.Chat.InviteRequests` in `config/config.exs`.

## Mail

`Tavern.Mailer.deliver/1` sends through the provider in `config :tavern, Tavern.Mailer`:

- `:cloudflare` (production): Cloudflare Email Service's REST API, `POST https://api.cloudflare.com/client/v4/accounts/{account_id}/email/sending/send`, with a Bearer token that holds "Email Sending: Edit". The sender's domain must be onboarded for Email Sending on the account that owns the token. `config/runtime.exs` reads `MAIL_PROVIDER`, `EMAIL_FROM`, `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_EMAIL_API_TOKEN`.
- `:capture` (development and test): sends `{:mail_captured, email}` to the calling process and its `$callers`, and logs the text body, so the link is in the dev server log.

Production mail: `cartridge.json` sets `EMAIL_FROM` (`tavern@dfg.rocks`, on a domain already onboarded for Email Sending) and `MAIL_PROVIDER=cloudflare`, and references two `KvSecret` entries (path `secret/data/tavern`, keys `cloudflare_email_api_token` and `cloudflare_account_id`, env `CLOUDFLARE_EMAIL_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`). `ops secret set` stores only a secret the cartridge references, so the entries come first; then the operator runs `ops secret set cloudflare_email_api_token` and `ops secret set cloudflare_account_id`, and `ops secret list` shows both set. The platform refuses to deploy while a declared secret is unset. The staged copy inherits the same entries and sends real mail (user decision 2026-11-20).

dfg.rocks and the other apps on this platform reach the same service over SMTP (`smtp.mx.cloudflare.net:465`, user `api_token`). Tavern uses the REST API instead, because Req speaks HTTP and SMTP would need a mail library. The REST API needs the account id, which SMTP does not.
