#!/bin/bash
# verify-infra-target.sh -- V17 Phase 3 target-aware enforcement
# Hook: PreToolUse (matcher: Bash)
#
# Replaces the May-era "warn on every Bash command" pattern with semantic
# target-aware gating. For each Bash command:
#
#   1. extract_targets(cmd)              -- Phase 1 library
#   2. filter to prod via prod-targets.yml -- Phase 2 manifest
#   3. for each prod target, allow IFF one of:
#        a. the user's last prompt mentioned the target's matchable token
#        b. a RAG search this turn returned results mentioning the token
#        c. a verify_action this turn declared the target (Phase 5)
#   4. otherwise BLOCK with the V17-spec error message
#
# Bypass envvar (debugging only): CLAUDE_PROD_OVERRIDE=<name>
# When used, the bypass is logged loudly to ~/.claude/security/audit.log.

set -uo pipefail

LIB_DIR="$HOME/.claude/hooks/lib"
STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

# shellcheck disable=SC1091
source "$LIB_DIR/target-extract.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/prod-target-match.sh"

LAST_PROMPT_FILE="$STATE_DIR/last-prompt.txt"
RAG_CALLS_FILE="$STATE_DIR/rag-calls-this-turn.txt"
VERIFY_ACTIONS_FILE="$STATE_DIR/verify-actions-this-turn.jsonl"
LEGACY_LOG="$HOME/.claude/infra-verification.log"

# ---------------------------------------------------------------------------
# Read PreToolUse input
# ---------------------------------------------------------------------------
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "$COMMAND" || "$COMMAND" == "null" ]] && exit 0

# Trivial-command allowlist — exact same shape as the previous hook so
# we don't regress "no warnings on `pwd`."
TRIVIAL_PATTERNS='^echo |^pwd$|^date$|^whoami$|^id$|^hostname$|^uname|^which |^type |--version$|--help$|-h$'
echo "$COMMAND" | grep -qE "$TRIVIAL_PATTERNS" && exit 0

# Load manifest. If it fails, fall back to legacy-style warning so the
# hook never sileently bypasses.
if ! pt_load_manifest; then
    cat << EOF
<system-reminder>
verify-infra-target: prod-targets.yml manifest not loadable; falling back
to legacy warning mode. Search RAG before infra commands.
</system-reminder>
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Extract targets and filter to prod
# ---------------------------------------------------------------------------
TARGETS=$(extract_targets "$COMMAND" | sort -u)
[[ -z "$TARGETS" ]] && exit 0

PROD_TARGETS=()
while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    if pt_is_prod_target "$t"; then
        PROD_TARGETS+=("$t")
    fi
done <<< "$TARGETS"

[[ ${#PROD_TARGETS[@]} -eq 0 ]] && exit 0

# ---------------------------------------------------------------------------
# matchable_token <TYPE:VALUE> -> the substring to search for in
# prompts/results. For most types this is the VALUE; for file_path we
# use the basename so /etc/foo.conf matches a prompt that says "foo".
# ---------------------------------------------------------------------------
matchable_token() {
    local entry="$1"
    local type="${entry%%:*}" val="${entry#*:}"
    case "$type" in
        file_path)
            printf '%s' "${val##*/}"
            ;;
        k8s_resource)
            printf '%s' "${val##*/}"
            ;;
        *)
            printf '%s' "$val"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Mention checks
# ---------------------------------------------------------------------------
user_prompt_mentions() {
    local token="$1"
    [[ -f "$LAST_PROMPT_FILE" ]] || return 1
    # case-insensitive, word-boundary
    LC_ALL=C grep -qiE "\\b${token//[^A-Za-z0-9._-]/.}\\b" "$LAST_PROMPT_FILE" 2>/dev/null
}

rag_results_this_turn_mention() {
    local token="$1"
    [[ -f "$RAG_CALLS_FILE" ]] || return 1
    # Only the RESULT lines count. Format: turn\tTOOL\tRESULT\t<content>
    LC_ALL=C grep -P "^[^\t]+\t[^\t]+\tRESULT\t" "$RAG_CALLS_FILE" 2>/dev/null \
      | LC_ALL=C grep -qiE "\\b${token//[^A-Za-z0-9._-]/.}\\b"
}

verify_action_this_turn_for() {
    local entry="$1"
    [[ -f "$VERIFY_ACTIONS_FILE" ]] || return 1
    # File holds one JSON line per verify_action call this turn.
    # Match if any line's "targets" array literally contains the entry,
    # or contains an entry where the value-side glob-matches us.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if echo "$line" | jq -e --arg t "$entry" \
            'any(.targets[]?; . == $t)' >/dev/null 2>&1; then
            return 0
        fi
    done < "$VERIFY_ACTIONS_FILE"
    return 1
}

# ---------------------------------------------------------------------------
# Bypass envvar
# ---------------------------------------------------------------------------
BYPASS="${CLAUDE_PROD_OVERRIDE:-}"
if [[ -n "$BYPASS" ]]; then
    pt_audit_log "[BYPASS-USED]" "verify-infra-target CLAUDE_PROD_OVERRIDE=$BYPASS cmd=$(echo "$COMMAND" | head -c 200)"
fi

# ---------------------------------------------------------------------------
# Per-target gate
# ---------------------------------------------------------------------------
BLOCKED_TARGETS=()
for entry in "${PROD_TARGETS[@]}"; do
    token="$(matchable_token "$entry")"

    # Bypass: explicit env var naming this specific target
    if [[ -n "$BYPASS" && "$BYPASS" == "$token" ]]; then
        pt_audit_log "[BYPASS-MATCHED]" "target=$entry token=$token"
        continue
    fi

    user_prompt_mentions "$token"          && continue
    rag_results_this_turn_mention "$token" && continue
    verify_action_this_turn_for "$entry"   && continue

    BLOCKED_TARGETS+=("$entry")
done

[[ ${#BLOCKED_TARGETS[@]} -eq 0 ]] && exit 0

# ---------------------------------------------------------------------------
# Build BLOCK message per V17 spec
# ---------------------------------------------------------------------------
{
    printf 'BLOCKED: command against PROD target(s):\n'
    for entry in "${BLOCKED_TARGETS[@]}"; do
        printf '  - %s\n' "$entry"
    done
    cat <<'EOF'

Verify it explicitly via ONE of:
  - User prompt naming the target (e.g. "yes, roll <name>")
  - mcp__rag__verify_action(target="<kind>:<name>", intent="<what you're doing>")
  - RAG search whose RESULTS mention <name> (the search must return content
    containing the target token — a query that mentions the target is NOT
    sufficient by itself)

Bypass envvar (debugging only): CLAUDE_PROD_OVERRIDE=<name>
EOF
} >&2

pt_audit_log "[BLOCK]" "verify-infra-target targets=$(IFS=,; echo "${BLOCKED_TARGETS[*]}") cmd=$(echo "$COMMAND" | head -c 200)"

# Also log to legacy file for backward compat with existing dashboards
{
    printf '[%s] BLOCKED bash: %s\n' "$(date -Iseconds)" "$(echo "$COMMAND" | head -c 200)"
    printf '  prod targets: %s\n' "$(IFS=,; echo "${BLOCKED_TARGETS[*]}")"
} >> "$LEGACY_LOG"

exit 2
