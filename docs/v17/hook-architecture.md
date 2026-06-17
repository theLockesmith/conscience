# V17 Hook Architecture

How Claude Code's `PreToolUse` and `PostToolUse` hooks are wired,
what order they run in, and how to add a new one without breaking the
V17 target-aware gates.

## Files involved

| File | Purpose |
|---|---|
| `~/.claude/hooks.yaml` | Hook registration. PreToolUse blocks are ordered top-to-bottom. |
| `~/.claude/hooks/dispatcher.sh` | Internal entrypoint Claude Code shells out to. |
| `~/.claude/hooks/lib/target-extract.sh` | V17 Phase 1 — parses commands into `TYPE:VALUE` lines. |
| `~/.claude/hooks/lib/prod-target-match.sh` | V17 Phase 2 manifest loader + matcher. Sourced by Phase 3/4/6 hooks. |
| `~/.claude/security/prod-targets.yml` | V17 Phase 2 — declarative manifest of "this counts as prod." |
| `~/.claude/security/audit.log` | All `[BLOCK]` and `[BYPASS-USED]` events from V17 hooks land here. Mode 0600. |
| `~/.claude/session-state/last-prompt.txt` | Cached most recent user prompt. Read by Phase 3 and the existing block-session-killers gate. |
| `~/.claude/session-state/rag-calls-this-turn.txt` | Per-call log of RAG tool invocations. Each call appends a QUERY line and a RESULT line (tab-separated). Phase 3 and Phase 6 read the RESULT lines. |
| `~/.claude/session-state/verify-actions-this-turn.jsonl` | Per-call log of `mcp__rag__verify_action`. Each line is `{intent, targets}`. Phase 3/4/6 grant pass to commands that intersect one of the listed targets. |
| `~/.claude/tests/v17/*.json` + `*.sh` | Fixture-based tests. `run.sh` covers target extraction; `run-hooks.sh` covers the gates end-to-end. |

## PreToolUse ordering (Bash matcher)

```yaml
PreToolUse:
  - matcher: "Bash"
    commands:
      - enforce-user-directives.sh         # operator commitments first
      - block-session-killers.sh           # don't kill the user's tmux
      - verify-infra-target.sh             # V17 Phase 3 (general gate)
      - block-destructive.sh               # V17 Phase 4 (yank fast-path) + literal-destructive
      - block-secrets.sh                   # don't echo secrets
      - unknown-tool-detector.sh
      - enforce-tool-rules.sh
      - warn-network-egress.sh
      - enforce-claude-md.sh
      - filter-verbose-output.sh
```

**Rationale for the ordering** (changed 2026-06-17 as part of V17 Phase 7):

1. **`verify-infra-target.sh` runs BEFORE `block-destructive.sh`** because
   the V17 Phase 3 gate is the general semantic enforcement — every
   prod target needs an explicit verify. Phase 4's shared-service-yank
   category in `block-destructive.sh` is the named-and-known-as-dangerous
   fast path; it short-circuits common cases but should not be the only
   thing that fires. Running Phase 3 first means the general gate is
   the authoritative answer; Phase 4 acts as defense in depth.

2. **`block-session-killers.sh` runs BEFORE both V17 gates** because no
   target-aware logic should be able to be talked into killing the user's
   shell session.

3. **`enforce-user-directives.sh` runs first.** Operator commitments
   recorded earlier in the session beat any later analysis.

## Edit/Write/Task/NotebookEdit matcher

```yaml
- matcher: "Edit|Write|Bash|Task|NotebookEdit|WebFetch|WebSearch"
  commands:
    - require-rag-pretooluse.sh             # V17 Phase 6 semantic check
```

Phase 6 runs alone for these tools — Bash gating is delegated to
`verify-infra-target.sh`/`block-destructive.sh` (the spec explicitly
removes Bash from Phase 6 to avoid double gating with overlapping but
differently-scoped rules).

## PostToolUse matcher

```yaml
PostToolUse:
  - matcher: "mcp__rag__"
    commands:
      - rag-call-tracker.sh
```

`rag-call-tracker.sh` is the bridge from "the assistant called a RAG
tool" to "the V17 gates can see what was searched for and what came
back." It appends `<turn>\t<tool>\tQUERY\t...` and `<turn>\t<tool>\tRESULT\t...`
to `rag-calls-this-turn.txt`. It also detects `mcp__rag__verify_action`
calls and writes `{intent, targets}` to `verify-actions-this-turn.jsonl`.

## Adding a new hook

1. Drop the script under `~/.claude/hooks/` with mode 0755.
2. Register it in `~/.claude/hooks.yaml` under the appropriate matcher.
3. Order it intentionally — see the "Rationale" above. If your hook is a
   target-aware gate, source `~/.claude/hooks/lib/target-extract.sh` and
   `~/.claude/hooks/lib/prod-target-match.sh` rather than re-implementing
   the manifest read.
4. Add fixture coverage to `~/.claude/tests/v17/fixtures-hooks.json`
   (positive and negative cases for any new BLOCK condition).
5. Run `bash ~/.claude/tests/v17/run-hooks.sh` to verify.

## Bypasses

| Envvar | Effect | Logged |
|---|---|---|
| `CLAUDE_PROD_OVERRIDE=<token>` | Skip Phase 3 + Phase 4 enforcement for the *value* matching `<token>` (e.g. `rag-mcp` to allow a helm upgrade of `rag-mcp`). Other prod targets in the same command are still checked. | `~/.claude/security/audit.log` `[BYPASS-USED]` / `[BYPASS-MATCHED]` |
| `DISABLE_RAG_PRETOOLUSE=1` | Skip Phase 6 entirely for the whole session. | none |

Bypasses exist for emergency unbreak-glass operations only. The audit
log lets us find them after the fact.

## See also

- `prod-target-manifest.md` — how to add a new prod target safely.
- `verify-action-guide.md` — assistant-facing: when to call `verify_action`.
