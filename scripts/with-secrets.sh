#!/bin/bash
# Execute command with secret substitution
# Location: ~/.claude/scripts/with-secrets.sh
#
# USAGE:
#   ~/.claude/scripts/with-secrets.sh 'curl -H "Authorization: Bearer {{secret:github_token}}" https://api.github.com/user'
#
# Secrets are stored in: ~/.claude/security/secrets.env
# Format: name=value (one per line)
#
# This script:
#   1. Reads the command with {{secret:name}} placeholders
#   2. Substitutes real values from secrets.env
#   3. Executes the command
#   4. The actual secrets never appear in Claude's conversation

set -uo pipefail

SECRETS_FILE="$HOME/.claude/security/secrets.env"

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 'command with {{secret:name}} placeholders'" >&2
    exit 1
fi

COMMAND="$1"

# Check for secret references
if ! echo "$COMMAND" | grep -qE '\{\{secret:[a-zA-Z0-9_]+\}\}'; then
    # No secrets, just execute
    eval "$COMMAND"
    exit $?
fi

# Secrets file must exist
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "ERROR: Secrets file not found: $SECRETS_FILE" >&2
    echo "Create it with: echo 'name=value' >> $SECRETS_FILE && chmod 600 $SECRETS_FILE" >&2
    exit 1
fi

# Check permissions
PERMS=$(stat -c %a "$SECRETS_FILE" 2>/dev/null)
if [[ "$PERMS" != "600" && "$PERMS" != "400" ]]; then
    echo "ERROR: Secrets file has unsafe permissions: $PERMS (must be 600 or 400)" >&2
    exit 1
fi

# Load secrets
declare -A SECRETS
while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    key=$(echo "$key" | xargs)
    # Don't trim value - might have intentional whitespace
    SECRETS["$key"]="$value"
done < "$SECRETS_FILE"

# Substitute secrets
SUBSTITUTED="$COMMAND"
while [[ "$SUBSTITUTED" =~ \{\{secret:([a-zA-Z0-9_]+)\}\} ]]; do
    SECRET_NAME="${BASH_REMATCH[1]}"
    FULL_MATCH="{{secret:$SECRET_NAME}}"

    if [[ -v "SECRETS[$SECRET_NAME]" ]]; then
        SECRET_VALUE="${SECRETS[$SECRET_NAME]}"
        SUBSTITUTED="${SUBSTITUTED//$FULL_MATCH/$SECRET_VALUE}"
    else
        echo "ERROR: Missing secret: $SECRET_NAME" >&2
        echo "Add to $SECRETS_FILE: $SECRET_NAME=value" >&2
        exit 1
    fi
done

# Log the substitution (secret names only, not values)
echo "[$(date -Iseconds)] Executed with secrets: $(echo "$COMMAND" | grep -oE '\{\{secret:[a-zA-Z0-9_]+\}\}' | tr '\n' ' ')" >> /tmp/claude-secret-executions.log

# Execute the substituted command
eval "$SUBSTITUTED"
