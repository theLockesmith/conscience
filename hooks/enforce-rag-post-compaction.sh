#!/bin/bash
# Enforce RAG Calls at Session Start
# Hook: Stop
#
# BLOCKS responses if:
# 1. Fresh session (has session_start) AND RAG not called within grace period
# 2. Post-compaction (has compaction_at) AND RAG not called within grace period
#
# This forces Claude to actually call RAG tools at session start,
# not just rely on the injected summary or ignore it entirely.

STATE_DIR="$HOME/.claude/session-state"
SESSION_ID=$(echo "$PWD" | md5sum | cut -c1-16)
STATE_FILE="$STATE_DIR/${SESSION_ID}.state"
LOG_FILE="$HOME/.claude/rag-enforcement.log"

# If no state file, allow (edge case - shouldn't happen)
if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# Read state
SESSION_START=$(grep "^session_start=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
COMPACTION_AT=$(grep "^compaction_at=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
RAG_CALLED=$(grep "^rag_called=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
ENFORCEMENT_CLEARED=$(grep "^enforcement_cleared=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)

# If enforcement was previously cleared, allow
if [[ "$ENFORCEMENT_CLEARED" == "1" ]]; then
    exit 0
fi

# If RAG was called, allow and mark enforcement as cleared
if [[ "$RAG_CALLED" == "1" ]]; then
    echo "enforcement_cleared=1" >> "$STATE_FILE"
    exit 0
fi

# Determine which enforcement mode we're in
ENFORCEMENT_MODE=""
REFERENCE_TIME=""

if [[ -n "$COMPACTION_AT" && "$COMPACTION_AT" != "" ]]; then
    ENFORCEMENT_MODE="compaction"
    REFERENCE_TIME="$COMPACTION_AT"
elif [[ -n "$SESSION_START" && "$SESSION_START" != "" ]]; then
    # Convert ISO timestamp to epoch for fresh sessions
    REFERENCE_TIME=$(date -d "$SESSION_START" +%s 2>/dev/null)
    if [[ -n "$REFERENCE_TIME" ]]; then
        ENFORCEMENT_MODE="fresh"
    fi
fi

# If no enforcement mode determined, allow
if [[ -z "$ENFORCEMENT_MODE" ]]; then
    exit 0
fi

# Calculate elapsed time
NOW=$(date +%s)
ELAPSED=$((NOW - REFERENCE_TIME))

# Grace periods:
# - Post-compaction: 5 minutes (Claude needs time to reload context)
# - Fresh session: 2 minutes (should call RAG immediately)
GRACE_PERIOD=300
if [[ "$ENFORCEMENT_MODE" == "fresh" ]]; then
    GRACE_PERIOD=120
fi

# After grace period, clear enforcement and allow
if [[ $ELAPSED -gt $GRACE_PERIOD ]]; then
    echo "enforcement_cleared=1" >> "$STATE_FILE"
    echo "[$(date -Iseconds)] Grace period expired ($ENFORCEMENT_MODE, ${ELAPSED}s), clearing enforcement" >> "$LOG_FILE"
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

echo "[$(date -Iseconds)] BLOCKED: $ENFORCEMENT_MODE session without RAG calls (attempt $BLOCK_COUNT, ${ELAPSED}s)" >> "$LOG_FILE"

# Circuit breaker: after 3 consecutive blocks, give up and allow
# This prevents infinite loops when Claude doesn't understand the instruction
if [[ $BLOCK_COUNT -ge 3 ]]; then
    echo "[$(date -Iseconds)] CIRCUIT BREAKER: Allowing after $BLOCK_COUNT failed attempts" >> "$LOG_FILE"
    rm -f "$BLOCK_COUNT_FILE"
    echo "enforcement_cleared=1" >> "$STATE_FILE"
    exit 0
fi

# Generate appropriate block message based on mode
if [[ "$ENFORCEMENT_MODE" == "compaction" ]]; then
    cat << 'EOF'
{"decision": "block", "reason": "STOP. DO NOT OUTPUT TEXT. Your context was compacted and you MUST call RAG tools FIRST. Your next action must be a TOOL CALL, not a text response. Call one of: mcp__rag__get_session_context, mcp__rag__search_learnings, or mcp__rag__search_decisions. DO NOT write any text until you have called at least one RAG tool."}
EOF
else
    cat << 'EOF'
{"decision": "block", "reason": "STOP. FRESH SESSION - LOAD RAG CONTEXT FIRST. You received an injected summary but you MUST call RAG tools to load full context. Call mcp__rag__search_learnings and mcp__rag__search_decisions for this project BEFORE responding. The summary is not enough - you need the details."}
EOF
fi
