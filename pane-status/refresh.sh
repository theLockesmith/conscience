#!/bin/bash
# Refresh Arbiter health status for current pane
# Run this in any pane to update its status display

exec bash ~/.claude/hooks/session-health-check.sh >/dev/null 2>&1
