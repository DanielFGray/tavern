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

## `GET /api/v1/members/:user_id`

Returns `{"data": {"id", "username", "display_name", "bot", "system", "role_ids"}}`. `role_ids` holds the roles the member holds and the default role. The scope is checked first (`Chat.get_member/2` through `Visibility.member/1`): a user who is not an active, visible member (a stranger, a deactivated or deleted member, a malformed id) answers 404 `not_found`. A request without a bot token answers 401.
