#!/bin/bash
# Enforce RAG Calls Post-Compaction
# Hook: Stop
#
# BLOCKS responses if:
# 1. Compaction happened (state file has compaction_at)
# 2. RAG tools were NOT called (rag_called=0)
#
# This forces Claude to actually call RAG tools after compaction,
# not just acknowledge the reminder and move on.

STATE_DIR="$HOME/.claude/session-state"
SESSION_ID=$(echo "$PWD" | md5sum | cut -c1-16)
STATE_FILE="$STATE_DIR/${SESSION_ID}.state"

# If no state file, allow (normal session, no compaction)
if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# Read state
COMPACTION_AT=$(grep "^compaction_at=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
RAG_CALLED=$(grep "^rag_called=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)

# If no compaction marker, allow
if [[ -z "$COMPACTION_AT" ]]; then
    exit 0
fi

# If RAG was called, allow
if [[ "$RAG_CALLED" == "1" ]]; then
    exit 0
fi

# Calculate time since compaction
NOW=$(date +%s)
ELAPSED=$((NOW - COMPACTION_AT))

# Grace period: first 5 minutes after compaction, enforce strictly
# After 5 minutes, assume user acknowledged and moved on
if [[ $ELAPSED -gt 300 ]]; then
    # Clear the compaction flag to stop blocking
    sed -i 's/^compaction_at=.*/compaction_at=/' "$STATE_FILE"
    exit 0
fi

# Track consecutive blocks for circuit breaker
BLOCK_COUNT_FILE="$STATE_DIR/${SESSION_ID}.block_count"
BLOCK_COUNT=0
if [[ -f "$BLOCK_COUNT_FILE" ]]; then
    BLOCK_COUNT=$(cat "$BLOCK_COUNT_FILE")
fi
BLOCK_COUNT=$((BLOCK_COUNT + 1))
echo "$BLOCK_COUNT" > "$BLOCK_COUNT_FILE"

echo "[$(date -Iseconds)] BLOCKED: Post-compaction response without RAG calls (attempt $BLOCK_COUNT)" >> "$HOME/.claude/compaction-tracker.log"

# Circuit breaker: after 5 consecutive blocks, give up and allow
# This prevents infinite loops when Claude doesn't understand the instruction
if [[ $BLOCK_COUNT -ge 5 ]]; then
    echo "[$(date -Iseconds)] CIRCUIT BREAKER: Allowing after $BLOCK_COUNT failed attempts" >> "$HOME/.claude/compaction-tracker.log"
    rm -f "$BLOCK_COUNT_FILE"
    sed -i 's/^compaction_at=.*/compaction_at=/' "$STATE_FILE"
    exit 0
fi

cat << 'EOF'
{"decision": "block", "reason": "STOP. DO NOT OUTPUT TEXT. Your context was compacted and you MUST call RAG tools FIRST. Your next action must be a TOOL CALL, not a text response. Call one of: mcp__rag__get_session_context, mcp__rag__search_learnings, or mcp__rag__search_decisions. DO NOT write any text until you have called at least one RAG tool."}
EOF
