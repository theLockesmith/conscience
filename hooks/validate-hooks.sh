#!/bin/bash
# Hook Permission Validator
#
# Runs at session start to ensure all hook scripts have execute permission.
# Prevents "Permission denied" (exit 126) errors during hook execution.
#
# Rationale:
#   New hook scripts may be created without +x, causing silent failures.
#   This validator auto-fixes permissions and notifies the user.
#
# Usage: Called first in SessionStart hook chain
# Output: JSON with hook_result (always continues, never blocks)

set -uo pipefail

HOOK_DIR="$HOME/.claude/hooks"
LOG_FILE="$HOME/.claude/hook-validator.log"
FIXED_COUNT=0
FIXED_HOOKS=""

log() {
    echo "[$(date -Iseconds)] $1" >> "$LOG_FILE"
}

# Check all .sh files in hooks directory
for hook in "$HOOK_DIR"/*.sh; do
    [[ -f "$hook" ]] || continue

    if [[ ! -x "$hook" ]]; then
        chmod +x "$hook"
        FIXED_COUNT=$((FIXED_COUNT + 1))
        FIXED_HOOKS="${FIXED_HOOKS}$(basename "$hook"), "
        log "Fixed permissions: $hook"
    fi
done

# Also check subdirectories (skills, etc.)
for subdir in "$HOOK_DIR"/*/; do
    [[ -d "$subdir" ]] || continue

    for hook in "$subdir"*.sh; do
        [[ -f "$hook" ]] || continue

        if [[ ! -x "$hook" ]]; then
            chmod +x "$hook"
            FIXED_COUNT=$((FIXED_COUNT + 1))
            FIXED_HOOKS="${FIXED_HOOKS}$(basename "$hook"), "
            log "Fixed permissions: $hook"
        fi
    done
done

# Build response
if [[ $FIXED_COUNT -gt 0 ]]; then
    # Remove trailing comma and space
    FIXED_HOOKS="${FIXED_HOOKS%, }"

    # Send desktop notification
    notify-send -u normal "Hook Validator" "Fixed permissions on $FIXED_COUNT hook(s): $FIXED_HOOKS" 2>/dev/null || true

    log "Session start: Fixed $FIXED_COUNT hooks"

    # Return message to inject into session context
    cat << EOF
{
  "hook_result": "continue",
  "message": "<hook-validator>\nFixed execute permissions on $FIXED_COUNT hook(s): $FIXED_HOOKS\n</hook-validator>"
}
EOF
else
    # Silent success - no need to inject anything
    log "Session start: All hooks OK"
    echo '{"hook_result": "continue"}'
fi
