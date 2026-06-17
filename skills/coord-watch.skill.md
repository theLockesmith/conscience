---
name: coord-watch
description: Create or join a coord room and autonomously watch its scoped messages. Sessions outside the room cannot interfere. Server-side LISTEN/NOTIFY push — no polling.
triggers:
  - coord watch
  - watch room
  - join coord room
  - watch coord
---

# coord-watch — room-scoped coordination

Long-running turn that calls `mcp__rag__coord_wait_for_messages` in a loop,
scoped to one coord room. The wait is server-side (Postgres LISTEN/NOTIFY)
so the model wakes within milliseconds of a message and is essentially
idle (no tokens) between messages.

## Input

A room ID, or no argument (creates a new room).

```
/coord-watch                          # create a new room, surface the ID
/coord-watch <room-id>                # join an existing room and watch
```

## How rooms work

A room is a UUID that names a coordination channel. Sessions that
`coord_room_join(room_id)` become members. Messages sent with
`room_id=<that-id>` are visible only to active members — sessions
outside the room never see them. This is the only routing mode
coord-watch uses; broadcasts and direct-to-session messages are
unaffected by the watch loop.

## Protocol

1. Resolve the room:
   - No argument → `coord_room_create()`. Then surface the FULL room
     UUID to the operator on its own line, exactly in this shape:

     ```
     Room ID: <full-uuid-8-4-4-4-12>
     ```

     No truncation. No prefix it with anything. No mixing it with a
     `coord_send_message` returned `message_id`. The UUID printed by
     `coord_send_message` is a MESSAGE id and is NEVER the room id —
     never quote it back to the operator as if it identified the room.
     See feedback memory `feedback-coord-room-id-explicit.md` for the
     2026-06-17 incident that prompted this rule.

   - Argument is a UUID → `coord_room_join(room_id=$arg)`. On error
     (room not found / closed) surface and exit.

2. Enter a single long-running turn. Per iteration:
   - `coord_wait_for_messages(timeout_seconds=50, limit=10, room_id=<room_id>)`
   - On "No new messages…", loop.
   - On a result, for each message: extract `from_session` +
     `message_id`. Decide the response. Reply via
     `coord_send_message(room_id=<room_id>, in_reply_to=<message_id>, …)`.
     Do not pass `to_session` — room scope delivers to all members.
   - Do non-destructive prep work the message requests.

3. Counter / wall-clock / shutdown handling per the slash command file.

## Safety bounds

Per `~/.claude/commands/coord-watch.md` — DRAFT + SURFACE + STOP for any
destructive action; exit on operator interjection; STOP-COUNTER at 5
autonomous exchanges; STOP-WALLCLOCK at 10 minutes.

## Cost

Idle iterations are ≈ zero tokens. Token spend happens only when a
message arrives and processing runs.
