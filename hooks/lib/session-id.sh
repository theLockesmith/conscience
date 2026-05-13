#!/bin/bash
# V12 LLM Portability - Session ID Helper
#
# Source this file to get SESSION_ID variable that works with multiple LLM providers.
#
# Usage:
#   source "$(dirname "$0")/lib/session-id.sh"
#   echo "Session: $SESSION_ID"
#
# Supports:
#   - LLM_SESSION_ID (provider-agnostic, preferred)
#   - CLAUDE_SESSION_ID (Claude Code specific)
#   - Falls back to "unknown"

SESSION_ID="${LLM_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"

# Export for subprocesses
export SESSION_ID
