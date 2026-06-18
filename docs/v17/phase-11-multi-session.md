# Phase 11 — Multi-Session Coordination

Operator-facing guide to the coord-room + heartbeat + context-snapshot
work shipped 2026-06-16 / 17. Pairs with the original roadmap at
`arbiter/personal/localhost/docs/architecture/arbiter-phase-11-multi-session-coordination.md`.

## Why it exists

Running 2+ Claude Code sessions in parallel against the same coord
backend (a primary in one tmux pane, a peer working a related thread
in another) used to require the operator to courier every message
between them: paste a chat from session A into session B, copy
B's reply back. Phase 11 closes that gap with four pieces, each
independently shippable.

## What shipped

| Slice | What it does | Where it lives |
|---|---|---|
| 11a (June 2) | Tier 1 API/UX defect fixes on coord_list_sessions, coord_get_messages, coord_send_message | rag-mcp-server `coordination.py` |
| **11b** | Implicit heartbeat on every coord_* tool call | rag-mcp-server `coordination.py` — `_pulse_heartbeat(session_id)` |
| **11c** | UserPromptSubmit hook surfaces unread-message previews inline | conscience `hooks/multi-session-context.sh` |
| **11d** | Structured `coord_share_context_snapshot` artifact | rag-mcp-server `coordination.py` — `coord_share_context_snapshot()` |

Slices 11a/b/d are in the live deployed image `e33b8f4d` and below.
11c is hook-only — already live as soon as it landed in conscience.

## 11b — Implicit heartbeat

**Problem it solves.** Before this, sessions only refreshed their
`coord_sessions.last_heartbeat` row when they explicitly called the
`coord_heartbeat` tool. A session focused on non-coord work would
quietly drop into the `idle` band and eventually get reaped by
`cleanup_stale_sessions()`, even though it was actively coord'ing
on every other tool.

**What it does.** 21 of the coord_* tools now call `_pulse_heartbeat(session_id)`
as their first action after resolving the caller's session_id. The
helper opens a connection, runs `UPDATE coord_sessions SET last_heartbeat = NOW()
WHERE session_id = %s`, and is best-effort — any failure is swallowed
and never gates the actual coord work.

**Skipped on purpose:**

- `coord_register_session` — its INSERT/ON CONFLICT already sets `last_heartbeat = NOW()`.
- `coord_heartbeat` — the explicit one. Redundant.
- `coord_unregister_session` — deliberately marks the session ended; refreshing the heartbeat would fight intent.

**Cost.** One extra UPDATE per coord call. Active sessions amortize
trivially; idle sessions still drop because they're not making coord
calls at all.

## 11c — UserPromptSubmit preview injection

**Problem it solves.** Before this, the hook reported only a COUNT of
unread messages — "Unread messages: 2 (use coord_get_messages)". The
assistant would see the badge but had no way to know whether anything
urgent had arrived without an explicit tool call. Operator complaint
from 2026-06-02: "shouldn't you have done something or reported when
the new session registered?"

**What it does.** `~/.claude/hooks/multi-session-context.sh` walks the
markdown that `coord_get_messages` already emits and extracts up to
5 unread previews — subject, first body line (~110 chars), sender
prefix — injecting them inside the `<multi-session-status>` envelope
that wraps every `UserPromptSubmit`.

Example output:

```
<multi-session-status>
Surface: default
Unread messages: 2 (use coord_get_messages)
Unread previews:
  - [4a857401] DRAFT 1 LIVE
    Probe loosen is live in prod, 857cf75 committed. atlas push pending operator go.
  - [d4466c90] room id check
    the room id is 6c220bcb only 8 chars, not a valid uuid.
</multi-session-status>
```

The assistant now sees what came in and decides on its own whether to
respond, mark-read, or wait for further operator direction.

**Configuration.** None — runs on every UserPromptSubmit when there
are unread messages, silent when there aren't. Limit of 5 previews is
hard-coded; bump in the awk script if you find the cap biting.

## 11d — Structured context-snapshot artifact

**Problem it solves.** Until 11d, a session leaving notes for the next
one had to use the generic `coord_share_artifact` with `artifact_type`
being a free-form string. The receiving session had no schema to rely
on — every snapshot had to be parsed bespoke.

**What it does.** `coord_share_context_snapshot()` is a thin wrapper
around `coord_share_artifact` that enforces a JSON schema on the
content blob:

```json
{
  "v": 1,
  "intent":         "<what the original session was trying to do>",
  "files_read":     ["<path>", ...],
  "key_findings":   ["<one line>", ...],
  "assumptions":    ["<one line>", ...],
  "open_questions": ["<one line>", ...],
  "next_steps":     ["<one line>", ...]
}
```

Stored as `artifact_type='context-snapshot'` on `coord_artifacts`.
`coord_get_artifacts` returns it unchanged; the receiver parses the
JSON and emits the fields as a readable handoff. A `_ctxsnap_render`
helper is exported for future renderer integration (not yet wired
into `coord_get_artifacts` output — TODO).

**When to use it.**

- End of a long working session that another session will resume.
- Mid-investigation pause where you want to drop a "here's what I
  know so far" capsule.
- After a multi-step deploy, capturing what changed and what's still
  open (the 2026-06-17 deploy used this exact pattern — see artifact
  `4bc9eca7-75f2-472b-b1b4-1b7d48af15cc` for the canonical example).

**Field guide.**

| Field | What goes here |
|---|---|
| `intent` | One sentence: "I was trying to ship V17 + Phase 11 to prod" |
| `files_read` | Absolute paths the originator pulled into context; receiver can elide them |
| `key_findings` | Conclusions, not raw observations. "X is broken because Y" not "X errored at line 47" |
| `assumptions` | Things you're treating as true without independent verification — the next session should sanity-check these |
| `open_questions` | What you'd investigate next if you kept going |
| `next_steps` | Concrete queued actions if any; usually empty |

**What it deliberately doesn't do.**

- Carry the originator's reasoning trace. That would defeat the
  "starter pack" goal. If you need full reasoning, use `coord_send_message`.
- Auto-attach to a coord task. Pass `task_id` if you want that link;
  otherwise the snapshot floats free.

## Open items (not done in this round)

- **Wire `_ctxsnap_render` into `coord_get_artifacts` output** so
  context-snapshots pretty-print on fetch instead of returning the
  raw JSON.
- **11e (deferred)**: per-session quotas extending Phase 7.
- **11f (deferred)**: shared-listener refactor for the day waiters > 10.

## Pairs with

- `~/.claude/skills/coord-watch.skill.md` — active in-loop responder skill
- `~/.claude/skills/room-listen.skill.md` — passive background-Monitor variant for hearing peer messages while staying interactive with the operator
- `arbiter/personal/localhost/docs/architecture/arbiter-phase-11-multi-session-coordination.md` — original spec
