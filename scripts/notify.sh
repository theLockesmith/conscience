#!/bin/bash
# Smart Notifications for Claude Code
# Sends desktop notifications for AI task completion
#
# Usage:
#   notify.sh "Title" "Message" [type] [timeout_ms]
#   notify.sh "Build Complete" "All tests passed" success
#   notify.sh "AI Review" "Found 3 issues" warning
#   notify.sh "Error" "Task failed" error
#
# Types: success, warning, error, info (default)
# Timeout: milliseconds (default 5000)

set -uo pipefail

TITLE="${1:-Claude Code}"
MESSAGE="${2:-Task completed}"
TYPE="${3:-info}"
TIMEOUT="${4:-5000}"

# Map type to icon
case "$TYPE" in
    success)
        ICON="dialog-positive"
        URGENCY="normal"
        ;;
    warning)
        ICON="dialog-warning"
        URGENCY="normal"
        ;;
    error)
        ICON="dialog-error"
        URGENCY="critical"
        ;;
    *)
        ICON="dialog-information"
        URGENCY="low"
        ;;
esac

# Try different notification methods
if command -v notify-send &> /dev/null; then
    # Standard freedesktop notifications (works with KDE, GNOME, etc.)
    notify-send \
        --app-name="Claude Code" \
        --icon="$ICON" \
        --urgency="$URGENCY" \
        --expire-time="$TIMEOUT" \
        "$TITLE" \
        "$MESSAGE" 2>/dev/null
elif command -v kdialog &> /dev/null; then
    # KDE fallback
    kdialog --passivepopup "$MESSAGE" $((TIMEOUT / 1000)) --title "$TITLE" 2>/dev/null
elif command -v zenity &> /dev/null; then
    # GNOME fallback
    zenity --notification --text="$TITLE: $MESSAGE" 2>/dev/null &
fi

# Also log to a file for tracking
LOG_FILE="${HOME}/.claude/notifications.log"
echo "$(date -Iseconds) [$TYPE] $TITLE: $MESSAGE" >> "$LOG_FILE"

# Optional: play sound for important notifications
if [[ "$TYPE" == "error" ]] || [[ "$TYPE" == "success" ]]; then
    if command -v paplay &> /dev/null; then
        case "$TYPE" in
            success)
                paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
                ;;
            error)
                paplay /usr/share/sounds/freedesktop/stereo/dialog-error.oga 2>/dev/null &
                ;;
        esac
    fi
fi

exit 0
