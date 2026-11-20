# Bot API: mentions and members

A bot learns whom a message mentions from the message, and which roles a person holds from the member endpoint. A bot that a role may summon (for example, a member with a configured role mentions it in a channel) reads both.

## Mentions on messages

Every serialized message (`Tavern.Bots.Serializer.serialize_message/1`: each message endpoint, and the `message.created`, `message.updated` and `message.deleted` events) carries:

```json
"mentions": {"user_ids": ["<uuid>"], "role_ids": ["<uuid>"], "everyone": false}
```

- `user_ids` are the `message_user_mentions` rows; `role_ids` are the `message_role_mentions` rows.
- `@everyone` and `@here` are stored as a mention of the default role. They set `everyone: true` and are left out of `role_ids`.
- The lists are preloaded by the scoped reads in `Tavern.Chat` (`@read_preloads`) and by the write path (`@message_preloads`), so the serializer runs no query.

A message whose author deleted their account keeps its `author_id`. Its `author` has `display_name` `"Deleted user"` and a `deleted-<hex>` `username` (see accounts.md).

## `GET /api/v1/messages/:message_id`

Returns `{"data": <serialized message>}`, the same shape as `message.created`. The read goes through `Tavern.Bots.get_message/2`, which calls `Chat.get_message/2` (scoped, with `@read_preloads`), so the serializer runs no query and the `mentions` lists are present.

- A message is visible when the bot can view its channel and every parent: a thread's parent channel, a channel's category. A message in a deleted channel is hidden with it.
- A thread's starter message lives in the thread's parent channel, so a bot that can view the parent reads the starter by id, even though the thread's own message list leaves it out.
- A hidden message, a missing one and a malformed id all answer 404 `not_found`. The response never says whether a hidden message exists.
- A request without a bot token answers 401.

## `GET /api/v1/members/:user_id`

Returns `{"data": {"id", "username", "display_name", "bot", "system", "role_ids"}}`. `role_ids` holds the roles the member holds, the Unverified role when the member holds it (docs/design/accounts.md), and the default role. The scope is checked first (`Chat.get_member/2` through `Visibility.member/1`): a user who is not an active, visible member (a stranger, a deactivated or deleted member, a malformed id) answers 404 `not_found`. A request without a bot token answers 401.

## Reactions

A bot sees who reacted through two events, and what a message holds through a summary.

- `reaction.added` and `reaction.removed` carry `{message_id, channel_id, user_id, emoji}`. A unicode emoji is its character (`"🛑"`). A custom emoji is `{"id": "<uuid>", "name": "<name>"}`. A reaction toggled off sends `reaction.removed` with the emoji it removed.
- `Tavern.Chat.toggle_reaction/3` broadcasts `{:reaction_added | :reaction_removed, message, reaction}` on the channel topic, after the `:message_updated` it has always sent. The bot stream subscribes only to channels the bot can view, so a reaction in any other channel is never sent. `ServerLive` ignores the two events.
- Every serialized message carries `reactions: [{"emoji", "count"}]`, in the order each emoji was first used, with no voter list. The emoji has the same shape as in the events. The list is empty for an unreacted message. It is read from the `reactions` preload of `@read_preloads` and `@message_preloads`, so the serializer runs no query.

## `GET /api/v1/channels/:id/messages`

Lists a page of messages, oldest first, with `after` and `before` cursors. A deleted message is not listed; its `message.deleted` event still arrives, and a cursor may name a deleted message. Read one deleted message by id with `GET /api/v1/messages/:message_id`, which still returns it.

## Rate limits

A bot is a member, so its messages count against the per-member send limit (rate-limits.md), as a person's do. A message send, a poll and the `send_message` command over the limit answer 429 `rate_limited` with `retry_after` seconds and a `Retry-After` header. Edits of one message have their own cap (`Tavern.Bots.EditLimit`) and answer the same way.

## Metadata limits

A message's `metadata` is capped on every write. `Tavern.Chat.Message.changeset/2` checks it, so the composer, the user API, the bot API, the `send_message` command and the poll and forum writes all meet the same bounds. Only the `entities` key is stored (`Tavern.Chat.Messages`), so the bounds apply to that list.

- **16,384 bytes encoded at most.** A mention entity (`{"type":"mention","id":<36-character uuid>,"label":<username, at most 24 characters>}`) encodes to about 100 bytes, so the cap holds about 160 entities. A 4,000-character body, the body limit, with a mention every 25 characters has 160 mentions. The cap admits every message that dense and refuses more.
- **Depth 3 at most.** The stored map is level 1, the `entities` array level 2, and each entity object level 3. An entity holds only scalars, so a value nested deeper is not an entity.

A write over either bound is `{:error, changeset}` with `metadata` in its errors, which the API answers as 422 `invalid_message`, with `details.metadata` holding `"is larger than 16384 bytes encoded"` or `"nests deeper than 3 levels"`. The composer shows the flash "This message has too many mentions to send. Remove some and send it again.", and keeps the draft. An edit checks the bounds only when it sends metadata. Rows written before the cap are not rechecked.
