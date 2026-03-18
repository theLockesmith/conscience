#!/bin/bash
# weekly-update-reminder.sh - PostToolUse hook for documentation reminders
#
# Triggers after significant work:
# - Git commits/pushes
# - Kubernetes deployments (oc apply, kubectl apply, oc rollout)
# - Creating 3+ documentation files OR 1 high-value doc (architecture/, CLAUDE.md)
#
# Only reminds once per session to avoid noise.

set -euo pipefail

# Session state file (unique per Claude session via PPID chain)
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
STATE_DIR="/tmp/claude-weekly-update"
STATE_FILE="$STATE_DIR/session-$SESSION_ID"
REPORTS_DIR="$HOME/Nextcloud/OneDrive-Nextcloud/Reports/Status-Report"

mkdir -p "$STATE_DIR"

# Initialize state if needed
if [[ ! -f "$STATE_FILE" ]]; then
    echo "doc_count=0" > "$STATE_FILE"
    echo "reminded=false" >> "$STATE_FILE"
fi

# Source current state
source "$STATE_FILE"

# If already reminded this session, exit silently
if [[ "$reminded" == "true" ]]; then
    exit 0
fi

# Read hook input (JSON with tool info)
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // .tool // ""' 2>/dev/null || echo "")
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // .input // ""' 2>/dev/null || echo "")

should_remind=false
trigger_reason=""

case "$TOOL_NAME" in
    Bash)
        # Extract command from input
        COMMAND=$(echo "$TOOL_INPUT" | jq -r '.command // ""' 2>/dev/null || echo "$TOOL_INPUT")

        # Check for significant commands
        if echo "$COMMAND" | grep -qE '^git\s+commit|^git\s+push'; then
            should_remind=true
            trigger_reason="git commit/push detected"
        elif echo "$COMMAND" | grep -qE '^oc\s+apply|^kubectl\s+apply|^oc\s+rollout'; then
            should_remind=true
            trigger_reason="deployment detected"
        fi
        ;;

    Write)
        # Extract file path
        FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""' 2>/dev/null || echo "")

        # Check if it's a new documentation file
        if [[ "$FILE_PATH" == *.md ]]; then
            # High-value locations trigger immediately
            if echo "$FILE_PATH" | grep -qE '/architecture/|/docs/|CLAUDE\.md$'; then
                should_remind=true
                trigger_reason="documentation file created: $FILE_PATH"
            else
                # Increment doc count for other .md files
                doc_count=$((doc_count + 1))
                echo "doc_count=$doc_count" > "$STATE_FILE"
                echo "reminded=$reminded" >> "$STATE_FILE"

                if [[ $doc_count -ge 3 ]]; then
                    should_remind=true
                    trigger_reason="$doc_count documentation files created this session"
                fi
            fi
        fi
        ;;
esac

if [[ "$should_remind" == "true" ]]; then
    # Mark as reminded
    echo "doc_count=$doc_count" > "$STATE_FILE"
    echo "reminded=true" >> "$STATE_FILE"

    # Get current week info
    YEAR=$(date +%Y)
    WEEK=$(date +%V)
    WEEK_FILE="$REPORTS_DIR/$YEAR-W$WEEK.md"

    echo "<weekly-update-reminder>"
    echo "Significant work completed ($trigger_reason)."
    echo ""
    echo "Update: ~/Nextcloud/OneDrive-Nextcloud/Reports/Status-Report/$YEAR-W$WEEK.md"
    echo "</weekly-update-reminder>"
fi
