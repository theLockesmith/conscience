#!/bin/bash
# Status line script that monitors context usage and sets a threshold flag
#
# Receives JSON via stdin, calculates context usage from cache tokens
# Writes threshold state to ~/.claude/context-threshold-state.json
# Also outputs a status line showing model and context usage
#
# Threshold: 85% (triggers documentation requirement at 15% remaining)

THRESHOLD=85
STATE_DIR="$HOME/.claude/session-state"

# Read JSON input
INPUT=$(cat)

# Extract session ID first for state file path
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

# Session-specific state file (avoids conflicts between concurrent sessions)
mkdir -p "$STATE_DIR" 2>/dev/null
STATE_FILE="$STATE_DIR/${SESSION_ID}.json"

# Extract values
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "Claude"')
CWD=$(echo "$INPUT" | jq -r '.cwd // "unknown"')
CONTEXT_SIZE=$(echo "$INPUT" | jq -r '.context_window.context_window_size // 200000')

# Calculate active context from cache tokens (this is what's actually in the context window)
CACHE_READ=$(echo "$INPUT" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
CACHE_CREATE=$(echo "$INPUT" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
CURRENT_INPUT=$(echo "$INPUT" | jq -r '.context_window.current_usage.input_tokens // 0')

# Active context = tokens currently in the context window
ACTIVE_TOKENS=$((CACHE_READ + CACHE_CREATE + CURRENT_INPUT))

# Calculate percentage (Claude Code doesn't provide used_percentage, so we calculate it)
if [[ "$CONTEXT_SIZE" -gt 0 ]]; then
    PCT=$((ACTIVE_TOKENS * 100 / CONTEXT_SIZE))
else
    PCT=0
fi

# Cap at 100
if [[ "$PCT" -gt 100 ]]; then
    PCT=100
fi

# Determine if we've crossed the threshold
THRESHOLD_CROSSED="false"
ACKNOWLEDGED="false"

# Read existing state if it exists
if [[ -f "$STATE_FILE" ]]; then
    EXISTING_SESSION=$(jq -r '.session_id // ""' "$STATE_FILE" 2>/dev/null)

    # If same session, check if already acknowledged
    if [[ "$EXISTING_SESSION" == "$SESSION_ID" ]]; then
        ACKNOWLEDGED=$(jq -r '.acknowledged // false' "$STATE_FILE" 2>/dev/null)
    fi
fi

# Check if threshold crossed
if [[ "$PCT" -ge "$THRESHOLD" ]]; then
    THRESHOLD_CROSSED="true"
fi

# Write state file
cat > "$STATE_FILE" << EOF
{
  "session_id": "$SESSION_ID",
  "cwd": "$CWD",
  "used_percentage": $PCT,
  "threshold": $THRESHOLD,
  "threshold_crossed": $THRESHOLD_CROSSED,
  "acknowledged": $ACKNOWLEDGED,
  "context_size": $CONTEXT_SIZE,
  "active_tokens": $ACTIVE_TOKENS,
  "updated_at": "$(date -Iseconds)"
}
EOF

# Build progress bar for status line
BAR_WIDTH=10
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))

# Build the bar string
BAR=""
for ((i=0; i<FILLED; i++)); do
    BAR="${BAR}#"
done
for ((i=0; i<EMPTY; i++)); do
    BAR="${BAR}-"
done

# Color coding: green < 70%, yellow 70-84%, red >= 85%
if [[ "$PCT" -ge 85 ]]; then
    COLOR="\033[31m"  # Red
    WARN=" [!]"
elif [[ "$PCT" -ge 70 ]]; then
    COLOR="\033[33m"  # Yellow
    WARN=""
else
    COLOR="\033[32m"  # Green
    WARN=""
fi
RESET="\033[0m"

# Output status line
echo -e "[$MODEL] ${COLOR}[$BAR]${RESET} ${PCT}%${WARN}"
