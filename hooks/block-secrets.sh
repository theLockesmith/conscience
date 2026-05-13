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
            block "Cannot read sensitive file ($pattern). Path: $FILE_PATH. To USE secrets: reference them via subshell \$(cat ...) in consuming commands, or use secretKeyRef in K8s manifests. Never VIEW secrets directly."
        fi
    done

    # Block reading from sensitive directories
    BLOCKED_DIRS=(
        "$HOME/.ssh"
        "$HOME/.gnupg"
        "$HOME/.aws"
        "$HOME/.azure"
        "$HOME/.gcloud"
        "$HOME/.secrets"
    )

    NORMALIZED_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
    for blocked_dir in "${BLOCKED_DIRS[@]}"; do
        if [[ "$NORMALIZED_PATH" == "$blocked_dir"* ]]; then
            block "Cannot read from sensitive directory: $blocked_dir. To USE these secrets: use subshell pattern like cmd --arg=\$(cat $blocked_dir/file) where output goes to the consuming command, never to stdout."
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

# K8s secret access - block value extraction, allow metadata inspection
# ALLOW: | jq 'keys' (list key names), | wc -c (count chars), | grep -q (existence check)
# BLOCK: standalone secret data retrieval that would display values
if echo "$COMMAND" | grep -qE '(kubectl|oc[-a-z]*).*get.*secret.*-o'; then
    # Allow safe output formats that don't expose values
    if echo "$COMMAND" | grep -qE -- '-o\s*(name|wide|custom-columns)'; then
        : # Allow - these don't expose secret data
    # Allow metadata inspection patterns that don't expose values
    elif echo "$COMMAND" | grep -qE '\|\s*(jq.*keys|wc\s+-[cl]|grep\s+-q)'; then
        : # Allow - these inspect metadata without exposing values
    else
        # Check if it's inside a subshell (output goes to consuming command)
        MAIN_CMD="${COMMAND%%\$(*}"
        if echo "$MAIN_CMD" | grep -qE '(kubectl|oc[-a-z]*).*get.*secret.*-o'; then
            block "Retrieving secret data as standalone command. You CAN: (1) use secrets in subshells: cmd --key=\$(oc get secret X -o jsonpath='{.data.key}' | base64 -d), (2) list key names: oc get secret X -o json | jq 'keys', (3) check existence: oc get secret X -o jsonpath='{.data.key}' | wc -c"
        fi
    fi
fi

if echo "$COMMAND" | grep -qE '(kubectl|oc[-a-z]*).*get.*secret.*jsonpath'; then
    # Allow metadata inspection
    if echo "$COMMAND" | grep -qE '\|\s*(wc\s+-c|wc\s+-l|grep\s+-q)'; then
        : # Allow - checking existence/size without displaying value
    else
        MAIN_CMD="${COMMAND%%\$(*}"
        if echo "$MAIN_CMD" | grep -qE '(kubectl|oc[-a-z]*).*get.*secret.*jsonpath'; then
            block "Retrieving secret via jsonpath as standalone command. Use in subshell: cmd --key=\$(oc get secret X -o jsonpath='{.data.key}' | base64 -d), or check existence: ... | wc -c"
        fi
    fi
fi

if echo "$COMMAND" | grep -qE '(kubectl|oc[-a-z]*).*describe.*secret'; then
    # describe is always blocked - no legitimate subshell use case
    block "Describing secrets exposes data. To USE a secret: reference via secretKeyRef in pod specs, mount as volume, or use get+jsonpath in a subshell."
fi

# ConfigMap access - only block if extracting data that looks sensitive
# Most configmaps are safe; only block if combined with sensitive-looking keys
if echo "$COMMAND" | grep -qE '(kubectl|oc[-a-z]*).*get.*(configmap|cm).*-o.*jsonpath.*\.(password|secret|key|token|credential)'; then
    block "ConfigMap may contain sensitive data in this key. Use secretKeyRef instead."
fi

# ============================================
# ANSIBLE VAULT/DEBUG SECRET EXTRACTION
# ============================================

if echo "$COMMAND" | grep -qE 'ansible-vault\s+(decrypt|view)'; then
    block "ansible-vault decrypt/view exposes vault contents. For vault values: treat as opaque, use ansible-vault encrypt_string for new values, or reference via lookup('hashi_vault', ...) at runtime."
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
    block "Ansible debug extracting sensitive variable. Use no_log: true on tasks handling secrets, or reference via secretKeyRef/volume mounts in K8s."
fi

# ============================================
# FILE READING COMMANDS - cat, head, tail, less, more, bat
# ============================================

# Block reading .env files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*\.env'; then
    block "Reading .env file via command. To USE env vars: source in subshell like (source .env && cmd \$VAR), or pass via --env-file to docker. Never VIEW the file directly."
fi

# Block reading vault files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*vault.*\.ya?ml'; then
    block "Reading vault file via command. Vault files are encrypted - use ansible-vault encrypt_string for new values, or reference via Jinja2 templates that decrypt at deploy time."
fi

# Block reading secrets files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*secrets.*\.ya?ml'; then
    block "Reading secrets file via command. Use secrets via subshell pattern: cmd --key=\$(cat secrets.yaml | yq '.key'), or reference in K8s via secretKeyRef."
fi

# Block reading ~/.secrets/ directory - but allow in subshells for USE without VIEW
# Pattern: `curl -H "Auth: $(cat ~/.secrets/token)"` is allowed (output goes to curl)
#          `cat ~/.secrets/token` is blocked (output returns to Claude)
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*[~/]\.secrets/'; then
    # Check if it's inside a subshell (output goes to consuming command)
    MAIN_CMD="${COMMAND%%\$(*}"
    if echo "$MAIN_CMD" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*[~/]\.secrets/'; then
        block "Reading ~/.secrets/ file as standalone command. You CAN use secrets in subshells: curl -H \"Auth: \$(cat ~/.secrets/token)\" - the secret value never returns to Claude."
    fi
    # Inside subshell - allow it (output goes to parent command)
fi

# Block reading credential files (including .cre shorthand)
# Pattern requires word boundary or path separator to avoid false positives like .created
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*(credentials|\.cre($|[^a-z]))'; then
    block "Reading credentials file via command. To USE: pass credentials in subshell like cmd --user=\$(cat creds | head -1) --pass=\$(cat creds | tail -1), never VIEW directly."
fi

# Block reading FTP credential files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*(\.netftp|\.ftp|ftp.*cred|ftp.*pass)'; then
    block "Reading FTP credentials file via command. Configure FTP client via ~/.netrc or lftp bookmark, or pass in subshell: lftp -u user,\$(cat .ftp-pass) host"
fi

# Block reading config files that commonly contain secrets
# Pattern requires .conf at end or followed by non-word char to avoid matching ~/.config/ paths
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*(\.conf($|[^a-z])|config\.ya?ml|config\.json)'; then
    block "Config files may contain embedded secrets. To inspect structure: use grep -v password config.yaml, or check source code/templates. To USE config values: reference via application's config loading mechanism."
fi

# Block reading key/pem files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*(\.pem|\.key|id_rsa|id_ed25519)'; then
    block "Reading private key file. Keys should be referenced by path (ssh -i /path/to/key), added to ssh-agent (ssh-add), or mounted as K8s secrets. Never view key contents."
fi

# Block reading docker config
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*\.docker/config'; then
    block "Reading docker config exposes registry credentials. Use docker login to authenticate, or reference via imagePullSecrets in K8s. Never view credentials directly."
fi

# ============================================
# SSH-WRAPPED COMMANDS - Detect credential reads via SSH
# ============================================

# Block SSH commands that read credential files remotely
if echo "$COMMAND" | grep -qE 'ssh\s+\S+.*".*\b(cat|head|tail|less|more)\b.*\.(cre|env|netftp|ftp|pem|key)"'; then
    block "Reading credentials via SSH. Use credentials remotely via subshell: ssh host 'cmd --pass=\$(cat /path/to/secret)'. Never extract secrets to local machine."
fi

if echo "$COMMAND" | grep -qE "ssh\s+\S+.*'.*\b(cat|head|tail|less|more)\b.*\.(cre|env|netftp|ftp|pem|key)'"; then
    block "Reading credentials via SSH. Use credentials remotely via subshell: ssh host 'cmd --pass=\$(cat /path/to/secret)'. Never extract secrets to local machine."
fi

# Block SSH commands that EXTRACT credentials (cat, echo, printenv)
# ALLOW searching logs for mentions of credentials (grep, docker logs)
if echo "$COMMAND" | grep -qE 'ssh\s+\S+.*["'"'"']\s*(cat|echo|printenv).*\b(password|secret|credential|token|apikey)\b'; then
    block "SSH command extracting sensitive data. To USE secrets remotely: ssh host 'cmd --key=\$(cat /path/to/secret)'. Searching logs (grep, docker logs) is allowed."
fi

# ============================================
# BASE64 DECODE OF SECRETS
# ============================================

# Only block GET/describe operations that pipe secret output to base64 decode
# ALLOW when inside subshell (output goes to consuming command, not Claude)
if echo "$COMMAND" | grep -qE '(kubectl|oc[-a-z]*).*\b(get|describe)\b.*secret.*\|\s*base64'; then
    MAIN_CMD="${COMMAND%%\$(*}"
    # Only block if the secret access is in the MAIN command (standalone), not inside $()
    if echo "$MAIN_CMD" | grep -qE '(kubectl|oc[-a-z]*).*\b(get|describe)\b.*secret'; then
        block "Decoding secret data via base64. Use inside subshell: cmd --arg=\$(oc get secret X -o jsonpath='{.data.key}' | base64 -d)"
    fi
    # Inside subshell - allow it
fi

# ============================================
# ENVIRONMENT VARIABLE EXTRACTION
# ============================================

if echo "$COMMAND" | grep -qE '(kubectl|oc[-a-z]*).*exec.*env\s*$'; then
    block "Extracting environment variables from pod. Check specific vars: oc exec pod -- printenv VAR_NAME | wc -c (existence). To USE env in commands: oc exec pod -- sh -c 'cmd --key=\$SECRET_VAR'"
fi

if echo "$COMMAND" | grep -qE '(kubectl|oc[-a-z]*).*exec.*printenv'; then
    block "Extracting environment variables from pod. Check specific vars: oc exec pod -- printenv VAR_NAME | wc -c (existence). To USE env in commands: oc exec pod -- sh -c 'cmd --key=\$SECRET_VAR'"
fi

exit 0
