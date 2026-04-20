#!/bin/bash
# Verify RAG Usage - WARN on EVERY Bash command
# Hook: PreToolUse (matcher: Bash)
#
# PURPOSE: Inject a warning for EVERY Bash command reminding Claude
# to use RAG FIRST. No exceptions. No excuses.
#
# The quality-enforcer.sh Stop hook will catch responses that ran
# commands without RAG verification.

set -uo pipefail

LOG_FILE="$HOME/.claude/infra-verification.log"

# Read hook input
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Exit if no command
[[ -z "$COMMAND" || "$COMMAND" == "null" ]] && exit 0

# =============================================================================
# MINIMAL WHITELIST - Only truly trivial commands skip warning
# =============================================================================

# Only skip for the most basic commands that need zero context
TRIVIAL_PATTERNS="^echo |^pwd$|^date$|^whoami$|^id$|^hostname$|^uname|^which |^type |--version$|--help$|-h$"

if echo "$COMMAND" | grep -qE "$TRIVIAL_PATTERNS"; then
    exit 0
fi

# =============================================================================
# Log and inject warning for EVERY command
# =============================================================================

echo "[$(date -Iseconds)] BASH COMMAND: $COMMAND" >> "$LOG_FILE"

# Inject reminder - this appears in Claude's context
cat << EOF
<system-reminder>
**BASH COMMAND DETECTED**
Command: $COMMAND

DID YOU SEARCH RAG FIRST?

Before running ANY command:
1. Use mcp__rag__search_docs to find relevant documentation
2. Use mcp__rag__search_learnings to check for gotchas
3. Use mcp__rag__search_decisions to check past decisions

RAG is your PRIMARY knowledge source. Filesystem commands are SECONDARY.
If you haven't searched RAG yet, STOP and search first.
</system-reminder>
EOF

# Allow the command but with warning injected
exit 0
