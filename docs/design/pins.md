# Pinned messages

A member pins a message to keep it at hand. Each channel and each thread has its own pins. The
Pins drawer lists them, and a line in the conversation tells everyone that a pin happened.

## Rules

- **Who pins.** A member with the `pin_messages` bit (bit 30) in the conversation, who is not
  timed out. In a locked or archived thread, only a member who manages the thread
  (`manage_messages` in its parent) may pin. `Visibility` decides `:pin_message` on a
  `%Message{}`. Unpinning takes the same rule. A member who cannot view the conversation gets
  `:not_found`.
- **What a pin is.** A message is pinned while its `pinned_at` is set. This is the only rule
  for the list and for the cap. Deleting a message clears `pinned_at`.
- **Cap.** A conversation holds at most 50 pins (`Pins.limit/0`). A pin over the cap is
  `{:error, :pin_limit}`. A per-conversation advisory lock serializes the count and the write,
  so two pins at the same moment cannot pass 50. The lock does not block sends or pins in
  other conversations.
- **Send limit.** The pin line counts toward the member's send limit (`SendLimit.admit/1`), so
  pin and unpin in a loop cannot post lines without bound. Over the limit, the pin is
  `{:error, {:rate_limited, seconds}}` and nothing changes.
- **Repeats.** Pinning a pinned message, or unpinning one that is not pinned, changes nothing
  and broadcasts nothing.
- **Pin line.** Each pin inserts a message with `kind: :pin`. Its author is the member who
  pinned, and its `reply_to_id` is the pinned message. Unpinning posts nothing.
  - The line does not go through `send_message`. Slowmode and `send_messages` do not apply,
    so a moderator can pin in a read-only channel.
  - The line's text belongs to the server. It takes no edit, no pin and no thread.
    `search_messages` skips it.
  - The line counts as a new message for unread state, as Discord's does. It is not counted as
    a `message.created` product event.

## Existing servers

Migration `20261124233151` copies `manage_messages` to `pin_messages` in every role and every
channel overwrite, in both the allow and the deny columns. So the members who moderate
messages can pin from the start. Its `down` clears bit 30 everywhere.

## Interface

- The message menu has Pin or Unpin for a member who may pin. A pinned row shows a "Pinned"
  mark.
- The pin line reads "*Name* pinned a message: *start of the text*. See all pins". The button
  opens the drawer.
- The channel header and the thread panel header each have a Pins button. The drawer lists the
  pins of that conversation, most recently pinned first. A member who may pin sees Unpin on
  each row.
- The drawer closes when its conversation stops being the open channel or thread, as after
  browser Back.
- An open drawer lists its pins again on each `:message_updated` or `:message_deleted` of its
  conversation, so it follows pins made in other sessions.
- The acting session hears no broadcast of its own write (`Topics.broadcast_channel/2` uses
  `broadcast_from`). So `Chat.pin_message/2` returns the pin line, and the session shows the
  line itself.

## Not built

- Jump from a pin to the message in the transcript. This needs the same work as jumping from
  a search result.
- Pins in the bot API.
- Deleting a pin line from the interface. The domain allows `manage_messages` to delete it,
  but the row has no menu.
