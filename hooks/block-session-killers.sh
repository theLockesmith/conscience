#!/bin/bash
# Block Session Killers - Prevents commands that would log user out
# Hook: PreToolUse (matcher: Bash)
#
# NEVER destroy the user's desktop session. Period.

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')

# Session-killing patterns
BLOCKED_PATTERNS=(
    "loginctl terminate"
    "loginctl kill"
    "loginctl lock-session"
    "pkill -9 -u"
    "pkill -KILL -u"
    "killall -u"
    "systemctl restart gdm"
    "systemctl restart sddm"
    "systemctl restart display-manager"
    "systemctl stop gdm"
    "systemctl stop sddm"
    "systemctl stop display-manager"
    "qdbus org.kde.Shutdown"
    "qdbus org.kde.ksmserver"
    "dbus-send.*Shutdown"
    "gnome-session-quit"
    "plasmashell --replace"
    "kquitapp5 plasmashell"
)

# Check if user explicitly permitted this in the current prompt
LAST_PROMPT=$(cat "$HOME/.claude/session-state/last-prompt.txt" 2>/dev/null || echo "")
LAST_PROMPT_LOWER=$(echo "$LAST_PROMPT" | tr '[:upper:]' '[:lower:]')

# Permission phrases - user must explicitly say one of these
PERMISSION_GRANTED=false
if echo "$LAST_PROMPT_LOWER" | grep -qE "(log me out|kill my session|restart gdm|restart display|you can log|permission to log|go ahead and log|ok to log)"; then
    PERMISSION_GRANTED=true
fi

for pattern in "${BLOCKED_PATTERNS[@]}"; do
    if echo "$COMMAND_LOWER" | grep -qiE "$pattern"; then
        if [[ "$PERMISSION_GRANTED" == "true" ]]; then
            # User explicitly gave permission
            exit 0
        fi
        echo "SESSION KILLER BLOCKED: Command matches dangerous pattern '$pattern'" >&2
        echo "This command could log you out or destroy your desktop session." >&2
        echo "If you need this, explicitly say 'you can log me out' or similar." >&2
        exit 2
    fi
done

exit 0
