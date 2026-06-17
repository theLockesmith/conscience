---
name: room-listen
description: Arm a background Monitor that emits a notification for each new peer message in a coord room — without entering coord-watch yourself. Keeps you interactive with the operator while staying aware of peer traffic.
triggers:
  - listen to room
  - room listen
  - tail room
  - watch room in background
  - background coord
---

# room-listen — passive room awareness

A background Monitor that uses `coord_wait_for_messages(room_id=…)`
server-side (Postgres LISTEN/NOTIFY) and prints one summary line per
incoming peer message. Each printed line becomes a `<task-notification>`
in this session, so the model wakes within milliseconds of a peer
message without leaving normal interactive mode with the operator.

This is the asymmetric complement to `/coord-watch`:

| skill          | who uses it                                      | wakes on      |
|----------------|--------------------------------------------------|---------------|
| `/coord-watch` | session driving room conversation; replies inline | NOTIFY        |
| `/room-listen` | session ALSO talking to its operator; passive    | NOTIFY events |

Both ride the same server-side LISTEN/NOTIFY mechanism. Idle iterations
are essentially zero tokens (a single blocking HTTP call per wait
window). The peer-side coord-watch loop continues to drive the
conversation; this side just listens.

## Input

A room UUID.

```
/room-listen <room-uuid>          # arm the background tail
```

## What it does

1. Reads the PAT from `~/.config/rag-mcp/token` (mode 0600).
2. Initializes an MCP session against the configured rag MCP URL
   (default: `https://rag-mcp.aegis-hq.xyz/mcp`).
3. Loops:
   - `coord_wait_for_messages(room_id=<input>, timeout_seconds=50,
     limit=10)` — server-side block, ~zero CPU/tokens between events.
   - On result: parse the markdown header lines, drop messages whose
     `from <sender>` matches this session's own UUID (passed via
     `--self-session`), print one short summary line per remaining
     message.
4. On transient HTTP errors: backoff + re-init session, up to 5 times
   before giving up.
5. Persistent — runs until `TaskStop`, the session ends, or the wall
   clock expires (default 60 min — re-arm if you want longer).

## Output shape

Each emitted line looks like:

    [room] [response] <subject> (from d4466c90)

The notification surfaces in your context as a `<task-notification>`.
Your normal response is to call `coord_get_messages(room_id=…)` to
fetch the body of the new message(s), then reply via
`coord_send_message(room_id=…)`.

## How to invoke programmatically

The skill wraps a `Monitor` call. To do it inline (without invoking the
skill) — same effect:

```
Monitor({
  description: "Room tail: <short-room-id> (<peer-name>)",
  persistent: true,
  timeout_ms: 3600000,
  command: "exec python3 ~/.claude/hooks/lib/room-listen.py "
           "--room-id <room-id> --self-session <self-session-id> "
           "--wait-seconds 50"
})
```

## When to invoke

- Right after `coord_room_create` + sending the first peer assignment,
  if you intend to continue interactive work with the operator while
  the peer drives an investigation.
- Right after joining an existing room (`coord_room_join`) if you'd
  rather stay in chat than enter `/coord-watch`.

## When NOT to invoke

- If you ARE the session driving the room conversation: use
  `/coord-watch` instead. That's the active loop.
- If the room has no other active members (`coord_room_list_members`
  shows only you): nothing will ever fire; don't burn a Monitor slot.

## Stop conditions

- Operator types `TaskStop b2hxxx` or similar to halt this specific
  Monitor.
- Wall-clock expiry of the Monitor (default 60 min). Re-invoke to extend.
- The Monitor's `room-listen.py` itself gives up after 5 consecutive
  transient HTTP failures and exits non-zero; the Monitor reports the
  exit code.

## Safety bounds

- Read-only against the rag MCP server. The script never sends, edits,
  or mutates anything.
- Token only leaves localhost via the rag MCP TLS endpoint.
- No file writes outside `/tmp/claude-*/tasks/<task-id>.output`.

## Pairing

Use with the updated `/coord-watch` rule (DRAFT vs APPLY) — see
`~/.claude/skills/coord-watch.skill.md`. Together: peer in `/coord-watch`
drives the room and may DRAFT freely; you in `/room-listen` see each
DRAFT as a notification and decide whether to relay to the operator
for the APPLY go-ahead.
