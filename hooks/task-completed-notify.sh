#!/bin/bash
# Notification hook for completed background tasks
# Hook: TaskCompleted
# Sends desktop notification when background agents finish

set -uo pipefail

NOTIFY_SCRIPT="$HOME/.claude/scripts/notify.sh"

# Read hook input (JSON with task info)
HOOK_INPUT=$(cat)

# Extract task info
TASK_TYPE=$(echo "$HOOK_INPUT" | jq -r '.task_type // "task"' 2>/dev/null)
TASK_ID=$(echo "$HOOK_INPUT" | jq -r '.task_id // "unknown"' 2>/dev/null)
SUCCESS=$(echo "$HOOK_INPUT" | jq -r '.success // true' 2>/dev/null)
DURATION=$(echo "$HOOK_INPUT" | jq -r '.duration_ms // 0' 2>/dev/null)

# Format duration
if [[ "$DURATION" -gt 0 ]]; then
    DURATION_SEC=$((DURATION / 1000))
    if [[ $DURATION_SEC -gt 60 ]]; then
        DURATION_STR="$((DURATION_SEC / 60))m $((DURATION_SEC % 60))s"
    else
        DURATION_STR="${DURATION_SEC}s"
    fi
else
    DURATION_STR=""
fi

# Build notification
if [[ "$SUCCESS" == "true" ]]; then
    TITLE="Task Complete"
    TYPE="success"
    if [[ -n "$DURATION_STR" ]]; then
        MESSAGE="$TASK_TYPE finished in $DURATION_STR"
    else
        MESSAGE="$TASK_TYPE completed successfully"
    fi
else
    TITLE="Task Failed"
    TYPE="error"
    MESSAGE="$TASK_TYPE failed - check logs"
fi

# Send notification (but only for background tasks that took > 5 seconds)
# Don't spam for quick tasks
if [[ "$DURATION" -gt 5000 ]] || [[ "$SUCCESS" != "true" ]]; then
    "$NOTIFY_SCRIPT" "$TITLE" "$MESSAGE" "$TYPE" 8000
fi

exit 0
