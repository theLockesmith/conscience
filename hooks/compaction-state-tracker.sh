#!/bin/bash
# Compaction State Tracker
# Hook: SessionStart (compact matcher)
#
# Sets a flag indicating compaction just happened.
# The enforce-rag-post-compaction.sh Stop hook reads this flag.

STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

# Generate session ID from PWD (same as session-memory-loader.sh)
SESSION_ID=$(echo "$PWD" | md5sum | cut -c1-16)
STATE_FILE="$STATE_DIR/${SESSION_ID}.state"

# Mark compaction happened, RAG not yet called
echo "compaction_at=$(date +%s)" > "$STATE_FILE"
echo "rag_called=0" >> "$STATE_FILE"
echo "project=$(basename "$PWD")" >> "$STATE_FILE"

# Log for debugging
echo "[$(date -Iseconds)] Compaction detected, state set: $STATE_FILE" >> "$HOME/.claude/compaction-tracker.log"

exit 0
