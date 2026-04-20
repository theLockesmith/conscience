#!/bin/bash
# Block destructive commands before Claude executes them
# Location: ~/.claude/hooks/block-destructive.sh
# Last Updated: 2026-02-06

set -uo pipefail
# Note: Not using set -e because grep returns 1 on no match, which is expected

# Debug log (remove after testing)
echo "[HOOK DEBUG] block-destructive.sh invoked at $(date)" >> /tmp/claude-hook-debug.log

# Read the tool input from stdin
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Debug log
echo "[HOOK DEBUG] Command: $COMMAND" >> /tmp/claude-hook-debug.log

# Exit early if no command
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# =============================================================================
# BLOCKED PATTERNS - Commands that should NEVER be run
# =============================================================================

declare -A BLOCKED_PATTERNS=(
    # Force flags - must be standalone, not part of --from or -f /file
    # Note: --force-with-lease is allowed (safer alternative, checks remote hasn't changed)
    # The --force pattern is checked separately below to exclude --force-with-lease
    # Note: -f short form removed - too many false positives with -f /file and --from=
    ["--grace-period=0"]="Force delete with no grace period"
    ["--grace-period 0"]="Force delete with no grace period"

    # Kubernetes destructive operations
    ["kubectl delete"]="Kubernetes delete operation"
    ["oc delete"]="OpenShift delete operation"
    ["kubectl drain"]="Kubernetes node drain"
    ["oc drain"]="OpenShift node drain"

    # Docker - never restart
    ["systemctl restart docker"]="Docker daemon restart"
    ["systemctl stop docker"]="Docker daemon stop"
    ["service docker restart"]="Docker daemon restart"
    ["service docker stop"]="Docker daemon stop"

    # Ansible vault decryption
    ["ansible-vault decrypt"]="Vault decryption"
    ["ansible-vault view"]="Vault view (exposes secrets)"

    # Git destructive operations
    # Note: git push --force and -f handled separately below to allow --force-with-lease
    ["git reset --hard"]="Hard reset"
    ["git clean -fd"]="Force clean"

    # Filesystem destructive operations
    ["rm -rf /"]="Recursive delete of root"
    ["rm -rf /*"]="Recursive delete of root contents"
    ["rm -rf ~"]="Recursive delete of home"
    ["rm -rf $HOME"]="Recursive delete of home"

    # Ceph destructive operations
    ["ceph osd purge"]="Ceph OSD purge"
    ["ceph osd destroy"]="Ceph OSD destroy"
    ["ceph fs rm"]="Ceph filesystem remove"
    ["rbd rm"]="RBD image remove"

    # OpenStack destructive operations
    ["openstack server delete"]="OpenStack VM delete"
    ["openstack volume delete"]="OpenStack volume delete"
    ["openstack network delete"]="OpenStack network delete"
)

# =============================================================================
# Check for blocked patterns
# =============================================================================

for pattern in "${!BLOCKED_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qiF -- "$pattern" 2>/dev/null; then
        reason="${BLOCKED_PATTERNS[$pattern]}"

        # Exit 2 blocks the command, stderr message is shown to user
        echo "BLOCKED: $reason. Pattern matched: '$pattern'. This command requires explicit user approval." >&2
        exit 2
    fi
done

# =============================================================================
# DELETION COMMANDS - Block unless explicitly approved
# =============================================================================

# Extract just the command portion before any heredoc (<<) to avoid false positives
# from commit messages or other string content containing "rm -r"
COMMAND_BEFORE_HEREDOC="${COMMAND%%<<*}"

# Block rm -r and rm -rf - requires explicit user approval
# Only check the actual command, not heredoc/string content
if echo "$COMMAND_BEFORE_HEREDOC" | grep -qE '(^|[;&|])\s*rm\s+(-[a-zA-Z]*[rR]|[^-]+-[a-zA-Z]*[rR])'; then
    echo "BLOCKED: Recursive delete (rm -r) requires explicit user approval. Ask user before deleting." >&2
    exit 2
fi

# Block git rm - only as actual command, not in strings
if echo "$COMMAND_BEFORE_HEREDOC" | grep -qE '(^|[;&|])\s*git\s+rm\b'; then
    echo "BLOCKED: git rm requires explicit user approval. Ask user before removing files from git." >&2
    exit 2
fi

# Block --force but allow --force-with-lease (safer alternative)
if echo "$COMMAND" | grep -qE '\-\-force($|\s)' && ! echo "$COMMAND" | grep -q '\-\-force-with-lease'; then
    echo "BLOCKED: --force flag detected. Use --force-with-lease for safer force push, or get explicit user approval." >&2
    exit 2
fi

# Block git push -f (short form) but allow if --force-with-lease is also present
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*-f($|\s)' && ! echo "$COMMAND" | grep -q '\-\-force-with-lease'; then
    echo "BLOCKED: git push -f (force push). Use --force-with-lease for safer force push, or get explicit user approval." >&2
    exit 2
fi

# =============================================================================
# WARN PATTERNS - Allow but log warning
# =============================================================================

declare -A WARN_PATTERNS=(
    ["kubectl scale.*replicas=0"]="Scaling to zero replicas"
    ["oc scale.*replicas=0"]="Scaling to zero replicas"
)

for pattern in "${!WARN_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qiE "$pattern"; then
        reason="${WARN_PATTERNS[$pattern]}"
        echo "[HOOK WARNING] $reason: $COMMAND" >&2
    fi
done

# No blocked patterns matched, allow the command
exit 0
