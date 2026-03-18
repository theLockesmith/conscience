#!/bin/bash
# RAG Usage Tracker - Tracks when RAG memory tools are used
# Hook: PostToolUse (matcher: mcp__rag__)
#
# PURPOSE: Track when Claude uses RAG logging tools so quality-enforcer.sh
# knows whether memory was properly recorded.
#
# This hook updates session state when mcp__rag__log_decision or
# mcp__rag__log_learning is successfully called.

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
LOG_FILE="$HOME/.claude/rag-usage.log"
mkdir -p "$STATE_DIR"

# Read hook input
INPUT=$(cat)

# Extract tool name
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // .tool_input.tool_name // empty' 2>/dev/null)

# Only track RAG logging tools
if [[ "$TOOL_NAME" != *"log_decision"* ]] && [[ "$TOOL_NAME" != *"log_learning"* ]]; then
    exit 0
fi

# Check if tool succeeded (look for success indicators in result)
TOOL_RESULT=$(echo "$INPUT" | jq -r '.tool_result // .result // empty' 2>/dev/null)

if echo "$TOOL_RESULT" | grep -qiE 'logged successfully|Learning logged|Decision logged'; then
    # Get session ID
    SESSION_ID=$(echo "$PWD" | md5sum | cut -c1-16)
    SESSION_STATE="$STATE_DIR/${SESSION_ID}.state"

    # Update session state
    if [[ -f "$SESSION_STATE" ]]; then
        sed -i 's/rag_logged=.*/rag_logged=1/' "$SESSION_STATE"
    else
        echo "rag_logged=1" > "$SESSION_STATE"
    fi

    # Log the usage
    echo "[$(date -Iseconds)] RAG logging used: $TOOL_NAME (session: $SESSION_ID)" >> "$LOG_FILE"
fi

exit 0
