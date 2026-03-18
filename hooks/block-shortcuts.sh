#!/bin/bash
# Block Shortcuts Hook - Prevents Claude from taking shortcuts
# Hook: PreToolUse (Edit, Write)
#
# Detects patterns that indicate shortcuts:
# 1. Direct HTTP calls to Azure Function (bypassing logging)
# 2. One-off replay scripts that don't use existing code paths
# 3. Duplicate implementations of existing functionality
#
# This hook enforces: USE EXISTING CODE PATHS, DON'T REINVENT

set -uo pipefail

LOG_FILE="$HOME/.claude/shortcut-violations.log"

# Read hook input
INPUT=$(cat)

# Extract the code being written
CODE=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# If no code content, pass through
if [[ -z "$CODE" ]]; then
    exit 0
fi

# === SHORTCUT DETECTION PATTERNS ===

# Pattern 1: Direct Azure Function calls outside email_consumer
# If we're writing code that posts to AZURE_FUNCTION_URL and it's NOT in email_consumer.py
if echo "$CODE" | grep -qE '(AZURE_FUNCTION_URL|idi-receiver|zinier)' 2>/dev/null; then
    if [[ "$FILE_PATH" != *"email_consumer.py" ]]; then
        # Check if it's making an HTTP POST (the shortcut)
        if echo "$CODE" | grep -qE '(requests\.post|httpx\.post|aiohttp.*post|POST.*http)' 2>/dev/null; then
            REASON="SHORTCUT BLOCKED: Direct Azure Function call detected outside email_consumer.py. Use forward_to_azure_function() from email_consumer instead."
            echo "$(date -Iseconds) $REASON" >> "$LOG_FILE"
            echo "File: $FILE_PATH" >> "$LOG_FILE"
            echo "---" >> "$LOG_FILE"
            echo "{\"decision\": \"block\", \"reason\": \"$REASON\"}"
            exit 0
        fi
    fi
fi

# Pattern 2: Creating one-off replay scripts
# If file contains "replay" and makes direct API calls without using existing replay infrastructure
if echo "$FILE_PATH" | grep -qiE '(replay|backfill|resend|refire)' 2>/dev/null; then
    if echo "$CODE" | grep -qE '(requests\.post|httpx\.post|aiohttp)' 2>/dev/null; then
        # Check if it's using the database-api-service logging
        if ! echo "$CODE" | grep -qE '(record_api_forward|api_forwards|database-api)' 2>/dev/null; then
            REASON="SHORTCUT BLOCKED: Replay script detected without api_forwards logging. All replays MUST log to api_forwards table via database-api-service."
            echo "$(date -Iseconds) $REASON" >> "$LOG_FILE"
            echo "File: $FILE_PATH" >> "$LOG_FILE"
            echo "---" >> "$LOG_FILE"
            echo "{\"decision\": \"block\", \"reason\": \"$REASON\"}"
            exit 0
        fi
    fi
fi

# Pattern 3: Bulk operations without audit trail
if echo "$CODE" | grep -qE '(for.*in.*orders|while.*order|batch|bulk)' 2>/dev/null; then
    if echo "$CODE" | grep -qE '(requests\.post|httpx\.post)' 2>/dev/null; then
        if ! echo "$CODE" | grep -qE '(audit|log|record_api_forward|api_forwards)' 2>/dev/null; then
            REASON="SHORTCUT BLOCKED: Bulk operation without audit trail. All bulk operations MUST log to audit system."
            echo "$(date -Iseconds) $REASON" >> "$LOG_FILE"
            echo "File: $FILE_PATH" >> "$LOG_FILE"
            echo "---" >> "$LOG_FILE"
            echo "{\"decision\": \"block\", \"reason\": \"$REASON\"}"
            exit 0
        fi
    fi
fi

# Pattern 4: Direct database writes bypassing API
if echo "$CODE" | grep -qE '(INSERT INTO|UPDATE.*SET|DELETE FROM)' 2>/dev/null; then
    if [[ "$FILE_PATH" != *"database-api"* ]] && [[ "$FILE_PATH" != *"migration"* ]]; then
        REASON="SHORTCUT BLOCKED: Direct database write outside database-api-service. Use the API endpoints."
        echo "$(date -Iseconds) $REASON" >> "$LOG_FILE"
        echo "File: $FILE_PATH" >> "$LOG_FILE"
        echo "---" >> "$LOG_FILE"
        echo "{\"decision\": \"block\", \"reason\": \"$REASON\"}"
        exit 0
    fi
fi

# Pattern 5: Creating duplicate functionality
# Check for patterns that suggest reimplementing existing functions
EXISTING_FUNCTIONS=(
    "forward_to_azure_function:Direct Azure forwarding"
    "record_api_forward:API forward logging"
    "send_to_zinier:Zinier integration"
)

for func_check in "${EXISTING_FUNCTIONS[@]}"; do
    func_name="${func_check%%:*}"
    func_desc="${func_check##*:}"

    # If code looks like it's reimplementing this function
    if echo "$CODE" | grep -qE "(def|async def).*($func_name|${func_name//_/})" 2>/dev/null; then
        if [[ "$FILE_PATH" != *"email_consumer.py"* ]] && [[ "$FILE_PATH" != *"database-api"* ]]; then
            REASON="SHORTCUT BLOCKED: Appears to reimplement '$func_name' ($func_desc). Use the existing implementation."
            echo "$(date -Iseconds) $REASON" >> "$LOG_FILE"
            echo "File: $FILE_PATH" >> "$LOG_FILE"
            echo "---" >> "$LOG_FILE"
            echo "{\"decision\": \"block\", \"reason\": \"$REASON\"}"
            exit 0
        fi
    fi
done

# All checks passed
exit 0
