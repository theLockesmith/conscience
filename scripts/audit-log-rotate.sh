#!/bin/bash
# Simple audit log rotation (no root required)
# Runs via cron or systemd timer
# Keeps 14 days of compressed logs

set -uo pipefail

AUDIT_LOG="$HOME/.claude/security/audit.log"
ARCHIVE_DIR="$HOME/.claude/security/audit-archive"
MAX_DAYS=14

mkdir -p "$ARCHIVE_DIR"

# Only rotate if log exists and has content
if [[ -s "$AUDIT_LOG" ]]; then
    DATE=$(date +%Y%m%d)
    ARCHIVE_FILE="$ARCHIVE_DIR/audit-$DATE.log"

    # Append to today's archive (in case we rotate multiple times)
    cat "$AUDIT_LOG" >> "$ARCHIVE_FILE"

    # Compress if not today's file
    find "$ARCHIVE_DIR" -name "audit-*.log" -mtime +0 -exec gzip -f {} \; 2>/dev/null

    # Clear the main log
    : > "$AUDIT_LOG"

    echo "Rotated audit log to $ARCHIVE_FILE"
fi

# Clean up old archives
find "$ARCHIVE_DIR" -name "audit-*.log.gz" -mtime +$MAX_DAYS -delete 2>/dev/null

echo "Audit log rotation complete. Archives in $ARCHIVE_DIR"
