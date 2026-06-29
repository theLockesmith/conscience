#!/bin/bash
# Require RAG Before Substantive Action (PreToolUse)
# V17 Phase 6: semantic upgrade.
#
# Old logic: "any mcp__rag__search_* this turn satisfies the gate."
# New logic: "RAG search RESULTS this turn must mention the target's
# tokens, OR a verify_action this turn must declare the target."
#
# Per V17 Phase 6 spec:
#   token_extract(tool_input) -> [tokens]
#   if any(rag_results_this_turn contain tokens): pass
#   elif verify_action_this_turn_for_any(tokens): pass
#   else: BLOCK
#
# Free passes (unchanged from pre-V17 hook):
#   - mcp__rag__*           (otherwise we'd self-block)
#   - Read / Glob / Grep    (search-shaped, no commit)
#   - TaskList/Get/Update/Create (intra-task management)
#   - Bash                   (Phase 3/4 hooks gate the dangerous shapes)
#   - Edit/Write/NotebookEdit into scratch paths (/tmp, ~/.cache, scratch/)
#
# Bypass: DISABLE_RAG_PRETOOLUSE=1

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

[[ "${DISABLE_RAG_PRETOOLUSE:-}" == "1" ]] && exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Free-pass tools (unchanged)
case "$TOOL_NAME" in
    mcp__rag__*|mcp__rag-empire__*) exit 0 ;;
    Read|Glob|Grep|TaskList|TaskGet|TaskUpdate|TaskCreate) exit 0 ;;
    "") exit 0 ;;
esac

SUBSTANTIVE_REGEX="^(Edit|Write|Task|NotebookEdit)$"
[[ "$TOOL_NAME" =~ $SUBSTANTIVE_REGEX ]] || exit 0

is_scratch_path() {
    local p="$1"
    [[ -z "$p" ]] && return 1
    case "$p" in
        /tmp/*|/tmp|/var/tmp/*|/var/tmp) return 0 ;;
        "$HOME"/.cache/*|"$HOME"/.cache) return 0 ;;
        */.cache/*) return 0 ;;
        */scratch/*) return 0 ;;
        /run/user/*) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Token extraction per tool type. Outputs one token per line on stdout.
# ---------------------------------------------------------------------------
extract_tokens() {
    case "$TOOL_NAME" in
        Edit|Write|NotebookEdit)
            local fp
            fp=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
            if [[ -z "$fp" || "$fp" == "null" ]]; then return; fi
            if is_scratch_path "$fp"; then
                printf '__SCRATCH__\n'   # special token, treated as auto-allow
                return
            fi
            # basename + parent dir + grand-parent dir if non-trivial
            local bn="${fp##*/}"
            local par="${fp%/*}";   par="${par##*/}"
            local gpar="${fp%/*}"; gpar="${gpar%/*}"; gpar="${gpar##*/}"
            # Normalize so dotfile/config paths are matchable: a leading dot
            # makes `\b.claude\b` unsatisfiable (the word boundary sits before
            # 'claude', not the dot), so strip it. Also emit the basename STEM
            # (hooks.yaml -> hooks, auth.go -> auth) so a topical RAG result
            # matches without the result needing the literal extension.
            bn="${bn#.}"; par="${par#.}"; gpar="${gpar#.}"
            local stem="${bn%.*}"
            [[ -n "$bn"   ]] && printf '%s\n' "$bn"
            [[ -n "$stem" && "$stem" != "$bn" ]] && printf '%s\n' "$stem"
            [[ -n "$par"  && "$par"  != "$bn" ]] && printf '%s\n' "$par"
            [[ -n "$gpar" && "$gpar" != "$par" && "$gpar" != "$bn" ]] && printf '%s\n' "$gpar"
            ;;
        Task)
            local agent prompt
            agent=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
            prompt=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null)
            [[ -n "$agent" ]] && printf '%s\n' "$agent"
            # First 50 tokens of the prompt as candidate tokens
            if [[ -n "$prompt" ]]; then
                echo "$prompt" \
                    | head -c 400 \
                    | tr '[:space:][:punct:]' '\n' \
                    | grep -E '^[A-Za-z0-9_.-]{4,}$' \
                    | head -20
            fi
            ;;
    esac
}

TOKENS=$(extract_tokens | sort -u)

# Scratch sentinel = auto-allow
if echo "$TOKENS" | grep -qx '__SCRATCH__'; then exit 0; fi

# No extractable tokens -> fall back to legacy "any RAG this turn" behavior
RAG_CALLS_FILE="$STATE_DIR/rag-calls-this-turn.txt"
TURN_ID_FILE="$STATE_DIR/current-turn-id.txt"
VERIFY_ACTIONS_FILE="$STATE_DIR/verify-actions-this-turn.jsonl"
CURRENT_TURN=""
[[ -f "$TURN_ID_FILE" ]] && CURRENT_TURN=$(cat "$TURN_ID_FILE" 2>/dev/null)

# Legacy: presence of any RAG call this turn (kept as a permissive
# fallback when token extraction yielded nothing — e.g. Task with a
# vague prompt).
has_any_rag_this_turn() {
    [[ -n "$CURRENT_TURN" && -f "$RAG_CALLS_FILE" ]] || return 1
    grep -q "^${CURRENT_TURN}:" "$RAG_CALLS_FILE" 2>/dev/null
}

# Time-window fallback: a recent RAG search counts. Useful for
# background-task / monitor flows that roll current-turn-id mid-turn.
has_recent_rag_window() {
    local f="$STATE_DIR/last-rag-search.txt"
    [[ -f "$f" ]] || return 1
    local last now win
    last=$(cat "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    win="${RAG_LOOKUP_WINDOW:-1800}"
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    (( now - last < win ))
}

if [[ -z "$TOKENS" ]]; then
    has_any_rag_this_turn && exit 0
    has_recent_rag_window && exit 0
fi

# ---------------------------------------------------------------------------
# Semantic check: do RAG results this turn mention any extracted token?
# ---------------------------------------------------------------------------
rag_results_mention_any_token() {
    [[ -f "$RAG_CALLS_FILE" ]] || return 1
    # RESULT-line rows only; case-insensitive token search
    local body
    body=$(LC_ALL=C grep -P '^[^\t]+\t[^\t]+\tRESULT\t' "$RAG_CALLS_FILE" 2>/dev/null || true)
    [[ -z "$body" ]] && return 1
    while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        # Escape regex metachars in tok
        local etok="${tok//[^A-Za-z0-9._-]/.}"
        if echo "$body" | LC_ALL=C grep -qiE "\\b${etok}\\b"; then
            return 0
        fi
    done <<< "$TOKENS"
    return 1
}

verify_action_mentions_any_token() {
    [[ -f "$VERIFY_ACTIONS_FILE" ]] || return 1
    while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        local etok="${tok//[^A-Za-z0-9._-]/.}"
        if LC_ALL=C grep -qiE "\\b${etok}\\b" "$VERIFY_ACTIONS_FILE" 2>/dev/null; then
            return 0
        fi
    done <<< "$TOKENS"
    return 1
}

rag_results_mention_any_token        && exit 0
verify_action_mentions_any_token     && exit 0

# ---------------------------------------------------------------------------
# BLOCK
# ---------------------------------------------------------------------------
{
    echo "[$(date -Iseconds)] PRETOOLUSE BLOCK (V17 P6): no RAG result / verify_action mentions" \
         "tokens=$(echo "$TOKENS" | tr '\n' ',' | sed 's/,$//') tool=$TOOL_NAME turn=${CURRENT_TURN:-unknown}"
} >> "$HOME/.claude/rag-enforcement.log"

# 2026-06-29: emit the block on STDOUT as a Claude Code decision envelope
# so the MODEL sees the actionable guidance — not just the dispatcher.log.
# Pre-fix this output went to stderr, which Claude Code does NOT surface
# to the model; the model just saw a bare exit-2 and had no idea what to
# do. Operator's other session was hitting persistent edit-blocks with
# no notification of how to satisfy the gate. The stderr ASCII-box stays
# duplicated below for human/log readability.
#
# Tokens are comma-joined onto a single line for the JSON-safe reason
# string; the multi-line stderr form below keeps the original formatting
# for `journalctl --user -u …` / `tail -f dispatcher.log` readers.
_TOKENS_FLAT=$(echo "$TOKENS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
_REASON="BLOCKED: ${TOOL_NAME} on a target nothing this turn has RAG-loaded.

Tokens extracted from the tool input: ${_TOKENS_FLAT}

To proceed, satisfy the gate with ONE of:
  • mcp__rag__search_docs / search_learnings / search_decisions whose RESULTS contain content mentioning one of the tokens above.
  • mcp__rag__verify_action(intent=\"<what you're doing>\", targets=[\"<entry>\"]) for a target whose value matches one of the tokens.

The token must appear in RAG RESULTS, not just the query. A search whose results don't return content naming the token doesn't satisfy the gate.

Bypass for the rest of the session: export DISABLE_RAG_PRETOOLUSE=1 (operator-side only)."

# Emit JSON to stdout — Claude Code reads this and surfaces the reason
# to the model, so it actually knows what to do.
python3 -c "
import json, sys
print(json.dumps({
    'decision': 'block',
    'reason': sys.argv[1],
}))
" "$_REASON"

# Also write the human-readable box-art to stderr for logs/journalctl.
cat <<EOF >&2
╔═══════════════════════════════════════════════════════════════════════════════╗
║ BLOCKED: ${TOOL_NAME} on a target nothing this turn has RAG-loaded             ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║ Tokens from the tool input: ${TOKENS//$'\n'/, }
║
║ Allow this action by ONE of:
║   - mcp__rag__search_docs / search_learnings / search_decisions whose
║     results return content mentioning one of the tokens above
║   - mcp__rag__verify_action(intent="<what>", targets=["<entry>"]) for a
║     target whose value matches one of the tokens
║
║ The token must appear in RAG RESULTS, not just the query. Searching
║ "what is the rag-mcp deploy" without getting back content that names
║ rag-mcp is not enough.
║
║ Bypass: export DISABLE_RAG_PRETOOLUSE=1
╚═══════════════════════════════════════════════════════════════════════════════╝
EOF
exit 2
