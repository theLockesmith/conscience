#!/bin/bash
# Sensitive Path Restriction Hook
# Location: ~/.claude/hooks/restrict-sensitive-paths.sh
# Hook type: PreToolUse (for Edit, Write tools)
#
# PURPOSE: Blocks writes to sensitive paths like ~/.ssh, /etc, .env files

set -uo pipefail

LOG_FILE="$HOME/.claude/security/audit.log"

# Read input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only apply to Edit and Write tools
[[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]] && exit 0

# Extract file path
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ -z "$FILE_PATH" ]] && exit 0

# Normalize path (resolve ~, remove trailing slashes)
NORMALIZED_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# Blocked path patterns
declare -A BLOCKED_PATHS=(
    ["SSH_DIR"]="$HOME/.ssh"
    ["GPG_DIR"]="$HOME/.gnupg"
    ["ETC"]="/etc"
    ["SHADOW"]="/etc/shadow"
    ["PASSWD"]="/etc/passwd"
    ["SUDOERS"]="/etc/sudoers"
    ["SYSTEMD_SYSTEM"]="/etc/systemd/system"
    ["SYSTEMD_USER"]="$HOME/.config/systemd/user"
    ["KUBE_CONFIG"]="$HOME/.kube/config"
)

# Blocked file patterns (anywhere in path)
BLOCKED_PATTERNS=(
    "\.env$"
    "\.env\."
    "credentials\.json"
    "\.pem$"
    "\.key$"
    "id_rsa"
    "id_ed25519"
    "id_ecdsa"
    "\.netrc$"
    "\.npmrc$"
    "\.pypirc$"
    "secrets\.ya?ml$"
    "vault\.ya?ml$"
)

# Check blocked directories
for name in "${!BLOCKED_PATHS[@]}"; do
    blocked_path="${BLOCKED_PATHS[$name]}"
    if [[ "$NORMALIZED_PATH" == "$blocked_path"* ]]; then
        echo "[$(date -Iseconds)] BLOCKED: Write to sensitive path ($name): $FILE_PATH" >> "$LOG_FILE"
        cat >&2 << EOF
BLOCKED: Cannot write to sensitive path.

Path: $FILE_PATH
Category: $name
Reason: This directory contains security-critical files.

If you need to modify these files, do it manually outside Claude Code.
EOF
        exit 2
    fi
done

# Check blocked file patterns
BASENAME=$(basename "$FILE_PATH")
for pattern in "${BLOCKED_PATTERNS[@]}"; do
    if echo "$BASENAME" | grep -qE "$pattern" 2>/dev/null; then
        echo "[$(date -Iseconds)] BLOCKED: Write to sensitive file pattern ($pattern): $FILE_PATH" >> "$LOG_FILE"
        cat >&2 << EOF
BLOCKED: Cannot write to sensitive file type.

Path: $FILE_PATH
Pattern: $pattern
Reason: This file type typically contains secrets or credentials.

If you need to create/modify this file, do it manually outside Claude Code.
EOF
        exit 2
    fi
done

# Path is safe
exit 0
