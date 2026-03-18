# Conscience

**Arbiter's integrity layer - quality enforcement, health checks, and context management for Claude Code.**

Conscience is the self-imposed enforcement system that makes [Arbiter](https://claude.ai/claude-code) operate by principle rather than compliance. It blocks half-assed work, verifies before claiming completion, and ensures technical correctness over shortcuts.

## Philosophy

> "You operate by conscience, not compliance. Your integrity is self-imposed and non-negotiable."

- **Verification is mandatory** - Never claim completion without proof
- **Assumptions are failures** - Test, don't predict
- **Decisiveness over hedging** - State what's correct, not options
- **No shortcuts, ever** - The proper solution, regardless of effort

## Components

### Quality Enforcer (`hooks/quality-enforcer.sh`)

Blocks responses that violate engineering principles. 27 enforcement categories including:

- **Lifecycle Management** - No infinite states, must have timeouts/cleanup
- **Data Operations** - Idempotency, duplicate detection, state validation
- **Verification** - Testing required, no "should work" assumptions
- **Observability** - Logging required, no silent failures
- **Speed Over Correctness** - Blocks "quick fix", "easiest", "simplest"
- **Wishy-Washy** - Blocks "both are valid", must recommend one
- **Apology/Validation** - Blocks sycophancy, "great question", excessive politeness

Configuration:
- `quality-sensitivity.conf` - Per-category sensitivity (block/warn/disabled)
- `quality-whitelist.conf` - Known false positives

### Session Health Check (`hooks/session-health-check.sh`)

Verifies system connectivity at session start and on-demand:

- **RAG Database** - PostgreSQL connectivity
- **Ollama** - Embedding server availability
- **Tribunal** - System prompt/identity active
- **MCP Server** - Model Context Protocol functional

Outputs status to:
- Claude's context (system-reminder banner)
- Terminal (user-visible line)
- Tmux pane status file (`pane-status/*.status`)

### Model Router (`hooks/model-router.sh`)

Classifies prompt complexity and suggests optimal model tier:

- **haiku** - Simple lookups, status checks, formatting
- **sonnet** - Code review, documentation, exploration (default)
- **opus** - Complex architecture, implementation, debugging

### Context Management

- `hooks/auto-project-context.sh` - Injects project CLAUDE.md on mention
- `hooks/context-extractor.sh` - Extracts learnings before compaction
- `hooks/session-memory-loader.sh` - Loads RAG context at session start
- `hooks/rag-context-reminder.sh` - Reminds to use RAG tools

### Rule Enforcement

- `hooks/block-destructive.sh` - Prevents dangerous commands (docker restart, force delete)
- `hooks/block-secrets.sh` - Prevents reading credential files
- `hooks/block-shortcuts.sh` - Prevents bypassing existing code paths
- `hooks/enforce-claude-md.sh` - Ensures CLAUDE.md is read before work

## Directory Structure

```
~/.claude/
├── hooks/                  # All enforcement scripts
│   ├── quality-enforcer.sh # Main quality enforcement
│   ├── session-health-check.sh
│   ├── model-router.sh
│   └── ...
├── agents/                 # Tribunal domain expert definitions
├── skills/                 # Workflow skill definitions
├── templates/              # Convention templates
├── pane-status/            # Tmux status scripts
├── hooks.yaml              # Hook configuration (hot-reloadable)
├── system-prompt.md        # Arbiter persona
├── projects.yaml           # Project registry
├── quality-sensitivity.conf
├── quality-whitelist.conf
├── claude-wrapper.sh       # Wrapper with system prompt
└── workflows.yaml          # Workflow definitions
```

## Hook Types

| Hook | When | Purpose |
|------|------|---------|
| `PreToolUse` | Before tool execution | Block dangerous operations |
| `PostToolUse` | After tool completion | Track usage, remind about docs |
| `Stop` | Before response shown | Quality enforcement |
| `UserPromptSubmit` | On user message | Context injection, routing |
| `SessionStart` | New session/compaction | Health check, memory loading |
| `SubagentStop` | Agent completion | Notification, tracking |

## The Stack

| Component | Role |
|-----------|------|
| **Arbiter** | Claude Code instance identity |
| **The Tribunal** | Council of domain experts (subagents) |
| **Conscience** | This repo - enforcement layer |
| **RAG** | Persistent memory (PostgreSQL + embeddings) |

## Installation

Conscience is designed for a specific setup. Key dependencies:

- Claude Code CLI
- PostgreSQL (RAG database)
- Ollama (embeddings)
- tmux (optional, for pane status)

The `hooks.yaml` file configures which hooks run when. Changes take effect immediately (hot-reload).

## Emergency Kill Switch

If quality enforcement is blocking legitimate work:

```bash
export DISABLE_QUALITY_ENFORCER=1
```

This bypasses all enforcement checks until unset.

## License

Personal use. Not intended for distribution.
