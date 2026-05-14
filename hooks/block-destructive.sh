#!/bin/bash
# Block destructive commands before Claude executes them
# Location: ~/.claude/hooks/block-destructive.sh
# Last Updated: 2026-05-12

set -uo pipefail
# Not using set -e: grep returns 1 on no match, which is expected.

# Debug log
echo "[HOOK DEBUG] block-destructive.sh invoked at $(date)" >> /tmp/claude-hook-debug.log

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

echo "[HOOK DEBUG] Command: $COMMAND" >> /tmp/claude-hook-debug.log

[[ -z "$COMMAND" ]] && exit 0

# Strip heredoc body so patterns inside `cat <<EOF ... EOF` don't match.
COMMAND_BEFORE_HEREDOC="${COMMAND%%<<*}"

# [hook-tune] heredoc-safe target detector
# Decide whether the heredoc body should be scanned by the destructive-
# verb regex below. If the heredoc is being executed by a shell or
# interpreter, the body IS the command and we keep the original
# behavior (scan $COMMAND). Otherwise the body is data, and we scan
# only the pre-heredoc portion so a fixture/test/payload that describes
# destructive verbs doesn't trip the gate.
_HEREDOC_TARGET="${COMMAND_BEFORE_HEREDOC##*[[:space:]|;&\\]}"
_HEREDOC_TARGET="${_HEREDOC_TARGET#sudo }"
case "$_HEREDOC_TARGET" in
    bash|sh|zsh|ksh|dash|python|python3|perl|ruby|pwsh|node|nodejs|tcl|lua|psql|mysql)
        CMD_FOR_REGEX="$COMMAND"           # interpreter consumes heredoc; scan all
        ;;
    *)
        CMD_FOR_REGEX="$COMMAND_BEFORE_HEREDOC"  # heredoc is passive data
        ;;
esac


# =============================================================================
# LITERAL-VERB BLOCK LIST  (word-boundary regex; catches inside quotes/pipes/eval)
# =============================================================================
# Word patterns use \b. Flag patterns use (^|[[:space:];&|]) since \b can't
# precede a leading `-`. Aliases (k, kc) included for kubectl.

declare -A BLOCKED=(
    # Flag patterns (explicit anchor, not \b)
    ["(^|[[:space:];&|])--grace-period[= ][[:space:]]*0([[:space:]]|;|&|\\||$)"]="Force delete with no grace period"

    # Kubernetes/OpenShift (k and kc aliases too)
    ["\\b(kubectl|kc|k)[[:space:]]+delete\\b"]="Kubernetes delete operation"
    ["\\boc[[:space:]]+delete\\b"]="OpenShift delete operation"
    ["\\b(kubectl|kc|k)[[:space:]]+drain\\b"]="Kubernetes node drain"
    ["\\boc[[:space:]]+drain\\b"]="OpenShift node drain"

    # Docker daemon
    ["\\bsystemctl[[:space:]]+(restart|stop|reload)[[:space:]]+docker(\\.service|\\.socket)?\\b"]="Docker daemon restart/stop/reload"
    ["\\bservice[[:space:]]+docker[[:space:]]+(restart|stop)\\b"]="Docker daemon restart/stop"

    # tgtd (iSCSI target)
    ["\\bsystemctl[[:space:]]+(restart|stop)[[:space:]]+tgtd\\b"]="tgtd restart/stop - disconnects all iSCSI volumes"
    ["\\bservice[[:space:]]+tgtd[[:space:]]+(restart|stop)\\b"]="tgtd restart/stop"
    ["\\btgtadm[[:space:]]+--op[[:space:]]+delete\\b"]="tgtd target/LUN delete"

    # Ansible vault
    ["\\bansible-vault[[:space:]]+(decrypt|view)\\b"]="Vault decryption/view (exposes secrets)"

    # Git destructive (literal pair; broader set is in category block below)
    ["\\bgit[[:space:]]+reset[[:space:]]+--hard\\b"]="Git hard reset"
    ["\\bgit[[:space:]]+clean[[:space:]]+-[a-zA-Z]*[fd]"]="Git force clean"

    # Filesystem (specific roots; generic rm-r is in regex section below)
    ["\\brm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+/[[:space:]]*(\\*|;|&|\\||$)"]="Recursive delete of root"
    ["\\brm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+~([[:space:]]|/|$)"]="Recursive delete of home"
    ["\\brm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+$HOME([[:space:]]|/|$)"]="Recursive delete of home"

    # Ceph
    ["\\bceph[[:space:]]+osd[[:space:]]+(purge|destroy)\\b"]="Ceph OSD destroy/purge"
    ["\\bceph[[:space:]]+fs[[:space:]]+rm\\b"]="Ceph filesystem remove"
    ["\\brbd[[:space:]]+rm\\b"]="RBD image remove"

    # OpenStack
    ["\\bopenstack[[:space:]]+(server|volume|network)[[:space:]]+delete\\b"]="OpenStack delete"
)

for pattern in "${!BLOCKED[@]}"; do
    if echo "$CMD_FOR_REGEX" | grep -qiE -- "$pattern" 2>/dev/null; then
        echo "BLOCKED: ${BLOCKED[$pattern]}. Pattern matched: '$pattern'. Requires explicit user approval." >&2
        exit 2
    fi
done

# =============================================================================
# CATEGORY REGEX BLOCKS  (all use \b so they catch inside quotes/exec/bash-c)
# =============================================================================

# --- Database destructive (DROP/TRUNCATE/wholesale DELETE/FLUSHALL) ---
DB_DESTRUCTIVE='\bpsql\b.*-c.*(drop[[:space:]]+(table|database|schema|index|role|user|view|trigger|sequence|tablespace)|truncate[[:space:]]+(table[[:space:]]+)?[^;]*|delete[[:space:]]+from[[:space:]]+[^[:space:];]+[[:space:]]*(;|$|--))'
DB_DESTRUCTIVE+='|\bmysql\b.*-e.*(drop[[:space:]]+(table|database|schema)|truncate|delete[[:space:]]+from[[:space:]]+[^[:space:];]+[[:space:]]*(;|$))'
DB_DESTRUCTIVE+='|\b(dropdb|dropuser)\b'
DB_DESTRUCTIVE+='|\bredis-cli\b.*\b(flushall|flushdb)\b'
DB_DESTRUCTIVE+='|\bmongo(sh)?\b.*\bdropdatabase\b'
DB_DESTRUCTIVE+='|\bpg_drop_replication_slot\b'
if echo "$CMD_FOR_REGEX" | grep -qiE "$DB_DESTRUCTIVE"; then
    echo "BLOCKED: Database destructive operation (DROP/TRUNCATE/DELETE FROM/FLUSH). Requires explicit user approval." >&2
    exit 2
fi

# --- IaC destructive (terraform / helm / pulumi) ---
IAC_DESTRUCTIVE='\bterraform[[:space:]]+(destroy|apply[[:space:]]+.*-destroy)\b'
IAC_DESTRUCTIVE+='|\bhelm[[:space:]]+(uninstall|delete|rollback)\b'
IAC_DESTRUCTIVE+='|\bpulumi[[:space:]]+destroy\b'
if echo "$CMD_FOR_REGEX" | grep -qiE "$IAC_DESTRUCTIVE"; then
    echo "BLOCKED: IaC destructive operation (terraform/helm/pulumi). Requires explicit user approval." >&2
    exit 2
fi

# --- Cloud CLI destructive (scoped by service to reduce false positives) ---
CLOUD_DESTRUCTIVE='\baws[[:space:]]+(ec2[[:space:]]+terminate-instances|s3[[:space:]]+rm[[:space:]]+.*--recursive|s3[[:space:]]+rb|.*[[:space:]]delete-(bucket|instance|volume|snapshot|cluster|table|stack|db-instance|db-cluster|cluster-snapshot|file-system|load-balancer))\b'
CLOUD_DESTRUCTIVE+='|\bgcloud[[:space:]]+(compute|sql|storage|projects|container|dns|kms|iam|secrets|run|functions|pubsub)[[:space:]]+(.*[[:space:]])?delete\b'
CLOUD_DESTRUCTIVE+='|\baz[[:space:]]+(vm|disk|storage|group|aks|sql|network|keyvault|functionapp|webapp|cosmosdb)[[:space:]]+(.*[[:space:]])?delete\b'
if echo "$CMD_FOR_REGEX" | grep -qiE "$CLOUD_DESTRUCTIVE"; then
    echo "BLOCKED: Cloud CLI destructive operation (aws/gcloud/az). Requires explicit user approval." >&2
    exit 2
fi

# --- Pipelined deletion (find -delete, find -exec rm, xargs rm) ---
DELETE_PIPELINES='\bfind\b.*-delete\b'
DELETE_PIPELINES+='|\bfind\b.*-exec(dir)?[[:space:]]+rm\b'
DELETE_PIPELINES+='|\bxargs\b[[:space:]]+(.*[[:space:]])?rm\b'
if echo "$CMD_FOR_REGEX" | grep -qiE "$DELETE_PIPELINES"; then
    echo "BLOCKED: Pipelined deletion (find -delete / find -exec rm / xargs rm). Requires explicit user approval." >&2
    exit 2
fi

# --- Disk / filesystem-level destructive ---
DISK_DESTRUCTIVE='\bdd[[:space:]]+.*of=/dev/(sd|nvme|vd|hd|mmcblk|loop|md)'
DISK_DESTRUCTIVE+='|\bmkfs\.[a-z0-9]+\b'
DISK_DESTRUCTIVE+='|\bwipefs\b'
DISK_DESTRUCTIVE+='|\b(lvremove|vgremove|pvremove|lvreduce)\b'
DISK_DESTRUCTIVE+='|\bparted\b.*[[:space:]](rm|mklabel)\b'
DISK_DESTRUCTIVE+='|\bblkdiscard\b'
DISK_DESTRUCTIVE+='|\bshred[[:space:]]+.*-[a-z]*u'
if echo "$CMD_FOR_REGEX" | grep -qiE "$DISK_DESTRUCTIVE"; then
    echo "BLOCKED: Disk/filesystem-level destructive operation. Requires explicit user approval." >&2
    exit 2
fi

# --- Git destructive (beyond reset --hard / clean -fd in BLOCKED above) ---
GIT_DESTRUCTIVE='\bgit[[:space:]]+branch[[:space:]]+.*-D\b'
GIT_DESTRUCTIVE+='|\bgit[[:space:]]+tag[[:space:]]+.*-d\b'
GIT_DESTRUCTIVE+='|\bgit[[:space:]]+(checkout|restore)[[:space:]]+(--[[:space:]]+)?\.([[:space:]]|$)'
GIT_DESTRUCTIVE+='|\bgit[[:space:]]+stash[[:space:]]+(drop|clear)\b'
GIT_DESTRUCTIVE+='|\bgit[[:space:]]+reflog[[:space:]]+expire\b'
GIT_DESTRUCTIVE+='|\bgit[[:space:]]+gc[[:space:]]+.*--prune=now'
GIT_DESTRUCTIVE+='|\bgit[[:space:]]+filter-(branch|repo)\b'
GIT_DESTRUCTIVE+='|\bgit[[:space:]]+update-ref[[:space:]]+.*-d\b'
GIT_DESTRUCTIVE+='|\bgit[[:space:]]+worktree[[:space:]]+remove[[:space:]]+.*--force\b'
if echo "$CMD_FOR_REGEX" | grep -qiE "$GIT_DESTRUCTIVE"; then
    echo "BLOCKED: Git destructive operation (branch -D, checkout --, stash drop, reflog expire, history rewrite, etc.). Requires explicit user approval." >&2
    exit 2
fi

# --- System lifecycle ---
# Trailing context required so filenames like `shutdown.log` / `userdel.conf` don't trip.
LIFECYCLE='\b(shutdown|reboot|poweroff|halt)([[:space:]]|$|;|&|\|)'
LIFECYCLE+='|\bsystemctl[[:space:]]+(mask|isolate|emergency|rescue)\b'
LIFECYCLE+='|\b(userdel|groupdel)([[:space:]]|$|;|&|\|)'
if echo "$CMD_FOR_REGEX" | grep -qiE "$LIFECYCLE"; then
    echo "BLOCKED: System lifecycle operation (shutdown/reboot/mask/userdel). Requires explicit user approval." >&2
    exit 2
fi

# --- Output truncation to system paths ---
if echo "$COMMAND_BEFORE_HEREDOC" | grep -qE '>>?[[:space:]]*(/etc/|/var/|/usr/|/boot/|/lib/|/lib64/|/dev/(sd|nvme|vd|hd|mmcblk|loop|md))'; then
    echo "BLOCKED: Output redirection to system path detected. Requires explicit user approval." >&2
    exit 2
fi

# --- Scripted destructive in -c / -e payloads (python/perl/node/ruby) ---
# These bypass plain rm/dropdb pattern matching by going through language APIs.
# Matches by method-call shape (`.verb(`) so it catches both `os.unlink(x)` and
# `Path("x").unlink()`, both `fs.rmSync(x)` and `require("fs").rmSync(x)`.
SCRIPTED_DESTRUCTIVE='\bpython[0-9.]*[[:space:]]+.*-c[[:space:]]+.*(\bshutil\.rmtree\b|\bos\.(remove|unlink|rmdir|removedirs)\b|\.unlink\(|\.rmdir\(|\.rmtree\()'
SCRIPTED_DESTRUCTIVE+='|\bperl[[:space:]]+.*-[A-Za-z]*e[[:space:]]+.*\b(unlink\b|rmdir\b|system[[:space:]]+.*\brm[[:space:]]+-)'
SCRIPTED_DESTRUCTIVE+='|\bnode[[:space:]]+.*-e[[:space:]]+.*(\.(rmSync|unlinkSync|rmdirSync|rm|unlink|rmdir)\(|\bfs\.(rm|unlink|rmdir))'
SCRIPTED_DESTRUCTIVE+='|\bruby[[:space:]]+.*-e[[:space:]]+.*\b(File\.delete|FileUtils\.(rm|rm_rf|rm_r)|Dir\.rmdir)\b'
if echo "$CMD_FOR_REGEX" | grep -qiE "$SCRIPTED_DESTRUCTIVE"; then
    echo "BLOCKED: Scripted destructive operation in -c/-e payload (python/perl/node/ruby). Requires explicit user approval." >&2
    exit 2
fi

# --- Piped remote/encoded execution ---
# `curl X | bash`, `wget -O- X | sh`, `base64 -d ... | bash`, `xxd -r ... | sh`.
# Code from a remote or encoded source piped to a shell cannot be reviewed.
PIPED_EXEC='\b(curl|wget|fetch)\b[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|ksh)\b'
PIPED_EXEC+='|\bbase64\b[^|]*-d[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|ksh)\b'
PIPED_EXEC+='|\bxxd\b[^|]*-r[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|ksh)\b'
if echo "$CMD_FOR_REGEX" | grep -qiE "$PIPED_EXEC"; then
    echo "BLOCKED: Piped remote/encoded execution (curl|bash, base64|bash, etc.). Cannot be reviewed before execution. Requires explicit user approval." >&2
    exit 2
fi

# --- Untrusted-location pipe-to-shell ---
# Catches `cat /tmp/x.sh | bash`, `head ~/Downloads/y | sudo sh`, etc. Untrusted
# locations: /tmp, /var/tmp, ~/Downloads, ~/Desktop, /run/user/<uid>. Project
# dirs and repo paths are allowed — only well-known scratch areas are blocked.
# Allows flags between the read command and the path (e.g., `head -n 100 /tmp/x`).
UNTRUSTED_PIPE='(cat|head|tail|less|more|bat|view)[[:space:]]+([^|/]*[[:space:]])?(/tmp/|/var/tmp/|'"$HOME"'/Downloads/|'"$HOME"'/Desktop/|/run/user/[0-9]+/)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|ksh)\b'
if echo "$CMD_FOR_REGEX" | grep -qiE "$UNTRUSTED_PIPE"; then
    echo "BLOCKED: Piping a file from an untrusted location (/tmp, /var/tmp, ~/Downloads, ~/Desktop, /run/user) to a shell. Move the file to a project dir and review it first, or get explicit user approval." >&2
    exit 2
fi

# --- Variable indirection / eval bypass closure ---
# Catches `$KUBECTL delete`, `${TOOL} destroy`, `eval $(echo k delete)`,
# `$RM_CMD -rf ...`, etc. Pattern matching can't expand the variable, but the
# shape (var + destructive verb, or destructive-named var + recursive flag) is
# suspicious enough to block.
VAR_INDIRECTION='\$\{?[A-Z_][A-Z0-9_]*\}?[[:space:]]+(delete|destroy|drop|terminate|purge|wipe|remove|format|mkfs|reboot|shutdown)\b'
VAR_INDIRECTION+='|\$\{?(RM|REMOVE|DEL|DELETE|UNLINK|DESTROY|PURGE|WIPE|TRASH)[A-Z0-9_]*\}?[[:space:]]+-[a-zA-Z]*[rR]'
VAR_INDIRECTION+='|\beval\b[^|;&]*\b(delete|destroy|drop|terminate|purge|format|mkfs|reboot|shutdown)\b'
VAR_INDIRECTION+='|\beval\b[^|;&]*\brm[[:space:]]+-[a-zA-Z]*[rR]'
if echo "$CMD_FOR_REGEX" | grep -qiE "$VAR_INDIRECTION"; then
    echo "BLOCKED: Variable indirection or eval with destructive verb. Resolve the variable / inline the command so the destructive action is reviewable, or get explicit user approval." >&2
    exit 2
fi

# =============================================================================
# GENERIC rm-r / git rm / --force CHECKS  (\b for quote-context coverage)
# =============================================================================

# Block rm -r and rm -rf
if echo "$COMMAND_BEFORE_HEREDOC" | grep -qE '\brm[[:space:]]+(-[a-zA-Z]*[rR]|[^-]+-[a-zA-Z]*[rR])'; then
    echo "BLOCKED: Recursive delete (rm -r) requires explicit user approval." >&2
    exit 2
fi

# Block git rm
if echo "$COMMAND_BEFORE_HEREDOC" | grep -qE '\bgit[[:space:]]+rm\b'; then
    echo "BLOCKED: git rm requires explicit user approval." >&2
    exit 2
fi

# Block --force but allow --force-with-lease (safer alternative)
if echo "$CMD_FOR_REGEX" | grep -qE '\-\-force($|\s)' && ! echo "$COMMAND" | grep -q '\-\-force-with-lease'; then
    echo "BLOCKED: --force flag detected. Use --force-with-lease, or get explicit user approval." >&2
    exit 2
fi

# Block git push -f (short form) but allow if --force-with-lease is also present
if echo "$CMD_FOR_REGEX" | grep -qE 'git\s+push\s+.*-f($|\s)' && ! echo "$COMMAND" | grep -q '\-\-force-with-lease'; then
    echo "BLOCKED: git push -f (force push). Use --force-with-lease, or get explicit user approval." >&2
    exit 2
fi

# =============================================================================
# WARN PATTERNS - Allow but log warning
# =============================================================================

declare -A WARN_PATTERNS=(
    ["\\b(kubectl|kc|k)[[:space:]]+scale.*replicas=0\\b"]="Scaling to zero replicas"
    ["\\boc[[:space:]]+scale.*replicas=0\\b"]="Scaling to zero replicas"
)

for pattern in "${!WARN_PATTERNS[@]}"; do
    if echo "$CMD_FOR_REGEX" | grep -qiE -- "$pattern"; then
        echo "[HOOK WARNING] ${WARN_PATTERNS[$pattern]}: $COMMAND" >&2
    fi
done

exit 0
