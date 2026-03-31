#!/bin/bash
# Cleanup orphaned agent processes
# Usage: cleanup-orphaned-agents.sh [--dry-run]
#
# Kills:
# - Headless browsers (playwright/puppeteer)
# - Test runners that have been running too long
# - Processes from deleted directories

set -uo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Find processes from deleted /tmp directories
cleanup_deleted_tmp() {
    log "Checking for processes from deleted /tmp directories..."
    while IFS= read -r line; do
        pid=$(echo "$line" | awk '{print $2}')
        cmd=$(echo "$line" | cut -d' ' -f11-)

        if [[ "$cmd" == *"/tmp/"* ]]; then
            # Extract the /tmp path
            tmp_path=$(echo "$cmd" | grep -oP '/tmp/[^ ]+' | head -1)
            if [[ -n "$tmp_path" && ! -e "${tmp_path%%/*}/${tmp_path#*/}" ]]; then
                log "  Orphaned (deleted path): PID $pid - ${cmd:0:80}..."
                if [[ "$DRY_RUN" == "false" ]]; then
                    kill "$pid" 2>/dev/null && log "    Killed $pid"
                fi
            fi
        fi
    done < <(ps aux --no-headers | grep -E 'node|vite|vitest|playwright')
}

# Find headless browsers running > 30 minutes
cleanup_old_browsers() {
    log "Checking for old headless browsers (>30 min)..."
    while IFS= read -r pid; do
        if [[ -n "$pid" ]]; then
            # Get elapsed time
            etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
            cmd=$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-60)

            # Parse elapsed time (formats: MM:SS, HH:MM:SS, D-HH:MM:SS)
            if [[ "$etime" =~ ^[0-9]+-|^[0-9]+:[0-9]+:[0-9]+ ]]; then
                log "  Old browser: PID $pid ($etime) - $cmd..."
                if [[ "$DRY_RUN" == "false" ]]; then
                    kill "$pid" 2>/dev/null && log "    Killed $pid"
                fi
            fi
        fi
    done < <(pgrep -f 'firefox.*headless|chromium.*headless|webkit.*headless' 2>/dev/null)
}

# Find high-CPU processes from test tools
cleanup_runaway_tests() {
    log "Checking for high-CPU test processes (>80% for >5 min)..."
    ps aux --no-headers | awk '$3 > 80' | grep -E 'vitest|jest|playwright|puppeteer' | while read -r line; do
        pid=$(echo "$line" | awk '{print $2}')
        cpu=$(echo "$line" | awk '{print $3}')
        etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
        cmd=$(echo "$line" | cut -d' ' -f11- | cut -c1-60)

        # Check if running > 5 minutes
        if [[ "$etime" =~ ^[0-9]+:[0-9]+:[0-9]+ || "$etime" =~ ^[0-9]+- ]]; then
            log "  Runaway test: PID $pid (${cpu}% CPU, $etime) - $cmd..."
            if [[ "$DRY_RUN" == "false" ]]; then
                kill "$pid" 2>/dev/null && log "    Killed $pid"
            fi
        fi
    done
}

# Summary of current load
show_summary() {
    log "Current agent-related process summary:"
    echo
    echo "  Headless browsers: $(pgrep -c -f 'headless' 2>/dev/null || echo 0)"
    echo "  Node test runners: $(pgrep -c -f 'vitest|jest|playwright' 2>/dev/null || echo 0)"
    echo "  High CPU (>50%):   $(ps aux --no-headers | awk '$3 > 50' | wc -l)"
    echo
}

# Main
[[ "$DRY_RUN" == "true" ]] && log "DRY RUN - no processes will be killed"
echo

show_summary
cleanup_deleted_tmp
cleanup_old_browsers
cleanup_runaway_tests

echo
log "Cleanup complete."
show_summary
