#!/bin/bash
# Output Sanitizer with Redaction
# Location: ~/.claude/hooks/sanitize-output.sh
# Hook type: PostToolUse (for Bash tool)
#
# PURPOSE: Detects and REDACTS secret patterns in command output.
# Outputs sanitized version that Claude should use instead of raw output.
#
# The raw output still appears in Claude's context, but this hook
# outputs a clearly-marked sanitized version for Claude to prefer.

set -uo pipefail

AUDIT_LOG="$HOME/.claude/security/audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")"

# Read hook input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only apply to Bash PostToolUse
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

# Get the tool output (this is what the command returned)
TOOL_OUTPUT=$(echo "$INPUT" | jq -r '.tool_output // empty')
[[ -z "$TOOL_OUTPUT" ]] && exit 0

# Start with original output
SANITIZED="$TOOL_OUTPUT"
REDACTIONS=()

# Pattern 1: Strings after password/pass/pwd keywords
if echo "$SANITIZED" | grep -qiE '(password|passwd|pass|pwd)[[:space:]]*[=:][[:space:]]*[^[:space:]]+'; then
    SANITIZED=$(echo "$SANITIZED" | sed -E 's/(password|passwd|pass|pwd)([[:space:]]*[=:][[:space:]]*)([^[:space:]"'\'']+)/\1\2[REDACTED]/gi')
    REDACTIONS+=("PASSWORD_VALUE")
fi

# Pattern 2: AWS keys
if echo "$SANITIZED" | grep -qE 'AKIA[0-9A-Z]{16}'; then
    SANITIZED=$(echo "$SANITIZED" | sed -E 's/AKIA[0-9A-Z]{16}/[REDACTED-AWS-KEY]/g')
    REDACTIONS+=("AWS_KEY")
fi

# Pattern 3: GitHub tokens
if echo "$SANITIZED" | grep -qE 'ghp_[a-zA-Z0-9]{36}'; then
    SANITIZED=$(echo "$SANITIZED" | sed -E 's/ghp_[a-zA-Z0-9]{36}/[REDACTED-GITHUB-TOKEN]/g')
    REDACTIONS+=("GITHUB_TOKEN")
fi

# Pattern 4: GitLab tokens
if echo "$SANITIZED" | grep -qE 'glpat-[a-zA-Z0-9_-]{20,}'; then
    SANITIZED=$(echo "$SANITIZED" | sed -E 's/glpat-[a-zA-Z0-9_-]{20,}/[REDACTED-GITLAB-TOKEN]/g')
    REDACTIONS+=("GITLAB_TOKEN")
fi

# Pattern 5: Bearer/JWT tokens
if echo "$SANITIZED" | grep -qE 'Bearer[[:space:]]+ey[a-zA-Z0-9._-]{50,}'; then
    SANITIZED=$(echo "$SANITIZED" | sed -E 's/Bearer[[:space:]]+ey[a-zA-Z0-9._-]+/Bearer [REDACTED-JWT]/g')
    REDACTIONS+=("JWT_TOKEN")
fi

# Pattern 6: Private keys
if echo "$SANITIZED" | grep -qE -- '-----BEGIN.*PRIVATE KEY-----'; then
    # Redact everything between BEGIN and END
    SANITIZED=$(echo "$SANITIZED" | sed '/-----BEGIN.*PRIVATE KEY-----/,/-----END.*PRIVATE KEY-----/c\[PRIVATE KEY REDACTED]')
    REDACTIONS+=("PRIVATE_KEY")
fi

# Pattern 7: Generic API keys (sk-...)
if echo "$SANITIZED" | grep -qE 'sk-[a-zA-Z0-9]{32,}'; then
    SANITIZED=$(echo "$SANITIZED" | sed -E 's/sk-[a-zA-Z0-9]{32,}/[REDACTED-API-KEY]/g')
    REDACTIONS+=("API_KEY")
fi

# Pattern 8: High-entropy strings that look like passwords
# Match 8-32 char strings with mix of upper, lower, digit, special
# This is the pattern that would catch: NRU99J#0JKl(Q)Z
# Uses external perl script to avoid bash escaping issues
HOOK_DIR="$(dirname "$0")"
if [[ -x "$HOOK_DIR/redact-high-entropy.pl" ]]; then
    NEW_SANITIZED=$(echo "$SANITIZED" | "$HOOK_DIR/redact-high-entropy.pl" 2>/dev/null)
    if [[ "$NEW_SANITIZED" == *"REDACTED-CREDENTIAL"* ]]; then
        SANITIZED="$NEW_SANITIZED"
        REDACTIONS+=("HIGH_ENTROPY")
    fi
fi

# If we redacted anything, output the sanitized version
if [[ ${#REDACTIONS[@]} -gt 0 ]]; then
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // "unknown"' | head -c 100)
    echo "[$(date -Iseconds)] REDACTED: types=${REDACTIONS[*]} command=\"$COMMAND\"" >> "$AUDIT_LOG"

    cat << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  SANITIZED OUTPUT (use this instead of raw output above)
    Redacted: ${REDACTIONS[*]}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$SANITIZED

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
fi

exit 0
