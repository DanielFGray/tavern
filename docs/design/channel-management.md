# Channel management

Status: built. Task: "Edit the channel list in place: edit mode in the sidebar, channel popover, soft delete".

## Rule

A member with server `manage_channels` edits the channel list in the sidebar. Each change is written at once and broadcast. There is no draft state and no save step. A deleted channel is soft-deleted: it keeps its row, its threads and its messages, and every read treats it as missing until a manager restores it.

## Where it lives

- `Tavern.Chat.Channels` holds the writes: `create_channel/2`, `update_channel/3`, `place_channel/4`, `delete_channel/2`, `restore_channel/2`, and the read `list_deleted_channels/1`.
- `Tavern.Chat.Visibility` decides every write and read. `view?/2` refuses a channel whose `deleted_at` is set, so a deleted channel, its threads and their messages are absent from scoped reads, the bot API, the sidebar, search and notifications, with `{:error, :not_found}` on writes.
- `TavernWeb.ServerLive.ChannelEditor` holds the edit-mode state and events. `TavernWeb.ServerComponents.ChannelEditor` renders the edit list, the ⚙ popover and the header topic field, with three colocated hooks (`.ChannelDrag`, `.InlineEdit`, `.AnchoredPopover`).
- `TavernWeb.ServerLive.ChannelPermissions` and `TavernWeb.ServerComponents.ChannelPermissions` hold the per-channel overwrites, shown in the popover. The Settings page has no channel controls.

## Edit mode

- A pencil in the sidebar's "Channels" header switches the list into edit mode. Only a member with `manage_channels` sees it. Done leaves the mode and saves nothing, because every change was already saved.
- Each row has a drag handle, an inline name field, ⚙ and 🗑. A category row has the same controls. Every category, empty ones too, ends with "+ add channel". A "No category" section holds the top-level channels and ends with "+ add channel". The list ends with "+ add category" and, when there are any, "Recently deleted".
- The name field saves on Enter or blur and reverts on Esc. A refused save also reverts it.
- "+ add channel" asks for a name and a kind: Text, Announcement, Forum or Voice. Stage is not offered, and `create_channel/2` refuses it (`Channel.managed_kinds/0`). Voice channels carry media over Cloudflare Realtime SFU instead of a message transcript by default (voice.md), but they also hold a message transcript beside the grid.
- The ⚙ popover holds name, topic, age gate, delete, and the Permissions section. Permissions show only to a member who can also list overwrites (`manage_roles`). On a screen narrower than 640px the popover is a bottom sheet. It is rendered outside the channel drawer, because the drawer's CSS transform would otherwise be the frame for its fixed position.
- A member with `manage_channels` edits the topic in place in the channel header.
- The phone channel drawer is the same sidebar, so edit mode and touch drag work there.

## Placement

- `place_channel(scope, id, parent_id, before_id)` moves a channel under `parent_id` (nil for the top level), before the sibling `before_id` (nil for the end). One transaction sets the parent and renumbers every sibling from 0, hidden and deleted siblings included, in their stored order. It broadcasts `:channels_reordered`.
- The client sends an anchor, not an index, because a manager does not see hidden siblings and an index would count them differently.
- A category is placed only at the top level. A channel is placed only under a category or at the top level. A thread is never placed.
- A drag uses pointer events with pointer capture, so mouse and touch share one path. The client never reorders the DOM; the server renders the new order.

## Slugs

- The slug is derived from the name on create (`Channel.slugify/1`) and is not edited by hand. A taken slug gets the next free suffix: `name`, `name-2`, `name-3`.
- A rename keeps the slug, so links and bookmarks stay valid.
- The unique index on `slug` covers only live rows (`WHERE deleted_at IS NULL`). A deleted channel's slug is therefore free for a new channel.
- Restore keeps the old slug if it is still free, and otherwise takes the next free suffix.
- Provisioning and fixtures may still pass an explicit slug and position to `create_channel/2`. The web events pass only name and kind.

## Delete and restore

- 🗑 sets `deleted_at` at once, with no dialog. "Recently deleted" in edit mode lists the deleted channels and categories the manager could see if they were live, newest first.
- Deleting a category soft-deletes only the category. Its channels, deleted ones too, move to the end of the top level in the same transaction.
- Restore clears `deleted_at` and puts the channel at the end of its category, or at the end of the top level if that category is gone. It broadcasts `:channel_updated`.
- Restore is its own decision, `:restore_channel`: server `manage_channels`, and the channel would be visible if it were live. A manager who could not see the channel cannot list or restore it.
- Hard purge is not built. A deleted channel's rows stay until a later task purges them.

## Authorization

Every write takes the channel-tree advisory lock, then decides in its transaction through `Visibility.authorize_write/3`, then locks the target row. A member without the right never sees the pencil, and every edit-mode event refuses with a flash.

## Known gaps

- No hard purge, and no retention window for deleted channels.
- The event log design still describes hard delete (event-log.md, "Deleted channels"). It must adopt soft delete before it is built.
