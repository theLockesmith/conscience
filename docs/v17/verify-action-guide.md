# `verify_action` — Assistant's Guide

When to call `mcp__rag__verify_action` and what to put in the arguments.

## When to call it

Before running any infrastructure-mutating command that touches a
prod target. The PreToolUse hooks check `verify-actions-this-turn.jsonl`
and grant a pass if a `verify_action` call this turn declared the target.

The hooks have three pass-paths in increasing order of explicitness:

1. **Most lax:** user prompt mentioned the target (e.g., operator typed
   `roll rag-mcp`). This is fine for operator-directed actions.
2. **Medium:** a RAG search this turn returned results mentioning the
   target's token. This is fine when the assistant did its homework.
3. **Most explicit:** `verify_action` for the target. This is the
   formal declaration of "I'm about to do X to Y." Use this for any
   action you initiate without explicit operator naming AND for any
   action you want a clean audit trail on.

If you're unsure, call it. The cost is one MCP roundtrip; the benefit
is the action becomes auditable as your decision.

## Arguments

```python
mcp__rag__verify_action(
    intent="<free-form description of what you're about to do>",
    targets=["<type>:<value>", ...],
    company=None,   # optional, scope RAG search
)
```

### intent

Plain English. Be specific enough that, six months from now, an
operator reading `audit.log` would know what you were doing.

Good:
- `"roll rag-mcp after Phase 10 close-out shipped"`
- `"loosen harbor-core liveness probe to break 21-restarts/day flap"`
- `"chmod 0600 the new alice nsec file for phase 10 smoke"`

Bad:
- `"do thing"`
- `"helm upgrade"`
- (empty)

### targets

The exact `<type>:<value>` shape that `target-extract.sh` emits. The
hook compares the strings directly. Types:

| Type | Example |
|---|---|
| `helm_release` | `helm_release:rag-mcp` |
| `k8s_namespace` | `k8s_namespace:rag` |
| `k8s_context` | `k8s_context:atlantis` |
| `k8s_resource` | `k8s_resource:sts/dragonfly` |
| `systemd_unit` | `systemd_unit:rag-event-collector.service` |
| `docker_compose` | `docker_compose:/etc/docker-compose.yml` |
| `ssh_host` | `ssh_host:postgres-rw.db.aegis-hq.xyz` |
| `atlas_role` | `atlas_role:harbor-k8s` |
| `atlas_play` | `atlas_play:playbooks/site.yml` |
| `ansible_play` | `ansible_play:/home/forgemaster/Atlas/playbooks/foo.yml` |
| `file_path` | `file_path:/etc/sudoers` |

If the command touches multiple prod things, list ALL of them. The
hook's verify check is per-target — a verify_action for
`helm_release:rag-mcp` does NOT cover the namespace `k8s_namespace:rag`
the same upgrade implicitly touches. So:

```python
mcp__rag__verify_action(
    intent="roll rag-mcp after privacy mode shipped",
    targets=["helm_release:rag-mcp", "k8s_namespace:rag"],
)
```

### company

Optional RAG scope. Omit for cross-org search (most cases). Use it
when you know the target is empire-only or coldforge-only and want to
avoid noise from other orgs' learnings.

## Return shape

```json
{
  "verdict": "approve" | "warn" | "block",
  "intent": "<your intent>",
  "targets": ["...", "..."],
  "target_status": [
    {
      "target": "helm_release:rag-mcp",
      "evidence_count": 4,
      "evidence": [
        {"source": "learning", "text": "..."},
        {"source": "decision", "text": "..."},
        {"source": "doc", "text": "..."}
      ]
    }
  ],
  "contraindications": [
    {"target": "...", "source": "learning",
     "summary": "incident: harbor-core probe killed by tight timeout"}
  ],
  "next_steps": "...",
  "called_by": "<user_id or null>"
}
```

`verdict: warn` does NOT block the PreToolUse gate. It's an advisory.
The verdict's job is to give you (the assistant) the evidence to
decide whether to proceed; the gate's job is to enforce that you at
least *asked*. So:

- `approve` + no contraindications → run the command
- `warn` + contraindications → re-evaluate. Maybe surface to operator
  before running. The hook still lets you through if you want to
  override.
- `block` is reserved for future use (none of the current evidence
  sources actually return `block`). If you ever see one, surface to
  operator.

## What `verify_action` does NOT do

- It does not give you permission to run things. It only enables the
  hook's allow-path. Operator policies (CLAUDE.md "Never Do These")
  still apply.
- It does not detect mismatch between the targets you declared and the
  command you actually run. That's the hook's job: if you verify
  `helm_release:rag-mcp` and then `helm upgrade harbor`, the gate
  will block on `helm_release:harbor`.
- It does not skip RAG search. The pretooluse gate (Phase 6) still
  wants you to have searched RAG for the file/target you're editing.
  `verify_action` is one of the satisfying mechanisms, but searching
  RAG for the relevant context is generally better signal.

## See also

- `hook-architecture.md` — how the hook chain consumes this.
- `prod-target-manifest.md` — what counts as prod in the first place.
