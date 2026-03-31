#!/bin/bash
# Network Egress Warning Hook
# Location: ~/.claude/hooks/warn-network-egress.sh
# Hook type: PreToolUse (for Bash tool)
#
# PURPOSE: Warns when curl/wget access external URLs.
# Informational only - doesn't block (legitimate use cases exist).

set -uo pipefail

LOG_FILE="$HOME/.claude/security/audit.log"

# Read input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only apply to Bash tool
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

# Extract command
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

# Check if command involves network tools
if ! echo "$COMMAND" | grep -qE '\b(curl|wget|http|https://|nc |netcat |socat )\b'; then
    exit 0
fi

# Extract URLs from command
URLS=$(echo "$COMMAND" | grep -oE 'https?://[^ "'"'"']+' | head -5)

[[ -z "$URLS" ]] && exit 0

# Internal/safe domains (don't warn)
SAFE_DOMAINS="localhost|127\.0\.0\.1|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|\.local$|\.internal$|\.lan$|empacchosting\.com|coldforge\.net|coldforge\.app"

EXTERNAL_URLS=""
while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    # Extract domain from URL
    domain=$(echo "$url" | sed -E 's|https?://([^/:]+).*|\1|')
    if ! echo "$domain" | grep -qE "$SAFE_DOMAINS"; then
        EXTERNAL_URLS+="$url"$'\n'
    fi
done <<< "$URLS"

if [[ -n "$EXTERNAL_URLS" ]]; then
    echo "[$(date -Iseconds)] NETWORK: External URL access: $EXTERNAL_URLS" >> "$LOG_FILE"
    cat >&2 << EOF
[INFO] Network egress to external URL detected:
$(echo "$EXTERNAL_URLS" | sed 's/^/  /')
This is informational only. Proceeding with request.
EOF
fi

exit 0
