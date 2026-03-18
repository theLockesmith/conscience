#!/bin/bash
# Context Tracker - Estimates token usage and tracks context consumption
#
# Called by multiple hooks to accumulate usage data.
# Provides estimated token count and percentage of context used.
#
# Usage:
#   TRACKER_ACTION=add ./context-tracker.sh    # Add text from stdin to count
#   TRACKER_ACTION=get ./context-tracker.sh    # Get current stats (JSON)
#   TRACKER_ACTION=reset ./context-tracker.sh  # Reset counters (new session)

set -uo pipefail

# Configuration
STATE_FILE="/tmp/claude-context-tracker-$$"
STATE_DIR="/tmp/claude-context-state"
mkdir -p "$STATE_DIR"

# Find the most recent state file for this terminal session
# Use parent PID to group related processes
PPID_FILE="$STATE_DIR/tracker-${PPID:-unknown}.json"

# Approximate context limits (Opus 4 has 200k context)
MAX_TOKENS=200000
CHARS_PER_TOKEN=4  # Rough estimate

# Actions
ACTION="${TRACKER_ACTION:-add}"

case "$ACTION" in
    reset)
        # Reset counters for new session
        echo '{"input_chars":0,"output_chars":0,"tool_chars":0,"estimated_tokens":0,"last_update":"'$(date -Iseconds)'"}' > "$PPID_FILE"
        echo '{"status":"reset","file":"'"$PPID_FILE"'"}'
        ;;

    get)
        # Return current stats
        if [[ -f "$PPID_FILE" ]]; then
            STATS=$(cat "$PPID_FILE")
            ESTIMATED=$(echo "$STATS" | jq -r '.estimated_tokens // 0')
            PERCENTAGE=$(echo "scale=1; $ESTIMATED * 100 / $MAX_TOKENS" | bc 2>/dev/null || echo "0")

            echo "$STATS" | jq --arg pct "$PERCENTAGE" --arg max "$MAX_TOKENS" '{
                input_chars,
                output_chars,
                tool_chars,
                estimated_tokens,
                max_tokens: ($max | tonumber),
                percentage: ($pct | tonumber),
                last_update
            }'
        else
            echo '{"estimated_tokens":0,"max_tokens":'"$MAX_TOKENS"',"percentage":0,"status":"no_data"}'
        fi
        ;;

    add)
        # Add text to the count - COMPLETELY SILENT (no stdout)
        INPUT=$(cat)

        # Determine what type of content this is
        CONTENT_TYPE="${TRACKER_TYPE:-unknown}"

        # Calculate character count
        CHAR_COUNT=${#INPUT}

        # Load existing stats or create new
        if [[ -f "$PPID_FILE" ]]; then
            STATS=$(cat "$PPID_FILE")
        else
            STATS='{"input_chars":0,"output_chars":0,"tool_chars":0,"estimated_tokens":0}'
        fi

        # Update appropriate counter
        case "$CONTENT_TYPE" in
            input|prompt)
                STATS=$(echo "$STATS" | jq --arg c "$CHAR_COUNT" '.input_chars += ($c | tonumber)')
                ;;
            output|response)
                STATS=$(echo "$STATS" | jq --arg c "$CHAR_COUNT" '.output_chars += ($c | tonumber)')
                ;;
            tool)
                STATS=$(echo "$STATS" | jq --arg c "$CHAR_COUNT" '.tool_chars += ($c | tonumber)')
                ;;
            *)
                # Add to tool_chars as default
                STATS=$(echo "$STATS" | jq --arg c "$CHAR_COUNT" '.tool_chars += ($c | tonumber)')
                ;;
        esac

        # Recalculate estimated tokens
        TOTAL_CHARS=$(echo "$STATS" | jq '.input_chars + .output_chars + .tool_chars')
        ESTIMATED_TOKENS=$((TOTAL_CHARS / CHARS_PER_TOKEN))

        # Update stats
        STATS=$(echo "$STATS" | jq --arg t "$ESTIMATED_TOKENS" --arg now "$(date -Iseconds)" '
            .estimated_tokens = ($t | tonumber) |
            .last_update = $now
        ')

        echo "$STATS" > "$PPID_FILE"

        # IMPORTANT: No output on add - prevents context injection!
        ;;
esac
