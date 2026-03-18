#!/bin/bash
# Pane Status Update - Ensures tmux pane has health status
# Hook: UserPromptSubmit
#
# Runs health check and writes pane status if:
# - No status file exists for current pane, OR
# - Status file is older than 10 minutes
#
# Fast path: skips if recent status exists

set -uo pipefail

PANE_DIR="$HOME/.claude/pane-status"
PANE_ID="${TMUX_PANE:-}"
PANE_ID="${PANE_ID#%}"

# No tmux = nothing to do
[[ -z "$PANE_ID" ]] && exit 0

mkdir -p "$PANE_DIR"
STATUS_FILE="$PANE_DIR/${PANE_ID}.status"

# Fast path: skip if status file exists and is recent (< 10 min)
if [[ -f "$STATUS_FILE" ]]; then
    file_age=$(($(date +%s) - $(stat -c %Y "$STATUS_FILE" 2>/dev/null || echo 0)))
    [[ $file_age -lt 600 ]] && exit 0
fi

# Run health check in BACKGROUND (non-blocking)
# --pane-only skips terminal output and banner generation, only updates status file
( bash "$HOME/.claude/hooks/session-health-check.sh" --pane-only </dev/null >/dev/null 2>&1 & )

exit 0
