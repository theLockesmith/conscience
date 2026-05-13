#!/bin/bash
# Track User Prompts - Records recent user statements for source validation
# Hook: UserPromptSubmit
# Purpose: Enable 'user_stated' citations to be verified

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
PWD_HASH=$(echo "$PWD" | md5sum | cut -c1-8)
PROMPTS_FILE="$STATE_DIR/user-prompts-${PWD_HASH}.jsonl"

mkdir -p "$STATE_DIR"

# Read input
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // empty' 2>/dev/null)

# Fallback: if no user_prompt field, use raw input
if [[ -z "$PROMPT" ]]; then
    PROMPT="$INPUT"
fi

if [[ -n "$PROMPT" ]]; then
    # Store prompt (truncated to 2000 chars for storage)
    PROMPT_SHORT="${PROMPT:0:2000}"
    PROMPT_ESCAPED=$(echo "$PROMPT_SHORT" | jq -Rs '.')
    echo "{\"prompt\":$PROMPT_ESCAPED,\"timestamp\":\"$(date -Iseconds)\"}" >> "$PROMPTS_FILE"
fi

# Generate unique turn ID for RAG lookup enforcement
# Each user prompt starts a new "turn" - RAG must be consulted before infra commands
TURN_ID="$(date +%s)-$$"
echo "$TURN_ID" > "$STATE_DIR/current-turn-id.txt"

# Clear previous turn's RAG call record
> "$STATE_DIR/rag-calls-this-turn.txt"

# Keep last 50 prompts
if [[ -f "$PROMPTS_FILE" ]]; then
    LINE_COUNT=$(wc -l < "$PROMPTS_FILE")
    if (( LINE_COUNT > 50 )); then
        tail -n 50 "$PROMPTS_FILE" > "$PROMPTS_FILE.tmp"
        mv "$PROMPTS_FILE.tmp" "$PROMPTS_FILE"
    fi
fi

exit 0
