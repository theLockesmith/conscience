#!/bin/bash
# escalation-tracker.sh - V11 Escalation Triggers
#
# Tracks repeated stop hook blocks and injects warnings when patterns repeat.
# Helps detect when a model (especially Sonnet) is struggling and not self-correcting.
#
# Triggers:
#   - Same block category fires 2+ times in session
#   - Total blocks exceed threshold (5+)
#
# Output:
#   - Injects warning into context when threshold exceeded
#   - Logs escalation events for analysis

set -euo pipefail

# V12: Source session ID helper for LLM portability
source "$(dirname "$0")/lib/session-id.sh"

# Configuration
STATE_DIR="$HOME/.claude/session-state"
LOG_FILE="$HOME/.claude/quality-enforcement.log"
ESCALATION_LOG="$HOME/.claude/escalation-events.log"
# SESSION_ID is set by lib/session-id.sh
REPEAT_THRESHOLD=2      # Same pattern blocked N times
TOTAL_THRESHOLD=5       # Total blocks in session

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Session-specific state file
ESCALATION_STATE="$STATE_DIR/${SESSION_ID}.escalation"

# Read stdin (response being validated) - not used but consumed
cat > /dev/null

# Initialize escalation state if needed
if [[ ! -f "$ESCALATION_STATE" ]]; then
    echo '{}' > "$ESCALATION_STATE"
fi

# Parse recent blocks from quality-enforcement.log for this session
# Look for BLOCKED entries from the last 30 minutes (approximate session window)
CUTOFF=$(date -d '30 minutes ago' -Iseconds 2>/dev/null || date -v-30M -Iseconds 2>/dev/null || echo "")

if [[ -z "$CUTOFF" || ! -f "$LOG_FILE" ]]; then
    # Can't determine cutoff or no log file, skip
    exit 0
fi

# Extract block categories from recent log entries
declare -A BLOCK_COUNTS
TOTAL_BLOCKS=0

while IFS= read -r line; do
    # Parse: [timestamp] BLOCKED: CATEGORY - 'pattern'
    if [[ "$line" =~ ^\[([^\]]+)\]\ BLOCKED:\ ([A-Z_]+)\ -\ \'(.+)\' ]]; then
        timestamp="${BASH_REMATCH[1]}"
        category="${BASH_REMATCH[2]}"

        # Check if timestamp is recent (simple string comparison works for ISO format)
        if [[ "$timestamp" > "$CUTOFF" ]]; then
            BLOCK_COUNTS[$category]=$(( ${BLOCK_COUNTS[$category]:-0} + 1 ))
            ((TOTAL_BLOCKS++))
        fi
    fi
done < "$LOG_FILE"

# Check for escalation triggers
ESCALATION_NEEDED=false
ESCALATION_REASONS=()

# Check for repeated patterns
for category in "${!BLOCK_COUNTS[@]}"; do
    count=${BLOCK_COUNTS[$category]}
    if [[ $count -ge $REPEAT_THRESHOLD ]]; then
        ESCALATION_NEEDED=true
        ESCALATION_REASONS+=("$category blocked $count times")
    fi
done

# Check total threshold
if [[ $TOTAL_BLOCKS -ge $TOTAL_THRESHOLD ]]; then
    ESCALATION_NEEDED=true
    ESCALATION_REASONS+=("Total $TOTAL_BLOCKS blocks in session")
fi

# If escalation triggered, inject warning
if $ESCALATION_NEEDED; then
    # Log the escalation event
    {
        echo "[$(date -Iseconds)] ESCALATION TRIGGERED"
        echo "  Session: $SESSION_ID"
        echo "  Reasons: ${ESCALATION_REASONS[*]}"
        echo "  Block counts: $(declare -p BLOCK_COUNTS 2>/dev/null | sed 's/declare -A BLOCK_COUNTS=//')"
        echo "---"
    } >> "$ESCALATION_LOG"

    # Check if we already warned this session (don't spam)
    WARNED_FILE="$STATE_DIR/${SESSION_ID}.escalation_warned"
    if [[ -f "$WARNED_FILE" ]]; then
        # Already warned, don't repeat
        exit 0
    fi

    # Mark as warned
    touch "$WARNED_FILE"

    # Inject warning into context
    cat << 'EOF'
<escalation-warning>
REPEATED QUALITY BLOCKS DETECTED

The same quality patterns have triggered multiple times this session:
EOF

    for reason in "${ESCALATION_REASONS[@]}"; do
        echo "  - $reason"
    done

    cat << 'EOF'

This suggests the model may be struggling with self-correction.

RECOMMENDED ACTIONS:
1. STOP and re-read the block reasons carefully
2. Address the ROOT CAUSE, not just the symptom
3. If using --sonnet, consider switching to --opus for this task
4. If patterns persist, the task may require deeper reasoning

The system is designed to detect when models aren't learning from feedback.
This warning will not repeat this session.
</escalation-warning>
EOF
fi
