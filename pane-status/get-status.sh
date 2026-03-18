#!/bin/bash
# Get Arbiter health status for tmux status bar
# Usage: get-status.sh [pane_id]
#
# If pane_id not provided, uses $TMUX_PANE
# Returns compact status: "R✓ O✓ T✓ M✓ [OK]" or "no session"

PANE_DIR="$HOME/.claude/pane-status"
PANE_ID="${1:-${TMUX_PANE:-}}"
PANE_ID="${PANE_ID#%}"  # Remove % prefix

if [[ -z "$PANE_ID" ]]; then
    echo "?"
    exit 0
fi

STATUS_FILE="$PANE_DIR/${PANE_ID}.status"

if [[ -f "$STATUS_FILE" ]]; then
    # Check if file is recent (within last 30 minutes)
    file_age=$(($(date +%s) - $(stat -c %Y "$STATUS_FILE" 2>/dev/null || echo 0)))
    if [[ $file_age -gt 1800 ]]; then
        echo "stale"
    else
        head -1 "$STATUS_FILE"
    fi
fi
# No output for panes without Arbiter sessions (cleaner)
