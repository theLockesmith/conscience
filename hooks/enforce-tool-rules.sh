#!/bin/bash
# Subcommand Enforcement Hook
# Location: ~/.claude/hooks/enforce-tool-rules.sh
# Hook type: PreToolUse (for Bash tool)
#
# PURPOSE: Enforces allow/block rules from tools.yml for configured tools.
# This is the ENFORCEMENT layer - unknown-tool-detector handles DETECTION.
#
# Order of evaluation:
#   1. If command matches a 'block' pattern → BLOCKED
#   2. If command matches an 'allow' pattern → ALLOWED
#   3. If no match and tool is configured → BLOCKED (fail-closed)

set -uo pipefail

TOOLS_FILE="$HOME/.claude/security/tools.yml"
LOG_FILE="$HOME/.claude/security/audit.log"

# Read input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only apply to Bash tool
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

# Extract command
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

# Get the CLI tool being invoked
FIRST_WORD=$(echo "$COMMAND" | awk '{print $1}' | sed 's|.*/||')

# Check if tool has rules in tools.yml
[[ ! -f "$TOOLS_FILE" ]] && exit 0

# Check if this tool is configured
if ! grep -qE "^${FIRST_WORD}:" "$TOOLS_FILE" 2>/dev/null; then
    exit 0  # Not configured, let unknown-tool-detector handle it
fi

# Extract the subcommand (everything after the tool name)
SUBCOMMAND=$(echo "$COMMAND" | sed "s/^[^ ]* *//" | head -c 200)

# Parse allow/block patterns for this tool
# Simple YAML parsing - extract lines between "tool:" and next "tool:" or EOF
TOOL_CONFIG=$(awk "/^${FIRST_WORD}:/{found=1; next} /^[a-zA-Z]/{if(found) exit} found" "$TOOLS_FILE")

# Extract allow patterns
ALLOW_PATTERNS=$(echo "$TOOL_CONFIG" | awk '/allow:/{found=1; next} /block:|notes:/{found=0} found && /- "/{gsub(/.*- "|".*/, ""); print}')

# Extract block patterns
BLOCK_PATTERNS=$(echo "$TOOL_CONFIG" | awk '/block:/{found=1; next} /allow:|notes:/{found=0} found && /- "/{gsub(/.*- "|".*/, ""); print}')

# Check block patterns first (deny takes precedence)
while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if echo "$SUBCOMMAND" | grep -qE "$pattern" 2>/dev/null; then
        echo "[$(date -Iseconds)] BLOCKED: $FIRST_WORD subcommand matched block pattern '$pattern': $COMMAND" >> "$LOG_FILE"
        cat >&2 << EOF
BLOCKED: Command matches block rule in tools.yml

Tool: $FIRST_WORD
Command: ${COMMAND:0:100}
Blocked pattern: $pattern

This subcommand is explicitly blocked. If you need to run it,
edit the rules in: $TOOLS_FILE
EOF
        exit 2
    fi
done <<< "$BLOCK_PATTERNS"

# Check allow patterns
ALLOWED=false
while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if echo "$SUBCOMMAND" | grep -qE "$pattern" 2>/dev/null; then
        ALLOWED=true
        break
    fi
done <<< "$ALLOW_PATTERNS"

# Special case: if allow has ".*" (allow all), let it through
if echo "$ALLOW_PATTERNS" | grep -qE '^\.\*$'; then
    ALLOWED=true
fi

if [[ "$ALLOWED" == "false" && -n "$ALLOW_PATTERNS" ]]; then
    # Tool is configured with allow rules but command didn't match any
    echo "[$(date -Iseconds)] BLOCKED: $FIRST_WORD subcommand not in allow list: $COMMAND" >> "$LOG_FILE"
    cat >&2 << EOF
BLOCKED: Command not in allow list for $FIRST_WORD

Tool: $FIRST_WORD
Command: ${COMMAND:0:100}

This tool has explicit allow rules. Your command didn't match any.
Allowed patterns:
$(echo "$ALLOW_PATTERNS" | sed 's/^/  - /')

To allow this command, add a pattern to: $TOOLS_FILE
EOF
    exit 2
fi

# Allowed - log and proceed
echo "[$(date -Iseconds)] ALLOWED: $FIRST_WORD: ${COMMAND:0:100}" >> "$LOG_FILE"
exit 0
