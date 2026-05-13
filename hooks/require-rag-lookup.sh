#!/bin/bash
# Require RAG Lookup - Blocks infrastructure commands unless RAG was consulted first
# Hook: PreToolUse (matcher: Bash)
#
# PROBLEM: Claude guesses at paths, hostnames, and system locations instead of
# checking RAG documentation first. This wastes time and often targets the wrong system.
#
# SOLUTION: Block infrastructure commands unless mcp__rag__search_* was called
# in the current conversation turn.

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')

# Infrastructure command patterns that require RAG lookup first
INFRA_PATTERNS=(
    "^ssh "
    "^oc-"
    "^oc "
    "^kubectl "
    "openstack "
    "^psql "
    "virsh "
    "ceph "
    "rbd "
    "^docker exec"
    "ansible-playbook"
    "source.*openrc"
    "source.*rc.sh"
)

# Check if this is an infrastructure command
IS_INFRA=false
for pattern in "${INFRA_PATTERNS[@]}"; do
    if echo "$COMMAND_LOWER" | grep -qE "$pattern"; then
        IS_INFRA=true
        break
    fi
done

[[ "$IS_INFRA" != "true" ]] && exit 0

# Check if RAG was consulted in this conversation turn
# The rag-call-tracker.sh records RAG calls to a state file
RAG_STATE_FILE="$HOME/.claude/session-state/rag-calls-this-turn.txt"
TURN_MARKER="$HOME/.claude/session-state/current-turn-id.txt"

# Get current turn ID (set by track-user-prompts.sh on each UserPromptSubmit)
CURRENT_TURN=""
if [[ -f "$TURN_MARKER" ]]; then
    CURRENT_TURN=$(cat "$TURN_MARKER")
fi

# Check if RAG was called this turn
RAG_CALLED=false
if [[ -f "$RAG_STATE_FILE" && -n "$CURRENT_TURN" ]]; then
    if grep -q "^$CURRENT_TURN:" "$RAG_STATE_FILE" 2>/dev/null; then
        RAG_CALLED=true
    fi
fi

# Also check if session started with RAG context load (session-memory-loader)
# This counts as having RAG context for the first few commands
SESSION_START_FILE="$HOME/.claude/session-state/session-start-time.txt"
if [[ -f "$SESSION_START_FILE" ]]; then
    SESSION_START=$(cat "$SESSION_START_FILE")
    NOW=$(date +%s)
    SESSION_AGE=$((NOW - SESSION_START))
    # Within first 60 seconds of session, RAG context was just loaded
    if [[ $SESSION_AGE -lt 60 ]]; then
        RAG_CALLED=true
    fi
fi

if [[ "$RAG_CALLED" != "true" ]]; then
    echo "RAG LOOKUP REQUIRED: Infrastructure command detected but no RAG search this turn." >&2
    echo "" >&2
    echo "Before running: $COMMAND" >&2
    echo "" >&2
    echo "You MUST first call one of:" >&2
    echo "  - mcp__rag__search_docs" >&2
    echo "  - mcp__rag__search_instructions" >&2
    echo "  - mcp__rag__get_project_context" >&2
    echo "" >&2
    echo "To find: correct hostnames, paths, credentials locations, and procedures." >&2
    exit 2
fi

exit 0
