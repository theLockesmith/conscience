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

# If state file exists and has compaction flag, mark RAG as called
if [[ -f "$STATE_FILE" ]]; then
    # Update rag_called to 1
    sed -i 's/^rag_called=.*/rag_called=1/' "$STATE_FILE"
    echo "[$(date -Iseconds)] RAG tool called, enforcement cleared" >> "$HOME/.claude/compaction-tracker.log"
fi

# Create/touch verification file for infrastructure command enforcement
# This allows infrastructure commands after RAG verification
touch "$RAG_VERIFIED_FILE"
echo "[$(date -Iseconds)] RAG verified: $TOOL_NAME" >> "$HOME/.claude/infra-verification.log"

exit 0
