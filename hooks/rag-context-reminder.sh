#!/bin/bash
# RAG Context Loader - Automatically loads relevant RAG context on every message
# Hook: UserPromptSubmit
#
# PURPOSE: Force RAG lookup on every message. No more "reminders" - actually DO the search
# and inject relevant learnings/decisions into context.
#
# Queries:
# 1. Critical learnings (gotchas) - always injected
# 2. Recent learnings for current project (last 30 days)
# 3. Recent decisions for current project (last 30 days)

set -uo pipefail

# Read hook input
INPUT=$(cat)
USER_PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // .prompt // .message // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# Skip if no prompt
if [[ -z "$USER_PROMPT" || "$USER_PROMPT" == "null" ]]; then
    exit 0
fi

# Surface-aware routing: resolve the cwd's RAG surface (default vs empire) and
# point the helper at the matching server + PAT. An Empire-context session then
# recalls EMPIRE context, and sovereignty holds -- Coldforge decisions are never
# injected into an Empire session, nor the reverse. Falls back to the default
# surface (the helper's built-in endpoint/token) if resolution yields nothing.
if [[ -f "$HOME/.claude/hooks/lib/surface-resolve.sh" ]]; then
    # shellcheck source=lib/surface-resolve.sh
    . "$HOME/.claude/hooks/lib/surface-resolve.sh" 2>/dev/null || true
    SR_RESOLVED=$(sr_resolve "${CWD:-$PWD}" 2>/dev/null) || SR_RESOLVED=""
    IFS='|' read -r _SR_SURFACE _SR_COMPANY _SR_SERVER SR_MCP_URL SR_TOKEN_FILE <<< "$SR_RESOLVED"
    [[ -n "${SR_MCP_URL:-}"    ]] && export RAG_MCP_URL="$SR_MCP_URL"
    [[ -n "${SR_TOKEN_FILE:-}" ]] && export RAG_MCP_TOKEN_FILE="${SR_TOKEN_FILE/#\~/$HOME}"
fi

# Helper function to call RAG MCP server
call_rag_mcp() {
    local tool_name="$1"
    local args="$2"
    
    python3 "$HOME/.claude/hooks/lib/rag-mcp-call.py" "$tool_name" "$args" 2>/dev/null || true
}

# Determine project from working directory
PROJECT=""
if [[ -n "$CWD" ]]; then
    # Extract project name from path patterns like /home/*/arbiter/*/project or /home/*/Development/*/project
    if [[ "$CWD" =~ arbiter/([^/]+)/([^/]+) ]]; then
        PROJECT="${BASH_REMATCH[2]}"
    elif [[ "$CWD" =~ Development/([^/]+)/([^/]+) ]]; then
        PROJECT="${BASH_REMATCH[2]}"
    elif [[ "$CWD" =~ arbiter/([^/]+)$ ]]; then
        PROJECT="${BASH_REMATCH[1]}"
    fi
fi

# ============================================================================
# Parallel RAG fan-out: previously called search_decisions, search_learnings,
# and get_session_context SEQUENTIALLY, which on cold MCP/embedding paths
# wall-clocked at the 10s hook cap on ~48% of prompts. Run them concurrently
# with a per-call deadline so the worst case is max(individual) ≈ 2-3s.
# Each preserved guard (QUERY length, PROJECT presence) gates whether the
# corresponding call fires at all.
# ============================================================================

QUERY=$(printf '%s' "$USER_PROMPT" | tr '\n' ' ' | head -c 600)
RCR_TMP=$(mktemp -d -t rcr.XXXXXX) || exit 0
trap 'rm -rf "$RCR_TMP"' EXIT

if [[ "${#QUERY}" -ge 8 ]]; then
    DEC_ARGS=$(jq -n --arg q "$QUERY" '{query:$q, num_results:3}')
    LRN_ARGS=$(jq -n --arg q "$QUERY" '{query:$q, num_results:4}')
    ( timeout 3 python3 "$HOME/.claude/hooks/lib/rag-mcp-call.py" "search_decisions" "$DEC_ARGS" > "$RCR_TMP/dec" 2>/dev/null ) &
    ( timeout 3 python3 "$HOME/.claude/hooks/lib/rag-mcp-call.py" "search_learnings" "$LRN_ARGS" > "$RCR_TMP/lrn" 2>/dev/null ) &
fi
if [[ -n "$PROJECT" ]]; then
    CTX_ARGS=$(jq -n --arg project "$PROJECT" '{ project: $project }')
    ( timeout 3 python3 "$HOME/.claude/hooks/lib/rag-mcp-call.py" "get_session_context" "$CTX_ARGS" > "$RCR_TMP/ctx" 2>/dev/null ) &
fi
wait

REL_DECISIONS=$(cat "$RCR_TMP/dec" 2>/dev/null) || REL_DECISIONS=""
REL_LEARNINGS=$(cat "$RCR_TMP/lrn" 2>/dev/null) || REL_LEARNINGS=""
SESSION_CONTEXT=$(cat "$RCR_TMP/ctx" 2>/dev/null) || SESSION_CONTEXT=""

# Drop auto-logged telemetry "learnings" (quality-enforcer block counts,
# auto-syncs) -- synced metrics, not knowledge. Filter whole entries.
if [[ -n "$REL_LEARNINGS" ]]; then
    REL_LEARNINGS=$(printf '%s' "$REL_LEARNINGS" | python3 -c '
import sys
parts = sys.stdin.read().split("\n---\n")
junk = ("Quality enforcer blocked", "auto-logged", "Auto-synced from")
sys.stdout.write("\n---\n".join(p for p in parts if not any(j in p for j in junk)))
' 2>/dev/null || printf '%s' "$REL_LEARNINGS")
fi

if [[ -n "${REL_DECISIONS}${REL_LEARNINGS}" ]]; then
    echo "<relevant-prior-context>"
    echo "Auto-recalled from RAG, matched to this message. This is memory of past"
    echo "work on this stack -- answer FROM it instead of re-deriving or re-asking:"
    if [[ -n "$REL_DECISIONS" ]]; then printf '\n### Relevant past decisions\n%s\n' "$REL_DECISIONS"; fi
    if [[ -n "$REL_LEARNINGS" ]]; then printf '\n### Relevant past learnings\n%s\n' "$REL_LEARNINGS"; fi
    echo "</relevant-prior-context>"
fi

if [[ -n "$PROJECT" && -n "$SESSION_CONTEXT" ]]; then
    if echo "$SESSION_CONTEXT" | grep -q "Recent Decisions\|Recent Learnings"; then
        echo "<recent-context project=\"$PROJECT\">"
        echo "**Recent context (auto-loaded from RAG):**"
        echo "$SESSION_CONTEXT" | sed -n '/## Recent Decisions/,/## /p; /## Recent Learnings/,/## /p' | sed '$d'
        echo "</recent-context>"
    fi
fi

# ============================================================================
# 4. PATTERN-BASED REMINDERS - Keep for specific triggers
# ============================================================================
PROMPT_LOWER=$(echo "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')
OUTPUT=""

# Only add reminder if asking about past work specifically
if echo "$PROMPT_LOWER" | grep -qE 'did we|have we|last time|before|previous|remember|forgot|earlier|already'; then
    OUTPUT+="<rag-reminder>\n"
    OUTPUT+="**CHECK RAG MEMORY FIRST**: This question references past work. Use:\n"
    OUTPUT+="- \`mcp__rag__search_decisions\` for past architectural choices\n"
    OUTPUT+="- \`mcp__rag__search_learnings\` for past discoveries and gotchas\n"
    OUTPUT+="- \`mcp__rag__get_session_context\` for recent project history\n"
    OUTPUT+="</rag-reminder>\n"
fi

# Debug/fix requests - suggest checking for similar issues
if echo "$PROMPT_LOWER" | grep -qE 'fix|debug|broken|not working|error|issue|problem|wrong|fail'; then
    if [[ -z "$OUTPUT" ]]; then
        OUTPUT+="<rag-reminder>\n"
        OUTPUT+="**CHECK RAG FOR SIMILAR ISSUES**: Before debugging, search for similar past problems:\n"
        OUTPUT+="- \`mcp__rag__search_learnings\` with category='gotcha'\n"
        OUTPUT+="- \`mcp__rag__search_docs\` for relevant documentation\n"
        OUTPUT+="</rag-reminder>\n"
    fi
fi

if [[ -n "$OUTPUT" ]]; then
    echo -e "$OUTPUT"
fi

exit 0
