#!/bin/bash
# Session Hygiene - Remind about context management
# Hook: Stop (runs after each response)
# Location: ~/.claude/hooks/session-hygiene.sh
#
# Monitors session health and suggests /compact when context is growing large.
# Uses transcript file size as a proxy for context usage.

set -uo pipefail

# Configuration
WARN_SIZE_KB=500        # Suggest compact at 500KB transcript
CRITICAL_SIZE_KB=1000   # Strongly suggest at 1MB
STATE_FILE="/tmp/claude-hygiene-$$"
CHECK_INTERVAL=10       # Only check every N responses

# Get current response count (or initialize)
RESPONSE_COUNT=0
if [[ -f "$STATE_FILE" ]]; then
    RESPONSE_COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi
RESPONSE_COUNT=$((RESPONSE_COUNT + 1))
echo "$RESPONSE_COUNT" > "$STATE_FILE"

# Only check every N responses to avoid spam
if [[ $((RESPONSE_COUNT % CHECK_INTERVAL)) -ne 0 ]]; then
    exit 0
fi

# Find the current session transcript
# Claude Code stores transcripts in ~/.claude/projects/<project-hash>/sessions/<session-id>/
TRANSCRIPT_DIR="$HOME/.claude/projects"
if [[ ! -d "$TRANSCRIPT_DIR" ]]; then
    exit 0
fi

# Find most recently modified transcript.json
TRANSCRIPT=$(find "$TRANSCRIPT_DIR" -name "transcript.json" -type f -mmin -60 2>/dev/null | head -1)

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
    exit 0
fi

# Get transcript size in KB
SIZE_KB=$(du -k "$TRANSCRIPT" 2>/dev/null | cut -f1)

if [[ -z "$SIZE_KB" ]]; then
    exit 0
fi

# Check thresholds and suggest action
if [[ $SIZE_KB -ge $CRITICAL_SIZE_KB ]]; then
    echo "<stop-hook>"
    echo "SESSION HEALTH WARNING: Context is very large (${SIZE_KB}KB)"
    echo ""
    echo "Consider:"
    echo "- /compact - Summarize and reduce context"
    echo "- /clear - Start fresh if switching tasks"
    echo "- /rename - Name this session before clearing"
    echo "</stop-hook>"
elif [[ $SIZE_KB -ge $WARN_SIZE_KB ]]; then
    echo "<stop-hook>"
    echo "SESSION NOTE: Context growing (${SIZE_KB}KB). Consider /compact soon."
    echo "</stop-hook>"
fi

exit 0
