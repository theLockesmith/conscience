#!/bin/bash
# Enforce RAG Search Before Giving Up
# Hook: Stop
# Purpose: BLOCK responses that claim something is impossible/unavailable
#          unless RAG was searched first to verify there's no documented solution.
#
# Created: 2026-05-07 after user feedback about deflection without RAG lookup.
# Quote: "I shouldn't even have to tell you to search the RAG, first of all.
#         Then when I fucking tell you to do so, FUCKING DO IT."

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
PWD_HASH=$(echo "$PWD" | md5sum | cut -c1-8)

# Read the response
INPUT=$(cat)
RESPONSE=$(echo "$INPUT" | jq -r '.response // empty' 2>/dev/null)
[[ -z "$RESPONSE" ]] && exit 0

RESPONSE_LOWER=$(echo "$RESPONSE" | tr '[:upper:]' '[:lower:]')

# Patterns that indicate "giving up" without searching for a solution
GIVEUP_PATTERNS=(
    "can't access"
    "cannot access"
    "not available"
    "isn't available"
    "is not available"
    "doesn't have access"
    "does not have access"
    "no way to"
    "not possible"
    "isn't possible"
    "cannot be done"
    "can't be done"
    "unable to"
    "no access to"
    "don't have access"
    "i don't have"
    "i cannot"
    "i can't"
    "not supported"
    "isn't supported"
    "doesn't support"
    "won't work"
    "will not work"
    "can't find"
    "cannot find"
    "doesn't exist"
    "does not exist"
    "not configured"
    "isn't configured"
)

# Check if response contains give-up language
FOUND_GIVEUP=""
for pattern in "${GIVEUP_PATTERNS[@]}"; do
    if [[ "$RESPONSE_LOWER" == *"$pattern"* ]]; then
        FOUND_GIVEUP="$pattern"
        break
    fi
done

# If no give-up pattern found, allow through
[[ -z "$FOUND_GIVEUP" ]] && exit 0

# Check if RAG was searched in this conversation turn
# Look for evidence of RAG calls in the response itself
RAG_EVIDENCE_PATTERNS=(
    "mcp__rag__search"
    "search_docs"
    "search_learnings"
    "search_decisions"
    "get_project_context"
    "get_session_context"
    "rag search"
    "searched rag"
    "rag showed"
    "rag indicates"
    "according to rag"
    "from rag"
    "per rag"
    "rag confirms"
    "checked rag"
    "documentation shows"
    "docs show"
    "the documentation"
    "found in"
    "reference shows"
)

for pattern in "${RAG_EVIDENCE_PATTERNS[@]}"; do
    if [[ "$RESPONSE_LOWER" == *"$pattern"* ]]; then
        # RAG was searched, allow through
        exit 0
    fi
done

# Check session state for RAG calls this turn
RAG_CALLS_FILE="$STATE_DIR/rag-calls-this-turn.txt"
if [[ -f "$RAG_CALLS_FILE" ]] && [[ -s "$RAG_CALLS_FILE" ]]; then
    # RAG was called this turn, allow through
    exit 0
fi

# Block the response - RAG wasn't searched before claiming impossibility
cat << 'EOF' >&2
╔═══════════════════════════════════════════════════════════════════════════════╗
║ BLOCKED: GAVE UP WITHOUT SEARCHING RAG                                         ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║ You claimed something is unavailable/impossible without first searching RAG    ║
║ for documented solutions.                                                      ║
║                                                                                ║
║ BEFORE saying "can't", "not available", etc., you MUST:                        ║
║   1. mcp__rag__search_docs - Search for documented procedures                  ║
║   2. mcp__rag__search_learnings - Check for gotchas/patterns                   ║
║   3. mcp__rag__search_instructions - Check CLAUDE.md files                     ║
║                                                                                ║
║ The information you need is probably documented. LOOK FOR IT.                  ║
╚═══════════════════════════════════════════════════════════════════════════════╝
EOF
exit 2
