#!/bin/bash
# Read Tracker Hook - Tracks files read in session, warns on re-reads
# Hook: PreToolUse (matcher: Read)
# Location: ~/.claude/hooks/read-tracker.sh
#
# Purpose: Reduce token waste from redundant file reads (up to 60-90% savings)

set -uo pipefail

INPUT=$(cat)

# Extract tool name and file path
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only process Read tool
if [[ "$TOOL_NAME" != "Read" ]]; then
    exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Use session-specific tracking file based on Claude session
# Fall back to PID-based if no session ID available
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
TRACK_DIR="/tmp/claude-read-tracker"
TRACK_FILE="$TRACK_DIR/session-$SESSION_ID"

mkdir -p "$TRACK_DIR"

# Normalize path for consistent tracking
NORM_PATH=$(realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# Check if file was already read
if grep -qF "$NORM_PATH" "$TRACK_FILE" 2>/dev/null; then
    # File was already read - inject a reminder but allow the read
    # We don't block because the file may have changed
    LAST_READ=$(grep -F "$NORM_PATH" "$TRACK_FILE" | tail -1 | cut -d'|' -f2)
    echo "<read-tracker-notice>"
    echo "NOTE: This file was previously read in this session."
    echo "Consider if you need the full content or just specific changes."
    echo "</read-tracker-notice>"
fi

# Record this read with timestamp
echo "$NORM_PATH|$(date +%H:%M:%S)" >> "$TRACK_FILE"

# Clean up old tracking files (older than 24h)
find "$TRACK_DIR" -name "session-*" -mtime +1 -delete 2>/dev/null || true

exit 0
