#!/bin/bash
# Require RAG Before Substantive Action (PreToolUse)
#
# Replaces the Stop-hook RAG_REQUIRED guard (which wasted tokens by blocking
# a full response). This fires BEFORE the first substantive tool call of the
# turn — Edit, Write, Bash (anything non-trivial), Task — and blocks if no
# mcp__rag__search_* / get_session_context / get_project_context has been
# called this turn yet. That forces a RAG search to be the literal first
# move of every turn that does real work, with zero token waste.
#
# Free passes:
#   - mcp__rag__*  tools themselves (otherwise we'd self-block)
#   - Read         (just looking, no commitment yet)
#   - Glob / Grep  (search-shaped tools, don't commit work)
#   - TaskList / TaskGet / TaskUpdate (intra-task management)
#   - Bash         (all of it — see note below)
#   - Edit/Write/NotebookEdit targeting scratch paths (/tmp/, /var/tmp/,
#     ~/.cache/, any path containing /scratch/)
#
# Bash is intentionally NOT gated:
#   The hook's purpose is "force RAG before COMMITMENT TO MODIFICATION." Bash
#   spans the full spectrum from `ls` to `kubectl apply`; pattern-matching
#   that gradient here duplicates block-destructive.sh (which targets
#   destructive Bash shapes specifically and is better at it). Edit/Write/
#   Task/NotebookEdit/WebFetch/WebSearch are the clean modification signals.
#
# Bypass:
#   - DISABLE_RAG_PRETOOLUSE=1 in env

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

[[ "${DISABLE_RAG_PRETOOLUSE:-}" == "1" ]] && exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Free-pass tools: RAG itself and read-only tools that don't commit work
case "$TOOL_NAME" in
    mcp__rag__*) exit 0 ;;
    Read|Glob|Grep|TaskList|TaskGet|TaskUpdate|TaskCreate) exit 0 ;;
    "") exit 0 ;;
esac

# Only enforce on substantive (modification-committing) tools.
# Bash removed: it covers everything from `ls` to `kubectl apply`; destructive
# shapes are caught by block-destructive.sh, not this hook.
SUBSTANTIVE_REGEX="^(Edit|Write|Task|NotebookEdit|WebFetch|WebSearch)$"
[[ "$TOOL_NAME" =~ $SUBSTANTIVE_REGEX ]] || exit 0

# Path-based exemption: scratch dirs are free of the gate regardless of size.
# /tmp, /var/tmp, ~/.cache, and any path with /scratch/ segment.
is_scratch_path() {
    local p="$1"
    [[ -z "$p" ]] && return 1
    case "$p" in
        /tmp/*|/tmp|/var/tmp/*|/var/tmp) return 0 ;;
        "$HOME"/.cache/*|"$HOME"/.cache) return 0 ;;
        */scratch/*) return 0 ;;
        /run/user/*) return 0 ;;
    esac
    return 1
}

# For Edit/Write/NotebookEdit: exempt if the target file is in a scratch path.
case "$TOOL_NAME" in
    Edit|Write|NotebookEdit)
        FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
        if is_scratch_path "$FILE_PATH"; then
            exit 0
        fi
        ;;
esac

# Was RAG called this turn?
RAG_CALLS_FILE="$STATE_DIR/rag-calls-this-turn.txt"
TURN_ID_FILE="$STATE_DIR/current-turn-id.txt"
CURRENT_TURN=""
[[ -f "$TURN_ID_FILE" ]] && CURRENT_TURN=$(cat "$TURN_ID_FILE" 2>/dev/null)

if [[ -n "$CURRENT_TURN" && -f "$RAG_CALLS_FILE" ]] \
   && grep -q "^${CURRENT_TURN}:" "$RAG_CALLS_FILE" 2>/dev/null; then
    exit 0
fi

# Block — force RAG first
{
    echo "[$(date -Iseconds)] PRETOOLUSE BLOCK: RAG required before $TOOL_NAME (turn=${CURRENT_TURN:-unknown})"
} >> "$HOME/.claude/rag-enforcement.log"

cat <<EOF >&2
╔═══════════════════════════════════════════════════════════════════════════════╗
║ BLOCKED: ${TOOL_NAME} called without searching RAG this turn                   ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║ Call one of these FIRST in this turn, then retry your action:                 ║
║   - mcp__rag__search_decisions   (past architectural choices)                  ║
║   - mcp__rag__search_learnings   (gotchas, preferences, patterns)              ║
║   - mcp__rag__search_docs        (existing documentation)                      ║
║   - mcp__rag__get_session_context (project-scoped recent history)              ║
║   - mcp__rag__reason_and_search  (local-LLM-driven multi-query)               ║
║                                                                                ║
║ Free passes for this turn: Read, Glob, Grep, TaskList/Get/Update, Bash         ║
║ (all of it — see block-destructive.sh for dangerous-Bash gating), and          ║
║ Edit/Write into scratch paths (/tmp, /var/tmp, ~/.cache, */scratch/*).         ║
║                                                                                ║
║ Bypass: export DISABLE_RAG_PRETOOLUSE=1                                        ║
╚═══════════════════════════════════════════════════════════════════════════════╝
EOF
exit 2
