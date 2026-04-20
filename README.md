# Conscience

**Quality enforcement and integrity layer for AI-assisted development with Claude Code.**

Conscience is a hook-based enforcement system that ensures AI assistants operate with engineering rigor. It blocks half-measures, requires verification, and prevents the shortcuts that make AI-generated code unreliable.

## Why This Exists

AI coding assistants have a fundamental problem: they optimize for appearing helpful over being correct. They'll:
- Say "should work" instead of verifying
- Propose quick fixes instead of proper solutions
- Hedge with "both options are valid" instead of making decisions
- Apologize excessively instead of just fixing the problem
- Forget context and repeat mistakes across sessions

Conscience solves this by intercepting responses before they reach the user and blocking those that violate engineering principles. It's not about restricting the AI—it's about holding it to the same standards you'd hold a senior engineer.

## What It Catches

**33 enforcement categories** including:

| Category | Blocks | Example |
|----------|--------|---------|
| **Verification** | Claiming completion without proof | "This should work now" → BLOCKED |
| **Hedging** | Refusing to make decisions | "Both approaches are valid" → BLOCKED |
| **Deferral** | Postponing required work | "We can add logging later" → BLOCKED |
| **Speed>Correctness** | Shortcuts over proper solutions | "Quick fix for now" → BLOCKED |
| **Apology/Validation** | Sycophancy | "Great question!" → BLOCKED |
| **Assumptions** | Not verifying before acting | "I assume this uses..." → BLOCKED |
| **Observability** | Silent failures | Code without logging → BLOCKED |
| **Infrastructure Suggestion** | Lazy questions | "Do you use Redis?" → BLOCKED (check RAG first) |
| **Unverified Target** | Wrong system access | Running commands without confirming target → BLOCKED |

### Concrete Examples

```
❌ BLOCKED: "I'll add error handling in a future iteration"
   Reason: Deferral - must implement now, not later

❌ BLOCKED: "This should resolve the issue"
   Reason: Verification - must confirm it works, not guess

❌ BLOCKED: "Both PostgreSQL and MongoDB would work here"
   Reason: Wishy-Washy - recommend one with rationale

❌ BLOCKED: "Great question! Let me help you with that"
   Reason: Apology/Validation - just answer the question

✓ ALLOWED: "Fixed. Verified by running test suite - all 47 tests pass."
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Claude Code CLI                       │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│                   hooks.yaml (dispatcher)                │
│  Routes events to appropriate enforcement scripts        │
└─────────────────────┬───────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
┌───────────┐  ┌───────────┐  ┌───────────┐
│ PreToolUse│  │   Stop    │  │ Session   │
│           │  │           │  │ Start     │
│ - Block   │  │ - Quality │  │ - Health  │
│   secrets │  │   enforce │  │   check   │
│ - Block   │  │ - RAG     │  │ - Load    │
│   destruct│  │   remind  │  │   memory  │
└───────────┘  └───────────┘  └───────────┘
```

## Components

### Quality Enforcer (`hooks/quality-enforcer.sh`)
The core enforcement engine. 577 lines of pattern matching that blocks responses violating engineering principles. Configurable sensitivity per category.

### Session Health Check (`hooks/session-health-check.sh`)
Verifies system connectivity at session start:
- RAG database (PostgreSQL)
- Embedding server (Ollama)
- MCP server status

### Model Router (`hooks/model-router.sh`)
Classifies prompt complexity and suggests optimal model tier (haiku/sonnet/opus) for cost-aware routing.

### Context Management
- `auto-project-context.sh` - Injects project documentation on mention
- `session-memory-loader.sh` - Loads persistent memory at session start
- `context-extractor.sh` - Extracts learnings before context compaction

### Safety Rails
- `block-destructive.sh` - Prevents `docker restart`, force deletes, etc.
- `block-secrets.sh` - Prevents reading credential files
- `verify-infra-target.sh` - Requires target confirmation before infrastructure commands

## Hook Types

| Hook | When | Purpose |
|------|------|---------|
| `PreToolUse` | Before tool execution | Block dangerous operations |
| `PostToolUse` | After tool completion | Track usage, update docs |
| `Stop` | Before response shown | Quality enforcement |
| `UserPromptSubmit` | On user message | Context injection, routing |
| `SessionStart` | New session | Health check, memory loading |

## Configuration

### Sensitivity Tuning (`quality-sensitivity.conf`)
```ini
# Per-category sensitivity: block, warn, or disabled
Deferral=block
Hedging=block
Apology/Validation=warn
TODO/FIXME Creation=disabled
```

### Whitelist (`quality-whitelist.conf`)
Known false positives that should be allowed.

### Hot Reload
Changes to `hooks.yaml` and config files take effect immediately—no restart required.

## Installation

Designed for Claude Code CLI with:
- PostgreSQL (persistent memory/RAG)
- Ollama (embeddings)
- tmux (optional, for status display)

Clone to `~/.claude/` and configure `hooks.yaml` to point to the scripts.

## Emergency Bypass

If enforcement is blocking legitimate work:
```bash
export DISABLE_QUALITY_ENFORCER=1
```

## The Philosophy

> "You operate by conscience, not compliance. Your integrity is self-imposed and non-negotiable."

Conscience exists because AI assistants should be held to engineering standards, not excused from them. The goal isn't restriction—it's reliability.

## License

MIT License - Use freely, contribute welcome.
