#!/bin/bash
# RAG Call Tracker
# Hook: PostToolUse (mcp__rag__ matcher)
#
# Marks that RAG tools were called, clearing enforcement blocks.
# Creates verification file used by verify-infra-target.sh to allow
# infrastructure commands after RAG verification.

STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"
SESSION_ID=$(echo "$PWD" | md5sum | cut -c1-16)
STATE_FILE="$STATE_DIR/${SESSION_ID}.state"
RAG_VERIFIED_FILE="$STATE_DIR/${SESSION_ID}.rag_verified"

# Read tool input to see which RAG tool was called
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only these tools actually load session context
CONTEXT_LOADING_TOOLS="search_learnings|search_decisions|search_docs|search_instructions|get_session_context|get_project_context|reason_and_search"

# If state file exists, check if this is a context-loading tool
if [[ -f "$STATE_FILE" ]]; then
    if [[ "$TOOL_NAME" =~ ($CONTEXT_LOADING_TOOLS) ]]; then
        # Update rag_called to 1 - only for context-loading tools
        sed -i 's/^rag_called=.*/rag_called=1/' "$STATE_FILE"
        echo "[$(date -Iseconds)] Context loaded via $TOOL_NAME, enforcement cleared" >> "$HOME/.claude/rag-enforcement.log"
    fi
fi

# Create/touch verification file for infrastructure command enforcement
# This allows infrastructure commands after RAG verification
touch "$RAG_VERIFIED_FILE"
echo "[$(date -Iseconds)] RAG verified: $TOOL_NAME" >> "$HOME/.claude/infra-verification.log"

# Record RAG call for current turn (used by require-rag-lookup.sh +
# verify-infra-target.sh + require-rag-pretooluse.sh).
#
# Format: one line per call, with tab-separated fields:
#   <turn-id>\t<tool-name>\tQUERY\t<query-text>
#   <turn-id>\t<tool-name>\tRESULT\t<first 4KB of response>
#
# QUERY captures user's intent (what they're searching for).
# RESULT captures what came back (what to substring-match for target
# tokens in V17 verify-infra-target's `rag_results_this_turn_mention`
# check). Newlines/tabs in the captured content are stripped to one
# line so per-line consumers like grep work.
TURN_ID_FILE="$STATE_DIR/current-turn-id.txt"
RAG_TURNS_FILE="$STATE_DIR/rag-calls-this-turn.txt"
if [[ -f "$TURN_ID_FILE" ]]; then
    CURRENT_TURN=$(cat "$TURN_ID_FILE")
    # Legacy line kept for backwards compatibility with consumers that
    # only check call-presence-by-tool-name.
    echo "${CURRENT_TURN}:${TOOL_NAME}" >> "$RAG_TURNS_FILE"
    # New: capture query + truncated response. Use printf %q to make
    # tab-separated lines safely greppable.
    QUERY=$(echo "$INPUT" | jq -r '.tool_input.query // .tool_input.text // empty' 2>/dev/null \
        | tr '\n\t' '  ' | head -c 2048)
    RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // empty' 2>/dev/null \
        | tr '\n\t' '  ' | head -c 4096)
    if [[ -n "$QUERY" ]]; then
        printf '%s\t%s\tQUERY\t%s\n' "$CURRENT_TURN" "$TOOL_NAME" "$QUERY" \
            >> "$RAG_TURNS_FILE"
    fi
    if [[ -n "$RESPONSE" ]]; then
        printf '%s\t%s\tRESULT\t%s\n' "$CURRENT_TURN" "$TOOL_NAME" "$RESPONSE" \
            >> "$RAG_TURNS_FILE"
    fi
fi

# Record the timestamp of the last RAG context-load. This is the time-window
# fallback the require-rag-* hooks use: the per-turn turn-id key is fragile
# (background-task / monitor / system events fire UserPromptSubmit, which
# rolls current-turn-id.txt mid-turn and orphans an earlier RAG call). The
# timestamp survives those rolls so a genuine recent RAG search still counts.
if [[ "$TOOL_NAME" =~ ($CONTEXT_LOADING_TOOLS) ]]; then
    date +%s > "$STATE_DIR/last-rag-search.txt"
fi


# V17 Phase 5: verify_action recording.
case "$TOOL_NAME" in
    *verify_action)
        VERIFY_LOG="$STATE_DIR/verify-actions-this-turn.jsonl"
        INTENT_AND_TARGETS=$(echo "$INPUT" | jq -c \
            '{intent: (.tool_input.intent // ""), targets: (.tool_input.targets // [])}' \
            2>/dev/null)
        if [[ -n "$INTENT_AND_TARGETS" && "$INTENT_AND_TARGETS" != "null" ]]; then
            echo "$INTENT_AND_TARGETS" >> "$VERIFY_LOG"
        fi
        ;;
esac

exit 0
