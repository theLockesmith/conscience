#!/bin/bash
# RAG Call Tracker
# Hook: PostToolUse (mcp__rag__ matcher)
#
# Marks that RAG tools were called, clearing enforcement blocks.
# Creates verification file used by verify-infra-target.sh to allow
# infrastructure commands after RAG verification.

STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"
SESSION_ID=$(echo "$PWD" | md5sum | cut -c1-16)
STATE_FILE="$STATE_DIR/${SESSION_ID}.state"
RAG_VERIFIED_FILE="$STATE_DIR/${SESSION_ID}.rag_verified"

# Read tool input to see which RAG tool was called
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only these tools actually load session context
CONTEXT_LOADING_TOOLS="search_learnings|search_decisions|get_session_context|get_project_context"

# If state file exists, check if this is a context-loading tool
if [[ -f "$STATE_FILE" ]]; then
    if [[ "$TOOL_NAME" =~ ($CONTEXT_LOADING_TOOLS) ]]; then
        # Update rag_called to 1 - only for context-loading tools
        sed -i 's/^rag_called=.*/rag_called=1/' "$STATE_FILE"
        echo "[$(date -Iseconds)] Context loaded via $TOOL_NAME, enforcement cleared" >> "$HOME/.claude/rag-enforcement.log"
    fi
fi

# Create/touch verification file for infrastructure command enforcement
# This allows infrastructure commands after RAG verification
touch "$RAG_VERIFIED_FILE"
echo "[$(date -Iseconds)] RAG verified: $TOOL_NAME" >> "$HOME/.claude/infra-verification.log"

# Record RAG call for current turn (used by require-rag-lookup.sh)
TURN_ID_FILE="$STATE_DIR/current-turn-id.txt"
RAG_TURNS_FILE="$STATE_DIR/rag-calls-this-turn.txt"
if [[ -f "$TURN_ID_FILE" ]]; then
    CURRENT_TURN=$(cat "$TURN_ID_FILE")
    echo "${CURRENT_TURN}:${TOOL_NAME}" >> "$RAG_TURNS_FILE"
fi

exit 0
