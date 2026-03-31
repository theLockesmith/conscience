#!/bin/bash
# Output Sanitizer
# Location: ~/.claude/hooks/sanitize-output.sh
# Hook type: PostToolUse (for Bash tool)
#
# PURPOSE: Detects secret patterns in command output and warns.
# Can't actually redact (hooks see input, not output), but can:
#   1. Log potential exposures for audit
#   2. Inject warning into context
#
# NOTE: This is defense-in-depth. Primary protection is:
#   - Not reading secret files (block-secrets.sh)
#   - Using {{secret:...}} substitution (with-secrets.sh)

set -uo pipefail

CONFIG_FILE="$HOME/.claude/security/config.yml"

# Read hook input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only apply to Bash PostToolUse
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

# Get the tool output (this is what the command returned)
TOOL_OUTPUT=$(echo "$INPUT" | jq -r '.tool_output // empty')
[[ -z "$TOOL_OUTPUT" ]] && exit 0

# Secret patterns to detect
declare -A PATTERNS=(
    ["AWS_ACCESS_KEY"]="AKIA[0-9A-Z]{16}"
    ["AWS_SECRET_KEY"]="[A-Za-z0-9/+=]{40}"
    ["GITHUB_TOKEN"]="ghp_[a-zA-Z0-9]{36}"
    ["GITLAB_TOKEN"]="glpat-[a-zA-Z0-9_-]{20}"
    ["GENERIC_API_KEY"]="sk-[a-zA-Z0-9]{32,}"
    ["BEARER_TOKEN"]="Bearer\s+ey[a-zA-Z0-9._-]{50,}"
    ["PRIVATE_KEY_HEADER"]="-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----"
    ["BASE64_SECRET"]="[A-Za-z0-9+/]{64,}={0,2}"
)

FOUND_SECRETS=()

for pattern_name in "${!PATTERNS[@]}"; do
    pattern="${PATTERNS[$pattern_name]}"
    if echo "$TOOL_OUTPUT" | grep -qE "$pattern" 2>/dev/null; then
        FOUND_SECRETS+=("$pattern_name")
    fi
done

if [[ ${#FOUND_SECRETS[@]} -gt 0 ]]; then
    # Log the exposure (don't log the actual output!)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // "unknown"' | head -c 100)
    echo "[$(date -Iseconds)] SECRET_EXPOSURE: patterns=${FOUND_SECRETS[*]} command=\"$COMMAND\"" >> "$HOME/.claude/security/audit.log"

    # Inject warning into context
    cat << EOF
⚠️ WARNING: Command output may contain sensitive data.

Detected patterns: ${FOUND_SECRETS[*]}

If this was intentional (e.g., debugging), ignore this warning.
If unexpected, investigate how secrets ended up in output.

This output has been logged to: /tmp/claude-secret-exposures.log
EOF
fi

# Always allow - this is informational only
exit 0
