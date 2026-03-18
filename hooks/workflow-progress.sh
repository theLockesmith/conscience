#!/bin/bash
# Workflow Progress Tracker - Track and remind about workflow steps
# Hook: PostToolUse
# Location: ~/.claude/hooks/workflow-progress.sh
#
# Lightweight tracker that reminds about workflow steps after tool use.
# Does NOT auto-execute - just provides reminders.

set -uo pipefail

STATE_FILE="/tmp/claude-workflow-state"

# Read hook input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only check after significant tools
case "$TOOL_NAME" in
    Task|Edit|Write|Bash)
        # Continue to check
        ;;
    *)
        # Skip for read-only tools
        exit 0
        ;;
esac

# Check if we have an active workflow
if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# Read workflow state
WORKFLOW=$(jq -r '.workflow // empty' "$STATE_FILE" 2>/dev/null)
CURRENT_STEP=$(jq -r '.current_step // 0' "$STATE_FILE" 2>/dev/null)
STEPS=$(jq -r '.steps // []' "$STATE_FILE" 2>/dev/null)

if [[ -z "$WORKFLOW" ]]; then
    exit 0
fi

# Get next step info
TOTAL_STEPS=$(echo "$STEPS" | jq 'length')
NEXT_STEP=$((CURRENT_STEP + 1))

if [[ $NEXT_STEP -ge $TOTAL_STEPS ]]; then
    # Workflow complete
    echo "<post-tool-hook>"
    echo "WORKFLOW COMPLETE: $WORKFLOW"
    echo "All steps finished. Consider running a final review."
    echo "</post-tool-hook>"
    rm -f "$STATE_FILE"
    exit 0
fi

# Get next step name
NEXT_STEP_NAME=$(echo "$STEPS" | jq -r ".[$NEXT_STEP] // \"unknown\"")
CURRENT_STEP_NAME=$(echo "$STEPS" | jq -r ".[$CURRENT_STEP] // \"unknown\"")

# Output progress reminder (only occasionally to avoid spam)
# Use a counter to limit output frequency
REMINDER_COUNTER="/tmp/claude-workflow-reminder-$$"
COUNT=0
if [[ -f "$REMINDER_COUNTER" ]]; then
    COUNT=$(cat "$REMINDER_COUNTER")
fi
COUNT=$((COUNT + 1))
echo "$COUNT" > "$REMINDER_COUNTER"

# Only remind every 3 tool uses
if [[ $((COUNT % 3)) -eq 0 ]]; then
    echo "<post-tool-hook>"
    echo "WORKFLOW: $WORKFLOW (Step $((CURRENT_STEP + 1))/$TOTAL_STEPS)"
    echo "Current: $CURRENT_STEP_NAME"
    echo "Next: $NEXT_STEP_NAME"
    echo ""
    echo "Mark step complete: echo '{\"workflow\":\"$WORKFLOW\",\"current_step\":$NEXT_STEP,\"steps\":$STEPS}' > $STATE_FILE"
    echo "</post-tool-hook>"
fi

exit 0
