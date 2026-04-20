#!/bin/bash
# Block commands and file reads that expose secrets
# Location: ~/.claude/hooks/block-secrets.sh
# Applies to: Bash tool (commands) AND Read tool (file paths)
#
# SUBSHELL PATTERN: Secret access is ALLOWED inside $(...) subshells where
# output goes to a consuming command (never returns to Claude). Example:
#   psql "postgres://user:$(oc get secret X -o jsonpath='{.data.pass}' | base64 -d)@host/db"
# This lets Claude USE secrets without VIEWING them.
#
# Uses exit 2 to block - Claude Code hooks block on non-zero exit

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Helper function to block
block() {
    local reason="$1"
    echo "BLOCKED: $reason" >&2
    exit 2
}

# ============================================
# HANDLE READ TOOL - Check file paths
# ============================================
if [[ "$TOOL_NAME" == "Read" ]]; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    [[ -z "$FILE_PATH" ]] && exit 0

    BASENAME=$(basename "$FILE_PATH")

    # Blocked file patterns
    BLOCKED_FILE_PATTERNS=(
        "\.env$"
        "\.env\."
        "^\.env"
        "secrets\.ya?ml$"
        "vault\.ya?ml$"
        "credentials\.json$"
        "\.pem$"
        "\.key$"
        "^id_rsa"
        "^id_ed25519"
        "^id_ecdsa"
        "\.netrc$"
        "\.npmrc$"
        "\.pypirc$"
        "\.docker/config\.json$"
        "kubeconfig$"
        "\.kube/config$"
        "macaroon"
    )

    # Check basename against blocked patterns
    for pattern in "${BLOCKED_FILE_PATTERNS[@]}"; do
        if echo "$BASENAME" | grep -qiE "$pattern" 2>/dev/null; then
            block "Cannot read sensitive file ($pattern). Path: $FILE_PATH"
        fi
    done

    # Block reading from sensitive directories
    BLOCKED_DIRS=(
        "$HOME/.ssh"
        "$HOME/.gnupg"
        "$HOME/.aws"
        "$HOME/.azure"
        "$HOME/.gcloud"
    )

    NORMALIZED_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
    for blocked_dir in "${BLOCKED_DIRS[@]}"; do
        if [[ "$NORMALIZED_PATH" == "$blocked_dir"* ]]; then
            block "Cannot read from sensitive directory: $blocked_dir"
        fi
    done

    exit 0
fi

# ============================================
# HANDLE BASH TOOL - Check commands
# ============================================
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

# ============================================
# KUBERNETES/OPENSHIFT SECRET ACCESS
# ============================================

# K8s secret access - block standalone, allow in subshells (like atlas vault pattern)
if echo "$COMMAND" | grep -qE '(kubectl|oc).*get.*secret.*-o'; then
    # Check if it's inside a subshell (output goes to consuming command)
    MAIN_CMD="${COMMAND%%\$(*}"
    if echo "$MAIN_CMD" | grep -qE '(kubectl|oc).*get.*secret.*-o'; then
        block "Retrieving secret data as standalone command. You CAN use secrets in subshells where output goes to a consuming command: cmd --key=\$(oc get secret X -o jsonpath='{.data.key}' | base64 -d). The subshell output never returns to Claude."
    fi
    # Inside subshell - allow it (output goes to parent command)
fi

if echo "$COMMAND" | grep -qE '(kubectl|oc).*get.*secret.*jsonpath'; then
    MAIN_CMD="${COMMAND%%\$(*}"
    if echo "$MAIN_CMD" | grep -qE '(kubectl|oc).*get.*secret.*jsonpath'; then
        block "Retrieving secret via jsonpath as standalone command. Use inside subshell: cmd --key=\$(oc get secret X -o jsonpath='{.data.key}' | base64 -d)"
    fi
fi

if echo "$COMMAND" | grep -qE '(kubectl|oc).*describe.*secret'; then
    # describe is always blocked - no legitimate subshell use case
    block "Describing secrets exposes data. To USE a secret: reference via secretKeyRef in pod specs, mount as volume, or use get+jsonpath in a subshell."
fi

if echo "$COMMAND" | grep -qE '(kubectl|oc).*get.*(configmap|cm).*-o'; then
    block "ConfigMaps may contain sensitive data. Never expose config values."
fi

# ============================================
# ANSIBLE VAULT/DEBUG SECRET EXTRACTION
# ============================================

if echo "$COMMAND" | grep -qE 'ansible-vault\s+(decrypt|view)'; then
    block "ansible-vault decrypt/view exposes vault contents."
fi

# ============================================
# ATLAS VAULT DECRYPT - Block standalone, allow in subshells
# ============================================

# Block standalone `atlas vault decrypt-var` (would return secret to stdout)
# But ALLOW it inside $(...) subshells where output goes to parent command
if echo "$COMMAND" | grep -qE 'atlas\s+vault\s+decrypt-var'; then
    # Check if it's ONLY inside subshells - if the command starts with atlas vault, block it
    # Extract command before any $( to see if atlas vault is the main command
    MAIN_CMD="${COMMAND%%\$(*}"
    if echo "$MAIN_CMD" | grep -qE '(^|[;&|])\s*atlas\s+vault\s+decrypt-var'; then
        block "atlas vault decrypt-var as standalone command exposes secrets. Use inside \$(...) subshell with a consuming command."
    fi
    # If we get here, it's inside a subshell - allow it
fi

if echo "$COMMAND" | grep -qE 'ansible.*-m\s*debug.*var=.*(password|secret|key|token|cert|macaroon|credential)'; then
    block "Ansible debug extracting sensitive variable."
fi

# ============================================
# FILE READING COMMANDS - cat, head, tail, less, more, bat
# ============================================

# Block reading .env files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*\.env'; then
    block "Reading .env file via command. Use variables without viewing."
fi

# Block reading vault files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*vault.*\.ya?ml'; then
    block "Reading vault file via command."
fi

# Block reading secrets files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*secrets.*\.ya?ml'; then
    block "Reading secrets file via command."
fi

# Block reading credential files (including .cre shorthand)
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*(credentials|\.cre)'; then
    block "Reading credentials file via command."
fi

# Block reading FTP credential files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*(\.netftp|\.ftp|ftp.*cred|ftp.*pass)'; then
    block "Reading FTP credentials file via command."
fi

# Block reading config files that commonly contain secrets
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*(\.conf|config\.ya?ml|config\.json)'; then
    block "Config files may contain embedded secrets. Check source code instead."
fi

# Block reading key/pem files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*(\.pem|\.key|id_rsa|id_ed25519)'; then
    block "Reading private key file."
fi

# Block reading docker config
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*\.docker/config'; then
    block "Reading docker config exposes registry credentials."
fi

# ============================================
# SSH-WRAPPED COMMANDS - Detect credential reads via SSH
# ============================================

# Block SSH commands that read credential files remotely
if echo "$COMMAND" | grep -qE 'ssh\s+\S+.*".*\b(cat|head|tail|less|more)\b.*\.(cre|env|netftp|ftp|pem|key)"'; then
    block "Reading credentials via SSH. Never expose remote secrets."
fi

if echo "$COMMAND" | grep -qE "ssh\s+\S+.*'.*\b(cat|head|tail|less|more)\b.*\.(cre|env|netftp|ftp|pem|key)'"; then
    block "Reading credentials via SSH. Never expose remote secrets."
fi

# Block SSH commands that grep for passwords/secrets
if echo "$COMMAND" | grep -qE 'ssh\s+\S+.*(password|secret|credential|token|apikey)'; then
    block "SSH command searching for sensitive data."
fi

# ============================================
# BASE64 DECODE OF SECRETS
# ============================================

# Only block GET/describe operations that pipe secret output to base64 decode
# ALLOW when inside subshell (output goes to consuming command, not Claude)
if echo "$COMMAND" | grep -qE '(kubectl|oc).*\b(get|describe)\b.*secret.*\|\s*base64'; then
    MAIN_CMD="${COMMAND%%\$(*}"
    # Only block if the secret access is in the MAIN command (standalone), not inside $()
    if echo "$MAIN_CMD" | grep -qE '(kubectl|oc).*\b(get|describe)\b.*secret'; then
        block "Decoding secret data via base64. Use inside subshell: cmd --arg=\$(oc get secret X -o jsonpath='{.data.key}' | base64 -d)"
    fi
    # Inside subshell - allow it
fi

# ============================================
# ENVIRONMENT VARIABLE EXTRACTION
# ============================================

if echo "$COMMAND" | grep -qE '(kubectl|oc).*exec.*env\s*$'; then
    block "Extracting environment variables from pod."
fi

if echo "$COMMAND" | grep -qE '(kubectl|oc).*exec.*printenv'; then
    block "Extracting environment variables from pod."
fi

exit 0
