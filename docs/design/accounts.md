# Accounts

How an account verifies its email, how a forgotten password is reset, how it is deleted, and how a kicked member's deletion is scheduled, and why.

## Summary

- `Tavern.Accounts.delete_account/2` is the one deletion. Every path runs it: the scheduled deletion sweep, and the prune of never-verified accounts.
- `Tavern.Chat.kick_member_and_schedule_deletion/3` kicks a member and sets `memberships.deletion_scheduled_at` to 30 days ahead. `Chat.kick_member/3` still kicks without a schedule.
- `Tavern.Accounts.DeletionSweeper` deletes the accounts whose date has passed, once an hour, through `Accounts.delete_due_accounts/1`.
- A rejoin with an invite, a ban, or a moderator with `kick_members` cancels a schedule. A banned account is never deleted automatically.
- Messages stay. Their author shows as "Deleted user" everywhere the account's display name shows.
- A member who has not confirmed their email holds the Unverified role, which by default makes them read only. Registration mails a confirmation link. An email change applies only when the link sent to the new address opens. With no mail provider, verification is inactive and nobody is restricted.
- A member who forgot their password asks for a reset link on the login page. The link works once, for 1 hour, and ends every session of the account. Without a mail provider the page says reset is unavailable.

## Deleting an account

`delete_account(user_id, actor_id)` runs one transaction. It locks the membership row, then the user row. Every deletion path takes the locks in that order, so two deletions of one account wait for each other and do not deadlock. It reads the account's state under those locks:

| State | Result |
| --- | --- |
| No such user, or an id that is not a UUID | `{:error, :not_found}` |
| A bot or the system account | `{:error, :bot}`. A bot is revoked (`Bots.revoke_bot/2`), never deleted. |
| Already deleted | `{:ok, user}`, and nothing is written |
| An owner | `{:error, :owner}`. An owner is demoted first. |
| Any other account | wiped, `{:ok, user}` |

The function checks no permission. Each caller decides who may delete: the sweep runs on a schedule a moderator set, and the prune checks `kick_members`.

The wipe changes the user row (`User.deletion_changeset/2`):

- `email` is set to null. The column is nullable, so the email can register again at once.
- `username` becomes `deleted-` and 16 random hex digits. The column is not nullable and is unique, so it needs a value. Registration allows only `[a-z0-9_]`, so no member can take a `deleted-` name first. The hex is random, so nobody can register it ahead of a deletion. The old username is free at once.
- `display_name` becomes `Deleted user`. Every place that prints an author prints the display name (the message list, replies, thread and forum summaries, the bot API's `author`), so the deleted author reads as "Deleted user" with no change to those places. No author has a profile link today.
- `bio`, `hashed_password`, `confirmed_at`, `avatar_asset_id` and `banner_asset_id` are cleared, and `deleted_at` is set. With no email and no password, the account cannot sign in.

It also:

- deactivates the membership (`Membership.deleted_account_changeset/2`), keeping an earlier deactivation's date and flags, and clears the nickname, pronouns, server avatar, timeout and deletion schedule;
- deletes the member roles, channel permission overwrites for the user, channel read state, notification settings and overrides, thread follows, bot tokens, and every `user_sessions` row of any context;
- deletes the `media_assets` rows of the avatar, banner and server avatar;
- writes an `account_deleted` audit entry with the actor (none for the sweep).

After the commit, the account's open LiveViews get `"disconnect"`, and the objects of those images leave the object store (`MediaAssets.delete_objects/1`). Both happen after the commit, so a reconnect finds no session and a rollback never loses an image.

What stays: messages, reactions, poll ballots, invite uses, moderation cases, message reports and audit entries. They are the server's record, and other members' messages reply to and quote these messages. Invites the account created stay usable. An invite belongs to the server, and revoking one is a moderator's choice.

Mentions are recorded from `@username` tokens. A token matches only accounts that are not deleted, so a tombstone name is never recorded as a mention.

## Scheduled deletion

`kick_member_and_schedule_deletion(scope, user_id, reason)` runs through the same moderation transaction as a kick (`Visibility.authorize_write/3` with `kick_members`, the rank rule, no owners, not oneself). It:

1. kicks: deactivates the membership with the `kicked` flag, writes the `:kick` moderation case and the `kick_member` audit entry;
2. sets `deletion_scheduled_at` to now plus 30 days;
3. writes an `account_deletion_scheduled` audit entry with the date.

A bot subject is `{:error, :forbidden}`. After the commit, the member's sessions end as for a kick. If a mail provider is configured (`Tavern.Mailer.configured?/0`) and the account has an email, `Tavern.Accounts.DeletionNotice` mails the member the date, and says that signing in and entering an invite before then keeps the account. With no provider, no mail is sent and nothing fails.

The schedule lives on the membership, not the user, because rejoining and moderation already lock the membership row. Only a kicked membership carries a date: every reactivation (a rejoin, an unban) clears it, and so does a ban.

### Cancelling

Each cancellation clears the date and writes an `account_deletion_canceled` entry naming the actor, with the canceled date in its metadata.

- **Rejoin.** `Chat.rejoin_with_invite/2` reactivates the membership and cancels. The member is the actor.
- **Ban.** `Chat.ban_member/3` cancels in the same transaction as the ban. The moderator is the actor. A banned account must stay: deleting it would null its email, and the same person could then register again with that email, past the ban.
- **Moderator.** `Chat.cancel_account_deletion/2`, for a scope with `kick_members`, clears the date under the membership lock. The member stays kicked. With no date set it is `{:error, :not_found}`.

`Chat.list_scheduled_deletions/1` lists the scheduled members, soonest first, for the same permission.

### The sweep

`DeletionSweeper` is a GenServer in the supervision tree, built like `Tavern.Chat.PollCloser`. It sweeps one minute after start and then every hour; a deletion is due 30 days ahead, so an hour late costs nothing. `config :tavern, :deletion_sweeper, false` leaves it out, which the test config does. Tests call `delete_due_accounts/1` with a chosen time.

`delete_due_accounts(now)` selects up to 500 due memberships. It then deletes each in its own transaction. That transaction takes the membership row `FOR UPDATE SKIP LOCKED` and checks again that the date is at or before `now`, the membership is still deactivated, and it is not banned. The ban check is a second guard behind the ban path's cancellation, for a banned row that still carries a date. As a result:

- a rejoin, a ban or a cancellation that commits between the select and the delete keeps the account;
- when two nodes sweep at once, one skips the row the other holds; after the commit, the schedule is clear;
- a second sweep finds nothing, because the deletion clears the schedule.

## UI

- **Settings > Server, member actions.** The moderation form has a "Kick and delete in 30 days" button beside Kick, for members who may kick that member. It asks for confirmation.
- **Settings > Server, Scheduled deletions.** For `kick_members`, a panel lists each scheduled member with "Deletion scheduled for <date>" and a "Cancel deletion" button. It sits beside the Bans panel, not in the member list: the member list shows only active members, and a kicked member is not one.
- **The removed page** (`/banned`, which a kicked member reaches on sign-in) names the deletion date above the rejoin form.

## Audit lines

| Action type | Line |
| --- | --- |
| `account_deletion_scheduled` | `@mod scheduled the deletion of @member for Dec 19, 2026: reason` |
| `account_deletion_canceled` | `@actor canceled the deletion of @member` |
| `account_deleted` | `@actor deleted the account @deleted-…`, or `The scheduled deletion removed the account @deleted-…` from the sweep |

An entry about a deleted account shows its tombstone handle. No entry stores the old username or email.

## First owner

A fresh server has no owner, and its first human registration becomes the owner, even when registration is invite only (`Accounts.register_user/2`). So a new production database is served on a tailnet route first: the operator registers there, sets registration to invite only, and only then does the route change to the public host. `Tavern.Release.make_owner/1` promotes an existing account when the first owner must be someone else.

## Client address

The login, registration, password-reset and invite-request limits count requests per client IP, so the address must be one the client cannot choose. `TavernWeb.Plugs.ClientIp` (and `socket_client_ip/1` for LiveView mounts) sets `remote_ip` from the one header that `TRUSTED_PROXY_HEADER` names. The header holds a single address. When it is unset, missing or not an address, the peer address stays.

The cartridge sets the header to `x-real-ip`. On a public route Traefik is the only proxy; it writes `X-Real-Ip` from the socket address and drops any value the client sent (roamancer `tools/alchemy/platform/ingress/README.md:10`). `X-Forwarded-For` is not used: a client can write it, and no platform document says Traefik overwrites it.

Production's route is the public host `tavern.danielfgray.com` once the first owner exists (Traefik's `web` entry point, with no Cloudflare proxy in front), where `X-Real-Ip` is the client's socket address. The staged copy stays on a tailnet route, where `X-Real-Ip` is cynic's address (same README line), so every staged visitor shares one limiter bucket.

## Email verification

### Who is unverified

`Accounts.unverified?/1` is the one test. A user is unverified when all of these hold:

- `confirmed_at` is nil;
- the user is not a bot and not deleted;
- the user does not own the server;
- a mail provider is configured (`Accounts.verification_active?/0`, which is `Tavern.Mailer.configured?/0`).

Without a provider a member cannot receive a link, so restricting them would lock them out with no way back. Settings > Roles then shows "Email verification is inactive" and names the missing settings (`Tavern.Mailer.missing_settings/0`). An owner is never restricted: the owner must always be able to run the server. A bot has no inbox; its token is the proof.

The migration `20261119181454_add_email_verification` sets `confirmed_at` on every existing, not deleted account, so no member loses rights when it deploys. An account that registers while verification is inactive keeps `confirmed_at` nil. Once a provider is configured, that account becomes unverified and can resend the link from the banner.

### The Unverified role

An unverified member holds the Unverified role (`roles.is_unverified`) without a `member_roles` row, as every member holds `@everyone`. `Visibility.load` reads the role in the same statement as the member and passes it to `Authorization` as an implicit role. Denies and allows then combine as for any held role (roles.md, "Server permissions"), so another role that allows a bit wins over the Unverified deny.

`Bootstrap.ensure_unverified_role!/0` creates it with these denies: `send_messages`, `send_messages_in_threads`, `create_public_threads`, `create_private_threads`, `attach_files`, `add_reactions` and `mention_everyone`. The role denies nothing for invites, and an unverified member still cannot create one: creating an invite needs `manage_server`, which `@everyone` does not allow. A deny removes only what `@everyone` allows, so an invite deny would change nothing. A member who holds `manage_server` through another role keeps it, since allow wins. Bootstrap writes the bits only when it creates the role, so a manager's edits stay across deploys.

The role is managed. Nobody deletes, moves, gives or takes it, and no message can mention it. Its name, color and flags are fixed; only its allow and deny bits are editable, under the role rule (roles.md, "Fixed rules"). It sits at position 0 beside `@everyone`, outside the ranked roles. A unique partial index allows one such role, and the `unverified_role_is_not_default` check keeps it apart from the default role.

The bot API's member `role_ids` lists the Unverified role while the member holds it.

### Email tokens

Tokens follow the phx.gen.auth pattern and live in `user_sessions`:

- The mail carries a random token. The table stores only its hash (`hash_token`).
- `context` is `"confirm"`, `"reset"` for a password reset, or `"change:<old email>"` for an email change. `sent_to` is the address the mail went to.
- A token expires 7 days after it is made (`expires_at`), or 1 hour for a reset. Using it deletes it and every other token of the same kind for that user, so a link works once.

A confirmation or reset token works only while the account's email is still the `sent_to` address. A change token works only while the account's email is still the old address in its context. A link mailed before another change therefore fails. A token never works for a deleted account or a bot.

Each use runs in one transaction that locks the token row and the user row `FOR UPDATE`, so two clicks on one link cannot both succeed.

### Registration and resend

`UserRegistrationLive` calls `Accounts.deliver_user_confirmation_instructions/1` after the account is created. The function sends nothing to a verified, bot, deleted or email-less account, or while verification is inactive. `Accounts.register_user/2` sends no mail itself, so fixtures and the test support commands do not fill test mailboxes.

Registering with the address an invite request's link was mailed to verifies it at once, so no confirmation mail follows (invite-requests.md, "Flow", step 5). A failed send does not block registration. The member can ask for a new link from the banner (`Accounts.resend_user_confirmation/1`). `LoginRateLimiter.check_email_link/1` allows 3 link mails per member per 15 minutes, resends and email changes together, in the same bucket store as the login limit (Valkey, with an ETS fallback). Past the limit the banner flashes how long to wait.

### Opening a link

| Route | Effect |
| --- | --- |
| `GET /users/confirm/:token` | `Accounts.confirm_user/1` sets `confirmed_at`, then redirects to `/` with a flash. |
| `GET /users/confirm-email/:token` | `Accounts.update_user_email_from_token/1` writes the new email, sets `confirmed_at` if it was nil, then redirects to `/settings`. |

Both routes sit in the `:browser` pipeline without an authentication requirement. They sign nobody in or out. The member opens the link in whichever browser the mail client picks, signed in or not. After the commit, both broadcast `{:email_confirmed, user_id}` on the server topic. The member's open ServerLive views reload the member and the open channel, so the banner goes and the composer unlocks without a reload, even when the link opened in another tab. Other views reload their member list, which drops the badge.

### Email change

`Accounts.update_user_email/3` checks the current password and validates the new address, including uniqueness. When verification is active it does not write the address. It mails a change link to the new address and returns `{:ok, :confirmation_sent}`. That mail counts toward the same per-member link limit as a resend. The member stays verified meanwhile, and the old address keeps working. The address changes only when the link opens, which also proves the member controls it. If another account took the address in the meantime, the link answers "taken" and changes nothing. With verification inactive, the change applies at once, as before.

### Password reset

A member who forgot their password asks for a link, opens it, and sets a new one. It needs a mail provider (`Accounts.password_reset_available?/0`, the same test as verification). Without one, the login page hides "Forgot password?", and `/users/reset-password` says that reset is unavailable and to ask a server admin.

| Route | Page |
| --- | --- |
| `/users/reset-password` | `PasswordResetRequestLive`: one email field. |
| `/users/reset-password/:token` | `PasswordResetLive`: one new-password field. |

Both live in a session with no authentication rule, so a signed-in visitor can use them. The link's token is the authority, as for the confirm links.

**Asking.** `Accounts.request_password_reset/2` takes the email and the client IP. The page shows the same "If that email belongs to an account, a reset link is on its way" for every email, so it does not reveal which emails have accounts. The request first counts against the login limiter (`LoginRateLimiter.check_attempt/2`, the limiter that guards the login form). Past the limit the page flashes how long to wait, for any email. A later request for an account also counts against the per-member link limit above (3 per 15 minutes, shared with resends and email changes). Past that limit nothing is sent, and the reply is unchanged, so a visitor cannot fill a member's mailbox. A bot, a deleted account or an account with no password gets no mail. The mail goes out in a task under `Tavern.Mailer.TaskSupervisor`, so the reply takes about as long for an email with an account as for one without. The lookup and token insert still run in the request, so a precise timing test could tell them apart by a few milliseconds.

**The token.** Context `"reset"`, `sent_to` the account's email, valid 1 hour. A new request deletes the account's older reset token, so only the newest link works. It works only while the account's email is still `sent_to`, like a confirm token.

**Setting the password.** `Accounts.reset_user_password/2` runs `User.password_changeset/3`, which has the registration rules (12 to 72 bytes). A password that fails them returns the changeset, and the link still works. On success, in one transaction that locks the token row, it saves the hash and deletes every email token of the account: its reset token, and any `confirm` and `change:` token mailed earlier, so a link requested under the old password stops working. After the commit it calls `Accounts.revoke_user_sessions/1`, which deletes every session and closes the member's open sockets. The page then sends the member to `/login` with a flash. It does not sign them in. A used, expired or unknown link shows "This reset link does not work" with a link to ask again. The page checks the token on mount (`get_user_by_password_reset_token/1`), and again on save.

The link opens a form (a GET that changes nothing), so a mail scanner that follows it spends nothing: only the save spends the token. A link from an email verifies that email, so a successful reset also sets `confirmed_at` when it is nil, in the same transaction: the token's `sent_to` is the account's current email. After the commit it runs the shared first-verification path (`after_email_confirmed/1`): the `{:email_confirmed, user_id}` broadcast that unlocks the member's open views and drops the badge, and the `member_verified` product event. A reset for an account that is already verified changes nothing about its verification and announces nothing.

### UI

- **Banner.** ServerLive shows "Check <email> to verify your account." with a Resend button, above the channel view, while the member is unverified.
- **Composer.** In place of the form, the locked notice says "Verify your email to send messages" when verification is the reason. The thread reply notice says "Verify your email to reply."
- **Badge.** The member list in ServerLive and in Settings > Server shows "unverified" beside an unverified member, only to viewers with `manage_roles`.
- **Settings > Roles.** The Unverified role lists its member count and "unconfirmed emails". Its editor shows only the permission grid.

### Tests and the capture provider

The dev and test configs use the capture mail provider (`Tavern.Mailer.Capture`), so verification is active in tests. Capture logs each mail, so in development the link is in the server log. It also sends `{:mail_captured, email}`, but only to a process that called `Capture.subscribe/0`, when that process sent the mail or started the process that did (`$callers`). The `DataCase` and `ConnCase` setups subscribe the test process, and the e2e command subscribes its request. A LiveView never subscribes, so a view that sends mail never receives it.

`user_fixture/1` and the test support commands make verified users by default, because most tests need a member who can send. `unverified_user_fixture/1`, and `"verified": false` on the `upsert_user` and `login` commands, make an unverified one. The `capture_verification_mail` command mails a fresh link and returns its path, for e2e specs. It works wherever the e2e server runs (`MIX_ENV=test`), since it subscribes before it sends.

### Known gaps

- The link is a GET. A mail scanner that follows links can use a token before the member does. The member then finds the account verified, or asks for a new link.
- Pruning accounts that never verify is separate work.
- The app has no signed-in password change yet. When it ships it must also delete the account's email tokens (`Accounts.reset_user_password/2` shows how), so a link requested under the old password stops working.
