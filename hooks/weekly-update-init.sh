#!/bin/bash
# weekly-update-init.sh - SessionStart hook for weekly update management
#
# Ensures current week's update file exists and reminds to document work.
# Triggered on new sessions and after context compaction.

set -euo pipefail

REPORTS_DIR="$HOME/Nextcloud/OneDrive-Nextcloud/Reports/Status-Report"
TEMPLATE="$HOME/claude/empire/reports/template.md"

# Get current ISO week
YEAR=$(date +%Y)
WEEK=$(date +%V)
WEEK_FILE="$REPORTS_DIR/$YEAR-W$WEEK.md"

# Check if weekly update exists
if [[ ! -f "$WEEK_FILE" ]]; then
    # Create from template if it exists
    if [[ -f "$TEMPLATE" ]]; then
        # Get date range for this week
        # Monday of current week
        WEEK_START=$(date -d "$YEAR-01-01 +$(( (10#$WEEK - 1) * 7 )) days -$(date -d "$YEAR-01-01" +%u) days + 1 day" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
        WEEK_END=$(date -d "$WEEK_START + 6 days" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)

        # Create file from template with substitutions
        sed -e "s/{{WEEK}}/$WEEK/g" \
            -e "s/{{YEAR}}/$YEAR/g" \
            -e "s/{{WEEK_START}}/$WEEK_START/g" \
            -e "s/{{WEEK_END}}/$WEEK_END/g" \
            "$TEMPLATE" > "$WEEK_FILE"

        echo "<weekly-update-created>"
        echo "Created W$WEEK update: $WEEK_FILE"
        echo "Document work as you complete it."
        echo "</weekly-update-created>"
    else
        # No template, create minimal file
        cat > "$WEEK_FILE" << EOF
# Weekly Update - Week $WEEK, $YEAR

**Date Range:** $(date +%Y-%m-%d) to $(date -d "+6 days" +%Y-%m-%d)
**Project:** Empire Access

---

## Work Completed

<!-- Document work as you complete it -->

---
EOF
        echo "<weekly-update-created>"
        echo "Created W$WEEK update: $WEEK_FILE"
        echo "Document work as you complete it."
        echo "</weekly-update-created>"
    fi
else
    # File exists, just remind
    echo "<weekly-update-reminder>"
    echo "W$WEEK update: ~/Nextcloud/OneDrive-Nextcloud/Reports/Status-Report/$YEAR-W$WEEK.md"
    echo "Document work as you complete it."
    echo "</weekly-update-reminder>"
fi
