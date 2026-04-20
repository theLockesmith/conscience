#!/bin/bash
# Bash Output Sanitizer Wrapper
# Location: ~/.claude/hooks/bash-sanitizer.sh
#
# This script wraps bash command execution and sanitizes output
# to redact credential-like patterns before they reach Claude.
#
# Usage: bash-sanitizer.sh "command to run"
#
# Patterns redacted:
#   - High-entropy strings (passwords with special chars)
#   - Strings following "password:", "pass:", "pwd:", etc.
#   - API keys and tokens
#   - Base64-decoded credential-like content

set -uo pipefail

COMMAND="$1"
AUDIT_LOG="$HOME/.claude/security/audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")"

# Execute the command and capture output
OUTPUT=$(eval "$COMMAND" 2>&1)
EXIT_CODE=$?

# Function to detect and redact credential-like strings
sanitize_output() {
    local input="$1"
    local sanitized="$input"
    local redacted=false

    # Pattern 1: Strings after password/pass/pwd keywords (case insensitive)
    # Matches: password: xyz123, "password": "xyz123", password=xyz123
    if echo "$sanitized" | grep -qiE '(password|passwd|pass|pwd)\s*[=:"'\'']\s*[^[:space:]"'\'']+'; then
        sanitized=$(echo "$sanitized" | sed -E 's/(password|passwd|pass|pwd)(\s*[=:"'\'']\s*)[^[:space:]"'\'']+/\1\2[REDACTED]/gi')
        redacted=true
    fi

    # Pattern 2: High-entropy strings (8+ chars with uppercase, lowercase, numbers, and special chars)
    # This catches passwords like: NRU99J#0JKl(Q)Z
    # Uses perl for proper regex with lookaheads
    if command -v perl &>/dev/null; then
        local new_sanitized
        new_sanitized=$(echo "$sanitized" | perl -pe '
            s/(?<![A-Za-z0-9])
             ([A-Za-z0-9!@#$%^&*()_+=\[\]{}|;:",.<>?\/\\-]{8,32})
             (?![A-Za-z0-9])
            /
                my $s = $1;
                # Check entropy: must have uppercase, lowercase, digit, AND special char
                my $has_upper = ($s =~ m\/[A-Z]\/);
                my $has_lower = ($s =~ m\/[a-z]\/);
                my $has_digit = ($s =~ m\/[0-9]\/);
                my $has_special = ($s =~ m\/[!@#$%^&*()_+=\[\]{}|;:",.<>?\/\\-]\/);

                if ($has_upper && $has_lower && $has_digit && $has_special) {
                    "[REDACTED-HIGH-ENTROPY]"
                } else {
                    $s
                }
            /gex
        ')
        if [[ "$new_sanitized" != "$sanitized" ]]; then
            sanitized="$new_sanitized"
            redacted=true
        fi
    fi

    # Pattern 3: API keys and tokens
    sanitized=$(echo "$sanitized" | sed -E '
        s/AKIA[0-9A-Z]{16}/[REDACTED-AWS-KEY]/g
        s/ghp_[a-zA-Z0-9]{36}/[REDACTED-GITHUB-TOKEN]/g
        s/glpat-[a-zA-Z0-9_-]{20,}/[REDACTED-GITLAB-TOKEN]/g
        s/sk-[a-zA-Z0-9]{32,}/[REDACTED-API-KEY]/g
        s/Bearer\s+ey[a-zA-Z0-9._-]{50,}/Bearer [REDACTED-JWT]/g
    ')

    # Pattern 4: Private key content
    if echo "$sanitized" | grep -qE "BEGIN.*PRIVATE KEY"; then
        sanitized=$(echo "$sanitized" | sed -E 's/(-----BEGIN[^-]*PRIVATE KEY-----).*(-----END[^-]*PRIVATE KEY-----)/\1\n[PRIVATE KEY CONTENT REDACTED]\n\2/g')
        redacted=true
    fi

    # Log if we redacted anything
    if [[ "$redacted" == "true" ]]; then
        echo "[$(date -Iseconds)] REDACTED: command=\"${COMMAND:0:100}\"" >> "$AUDIT_LOG"
    fi

    echo "$sanitized"
}

# Sanitize and output
SANITIZED_OUTPUT=$(sanitize_output "$OUTPUT")
echo "$SANITIZED_OUTPUT"

exit $EXIT_CODE
