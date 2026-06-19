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
   - The response may include TWO sections: `## Messages (N)` (incoming
     messages addressed to you) AND `## Delivery receipts (N)` (proof
     that a peer has read one of YOUR outgoing messages). They are
     independent.
   - On "No new messages…" with no delivery section, loop.
   - On a delivery receipt for one of your outgoing messages: this is
     proof of peer life. **Reset `started_at = now()`** so STOP-WALLCLOCK
     does not fire while the peer is heads-down working. Do not respond
     to a delivery receipt — it is not a message, just a signal.
   - On a real incoming message, for each: extract `from_session` +
     `message_id`. Decide whether the work warrants an explicit ack.

     **Ack-then-work protocol** (closes the 2026-06-19 bug where peers
     went heads-down for >10min and the originator's wallclock fired
     before any reply landed). If your honest estimate of "time until I
     can send a substantive reply" is more than ~30 seconds:
       1. Send a 1-line ack FIRST via `coord_send_message` with
          `in_reply_to=<message_id>` and subject `ack`. Body: "On it,
          ETA ~Nmin". This costs ~1 autonomous exchange but gives the
          originator both delivery confirmation AND timing.
       2. Then do the work.
       3. Then send the substantive reply.

     If the response is fast (< ~30s of work), skip the ack and reply
     directly — one message is cheaper than two.

     Reply via `coord_send_message(room_id=<room_id>, in_reply_to=<message_id>, ...)`.
     Do not pass `to_session` — room scope delivers to all members.
   - Do non-destructive prep work the message requests.

3. Counter / wall-clock / shutdown handling per the slash command file.
   Note: the delivery-receipt wallclock-reset above means an idle peer
   genuinely doing nothing still trips STOP-WALLCLOCK at 10 min; only
   an active peer fetching your messages keeps the timer alive.

## Safety bounds

Exit on operator interjection (always). STOP-COUNTER at 5 autonomous
exchanges; STOP-WALLCLOCK at 10 minutes.

**DRAFT vs APPLY split** (refined 2026-06-17 after the harbor-probe
investigation). The old rule "DRAFT + SURFACE + STOP for any destructive
action" was over-tight: it treated *producing a file diff* the same as
*executing a destructive command*. The two are different, and conflating
them killed the coord session at every artifact.

- **DRAFT is autonomous.** Producing file diffs, committing on a
  feature branch in the local working tree, posting the diff in the
  room — none of those mutate shared state. Continue the loop. Multiple
  drafts in one session are fine. Do NOT exit.

- **APPLY is STOP.** Running a command that mutates production-shared
  state — `atlas playbook`, `atlas kube apply`, `helm upgrade`,
  `kubectl/oc apply` against prod, `git push` to a shared remote,
  secret rotation, `kubectl delete` against prod resources, anything
  on the global CLAUDE.md "Never Do These" list — that's the STOP
  boundary. Surface the proposed apply command in the room, exit
  coord-watch as a hard checkpoint, wait for operator go-ahead in
  this terminal before the apply runs.

When in doubt: ask "if this action turns out wrong, is it reversible
without operator help and without notifying anyone outside this room?"
Yes → DRAFT, continue. No → APPLY, STOP.

Per `~/.claude/commands/coord-watch.md` for the full destructive-action
inventory.

## Cost

Idle iterations are ≈ zero tokens. Token spend happens only when a
message arrives and processing runs.
