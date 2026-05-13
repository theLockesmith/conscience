#!/bin/bash
# Validate Learning Source - Blocks log_learning calls with unverified sources
# Hook: PreToolUse
# Purpose: Prevent fabricated learnings by requiring verified citations
#
# Validates:
# - file:/path -> file was read in this session
# - user_stated -> excerpt appears in recent user prompts
# - command:cmd -> command was executed in this session
# - verified -> always allowed (for directly verified facts)

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check mcp__rag__log_learning
[[ "$TOOL_NAME" != "mcp__rag__log_learning" ]] && exit 0

# Extract parameters
SOURCE=$(echo "$INPUT" | jq -r '.tool_input.source // empty')
SOURCE_EXCERPT=$(echo "$INPUT" | jq -r '.tool_input.source_excerpt // empty')

# Check required fields
if [[ -z "$SOURCE" ]]; then
    echo "BLOCKED: log_learning requires 'source' parameter." >&2
    echo "Use: file:/path, user_stated, command:cmd, or verified" >&2
    exit 2
fi

if [[ -z "$SOURCE_EXCERPT" ]]; then
    echo "BLOCKED: log_learning requires 'source_excerpt' parameter." >&2
    echo "Quote the relevant text from your source." >&2
    exit 2
fi

STATE_DIR="$HOME/.claude/session-state"
PWD_HASH=$(echo "$PWD" | md5sum | cut -c1-8)
SOURCES_FILE="$STATE_DIR/session-sources-${PWD_HASH}.jsonl"
PROMPTS_FILE="$STATE_DIR/user-prompts-${PWD_HASH}.jsonl"

# Validate based on source type
case "$SOURCE" in
    file:*)
        # Extract file path
        FILE_PATH="${SOURCE#file:}"

        # Check if file was read in this session
        if [[ ! -f "$SOURCES_FILE" ]]; then
            echo "BLOCKED: No files have been read in this session." >&2
            echo "Read the source file first, then log the learning." >&2
            exit 2
        fi

        if ! grep -q "\"path\":\"$FILE_PATH\"" "$SOURCES_FILE"; then
            # Try partial match (in case of path variations)
            BASENAME=$(basename "$FILE_PATH")
            if ! grep -q "$BASENAME" "$SOURCES_FILE"; then
                echo "BLOCKED: File '$FILE_PATH' was not read in this session." >&2
                echo "Read the source file first, then cite it." >&2
                exit 2
            fi
        fi
        ;;

    user_stated)
        # Check if excerpt appears in recent user prompts
        if [[ ! -f "$PROMPTS_FILE" ]]; then
            echo "BLOCKED: No user prompts recorded in this session." >&2
            exit 2
        fi

        # Normalize excerpt for matching (lowercase, remove extra whitespace)
        EXCERPT_NORMALIZED=$(echo "$SOURCE_EXCERPT" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | head -c 100)

        # Check if excerpt appears in any prompt
        FOUND=false
        while IFS= read -r line; do
            PROMPT=$(echo "$line" | jq -r '.prompt // empty' | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
            if [[ "$PROMPT" == *"$EXCERPT_NORMALIZED"* ]]; then
                FOUND=true
                break
            fi
        done < "$PROMPTS_FILE"

        if [[ "$FOUND" != "true" ]]; then
            echo "BLOCKED: Excerpt not found in recent user prompts." >&2
            echo "The user must have actually said this for 'user_stated' source." >&2
            exit 2
        fi
        ;;

    command:*)
        # Extract command
        CMD="${SOURCE#command:}"

        if [[ ! -f "$SOURCES_FILE" ]]; then
            echo "BLOCKED: No commands have been executed in this session." >&2
            exit 2
        fi

        # Check if command was executed (partial match)
        CMD_SHORT="${CMD:0:50}"
        if ! grep -q "\"type\":\"command\"" "$SOURCES_FILE" || ! grep -q "$CMD_SHORT" "$SOURCES_FILE"; then
            echo "BLOCKED: Command '$CMD_SHORT...' was not executed in this session." >&2
            echo "Run the command first, then cite the output." >&2
            exit 2
        fi
        ;;

    verified)
        # Always allowed - for directly observed/verified facts
        # This is the escape hatch for things like "I verified by checking the output"
        ;;

    *)
        echo "BLOCKED: Unknown source type '$SOURCE'." >&2
        echo "Use: file:/path, user_stated, command:cmd, or verified" >&2
        exit 2
        ;;
esac

exit 0
