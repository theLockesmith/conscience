#!/bin/bash
# Session Source Tracker - Records files/commands accessed in current session
# Hook: PostToolUse
# Purpose: Track sources so validate-learning-source.sh can verify citations
#
# Tracks:
# - Read tool: file paths accessed
# - Bash tool: commands executed (for command: citations)
# - User prompts (via separate UserPromptSubmit hook)

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
PWD_HASH=$(echo "$PWD" | md5sum | cut -c1-8)
SOURCES_FILE="$STATE_DIR/session-sources-${PWD_HASH}.jsonl"

mkdir -p "$STATE_DIR"

# Read input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_RESULT=$(echo "$INPUT" | jq -r '.tool_result // empty')

# Only track Read and Bash tools
case "$TOOL_NAME" in
    Read)
        # Extract file path from tool input
        FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
        if [[ -n "$FILE_PATH" ]]; then
            echo "{\"type\":\"file\",\"path\":\"$FILE_PATH\",\"timestamp\":\"$(date -Iseconds)\"}" >> "$SOURCES_FILE"
        fi
        ;;
    Bash)
        # Extract command from tool input
        COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
        if [[ -n "$COMMAND" ]]; then
            # Truncate long commands
            COMMAND_SHORT="${COMMAND:0:200}"
            # Escape for JSON
            COMMAND_ESCAPED=$(echo "$COMMAND_SHORT" | jq -Rs '.')
            echo "{\"type\":\"command\",\"command\":$COMMAND_ESCAPED,\"timestamp\":\"$(date -Iseconds)\"}" >> "$SOURCES_FILE"
        fi
        ;;
esac

# Clean up old entries (keep last 500 to prevent file growth)
if [[ -f "$SOURCES_FILE" ]]; then
    LINE_COUNT=$(wc -l < "$SOURCES_FILE")
    if (( LINE_COUNT > 500 )); then
        tail -n 500 "$SOURCES_FILE" > "$SOURCES_FILE.tmp"
        mv "$SOURCES_FILE.tmp" "$SOURCES_FILE"
    fi
fi

exit 0
