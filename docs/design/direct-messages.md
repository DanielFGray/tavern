# Direct messages

Status: designed, not built.

A direct message (DM) is a private conversation between two accounts on the server. A member or
a bot may start one. Group DMs are not part of this design.

## Rule

**Only the two participants can see a DM.** Permission bits, roles and overwrites never grant
access to one. The owner and administrators hold every bit, so a DM rule that read bits would
show them every DM.

Inside a DM, the server-wide bits still limit what a participant may do. A member who cannot
send in channels (the Unverified role, or a timeout) cannot send in a DM either.

## Owner answers

These are agent records of the owner's answers (tasks: "Direct messages and group DMs" and its
three questions, 2026-11-25):

- 1:1 only for now.
- Privacy is a server setting, `private` or `owner_can_read`. A new install picks it when the
  server is created, and it cannot change later. This server is `private`. Members see which
  setting applies.
- With `owner_can_read`, the owner opens any DM from the moderation panel. Each opening writes
  an audit-log entry.
- Any member may DM any member. Each member can turn off DMs from members they have no DM with
  yet.
- A block refuses the blocked account's DMs and collapses their messages in channels.
- Members who cannot send server-wide (Unverified, timed out) cannot send DMs.
- Bots may receive, answer and start DMs. Blocks and the opt-out apply to bots too.
- A member may report a DM message. The report shows moderators that one message only.

## Data

- **The DM is a channel row** of kind `:direct`. So messages, reactions, attachments, embeds,
  edits, deletes, read state (`ChannelMembership`), search, message links and the transcript
  pane work on it unchanged.
  - `direct_low_user_id` and `direct_high_user_id` name the two participants, the lower id
    first.
  - A check constraint holds: kind `direct` if and only if both columns are set, and low < high.
    So an account cannot DM itself.
  - A unique index on the pair (where `deleted_at IS NULL`) makes one DM per pair. Two members
    who open a DM at the same moment get the same row: the insert uses `on_conflict`.
  - `name` is nil and `slug` is `dm-<uuid>`, as a thread's slug is `thread-<uuid>`. Nothing
    reads a DM's slug.
  - Virtual field `peer`: the other participant, for the viewer. The read that loads a DM sets
    it.
- **`server_settings.direct_message_privacy`**, enum `private | owner_can_read`, default
  `private`. `Tavern.Bootstrap` writes it once when it creates the settings row, from the
  deploy setting `TAVERN_DM_PRIVACY`. No changeset casts it. An existing server gets `private`
  from the migration.
- **`users.direct_messages_from_new_contacts`**, boolean, default true. This is the opt-out.
- **`user_blocks`** (`blocker_id`, `blocked_id`, `inserted_at`), primary key on the pair.

## Decisions (Tavern.Chat.Visibility)

The DM rules are their own clauses, ahead of every bit check:

| Action | Rule |
| --- | --- |
| view | the scope's account is a participant, and the DM is not deleted |
| send, react, attach | view, not timed out, the server-wide bit (`send_messages`, `add_reactions`, `attach_files`), the peer is an active member, and neither participant blocks the other |
| delete or edit own message | view (as in a channel) |
| anything else (manage or pin messages, threads, @everyone, voice) | false |

A participant who holds `manage_messages` or `administrator` still cannot delete the peer's
messages in their DM.

**Opening a DM** (`Chat.open_direct_message(scope, user_id)`) returns the existing DM of the
pair. It creates one only when all of these hold:

- the target is an active member, and is not the scope's account;
- the scope may send server-wide;
- neither account blocks the other;
- the target accepts DMs from new contacts.

A refusal is one error, `:not_available`, the same for each reason. So a probe cannot learn
whether a member blocked the prober or turned DMs off.

## Where channels are enumerated

`Visibility.filter_all_channels/2` loads every channel row. DMs must not enter that query:

- It adds `kind != :direct` in SQL. So `visible_channels/1`, `list_channels/1`, the sidebar
  tree, the bot channel list, restore and reorder never see a DM.
- `Chat.list_direct_messages(scope)` reads the scope's DMs by participant column, newest
  activity first, with `peer` and unread counts.
- Search reads `visible_channels` ids plus the scope's DM ids.

## Events

- A new DM is announced as `{:direct_message_opened, channel}` on the two participants'
  `chat:user:<id>` topics, never on `chat:server`. That event makes each session and bot
  stream add the DM to its list and subscribe to its channel topic.
- Message, reaction, edit and delete events use the DM's channel topic, as in any channel.
- A block or unblock is sent to the blocker's user topic. It re-renders that account's rows of
  the blocked author.

## Alerts

`Tavern.Chat.Alerts` treats every DM message as a direct mention of the peer. The peer's
channel notification level and mute still apply. The title is `Ada sent you a message`.
@everyone and role mentions in a DM alert nobody: a DM grants no `mention_everyone`, and the
recipient filter already drops non-participants. The link is `/?dm=<id>&message=<id>`.

## Web

- **Address:** `/?dm=<channel id>`, with `&message=<id>` to open a message in place
  (docs/design/message-links.md). The DM opens in the channel pane. `message_path` and
  `Alerts.message_path` build the `dm` form for a `:direct` channel.
- **Sidebar:** a "Direct messages" section under the channel tree lists the member's DMs, with
  the peer's avatar and an unread badge.
- **Start:** a "Message" button on the profile card calls `open_direct_message` and opens the
  DM. A refusal shows "You can't message this member."
- **Header:** the peer's name. Under it, the privacy line: "Only the two of you can read this
  conversation." or "The server owner can read direct messages on this server."
- **Settings → Privacy:** the opt-out toggle, and the block list with Unblock.
- **Block:** a "Block" item on the profile card. In channels, a blocked author's message
  renders as one collapsed line, "Blocked message", with "Show" to open it.

## Owner reading

The owner's read is not visibility. A visibility grant would show every DM in search and in
lists, with no audit entry.

- Only with `owner_can_read`, the moderation panel has a "Direct messages" tab. It lists every
  DM with its participants and last activity.
- Opening one calls `Chat.read_direct_message_for_owner(scope, dm_id, cursor)`. It checks that
  the scope is the owner and the setting is `owner_can_read`, writes the audit entry
  `view_direct_message` (target: the DM, metadata: both participant ids), then returns a page
  of messages.
- The panel renders a read-only transcript. It does not use the chat pane, so it does not mark
  anything read or subscribe to the DM.

## Bot API

- `POST /api/v1/direct_messages` with `{"user_id"}` opens (or returns) the DM, with the same
  rules and the same `not_available` refusal (404).
- `GET /api/v1/direct_messages` lists the bot's DMs.
- The bot stream subscribes to the bot's user topic, and to each DM channel topic.
  `direct_message.opened` carries `{channel_id, user_id}`. Message events in a DM carry the
  DM's `channel_id`, as in a channel.
- Sending and listing messages use the channel message endpoints. Visibility answers for a DM
  as for a channel.

## Reports

No report flow is built yet (`message_reports` has a schema only). When it is built, a report
of a DM message shows moderators that one message. Moderators still cannot view the DM.

## Order of work

Each slice passes the gate before the next starts.

1. **Domain:** the migration, schema, `open_direct_message`, `list_direct_messages`, the
   Visibility clauses, the SQL exclusion, the user-topic event, search, blocks and opt-out.
   Leak tests: an administrator, the owner and a third member cannot view, list, search, alert
   on or receive events from a DM.
2. **Web:** the `dm` address, the sidebar section, the profile card button, the header and
   privacy line, and alerts.
3. **Settings:** the opt-out and block list, and blocked messages collapsed in channels.
4. **Owner reading** and its audit entry.
5. **Bot API.**

## Not in this design

- Group DMs.
- A rate limit on opening new DMs. The send limit applies to the messages, but a spammer could
  open many empty DMs. File it when slice 1 lands.
- Pins and threads in a DM.
