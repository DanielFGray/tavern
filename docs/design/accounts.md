# Accounts

How an account is deleted, and how a kicked member's deletion is scheduled, and why.

## Summary

- `Tavern.Accounts.delete_account/2` is the one deletion. Every path runs it: the scheduled deletion sweep, and the prune of never-verified accounts.
- `Tavern.Chat.kick_member_and_schedule_deletion/3` kicks a member and sets `memberships.deletion_scheduled_at` to 30 days ahead. `Chat.kick_member/3` still kicks without a schedule.
- `Tavern.Accounts.DeletionSweeper` deletes the accounts whose date has passed, once an hour, through `Accounts.delete_due_accounts/1`.
- A rejoin with an invite, a ban, or a moderator with `kick_members` cancels a schedule. A banned account is never deleted automatically.
- Messages stay. Their author shows as "Deleted user" everywhere the account's display name shows.

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
- writes an `account_deleted` audit entry with the actor (none for the sweep).

After the commit, the account's open LiveViews get `"disconnect"`, and its avatar, banner and server avatar leave the object store. Both happen after the commit, so a reconnect finds no session and a rollback never loses an image.

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
