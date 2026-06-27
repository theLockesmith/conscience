#!/bin/bash
# llm-usage-logger.sh
#
# Revives the dead llm-usage.jsonl stream that the old claude-wrapper.sh
# used to emit. The wrapper is no longer in the invocation path (claude
# binary is called directly), so its start/end events stopped flowing
# 2026-06-09. This hook puts the start signal back: one line on every
# SessionStart, captured as JSON in ~/.claude/llm-usage.jsonl — the same
# path the hook-metrics-shipper already reads.
#
# Session END is intentionally not written here: Claude Code's Stop hook
# fires on every turn, not session end, and a reliable end-of-session
# signal doesn't exist. The shipper computes duration from successor
# session start timestamps (or transcript mtimes) downstream.

set -uo pipefail

LOG_FILE="${LLM_USAGE_LOG:-$HOME/.claude/llm-usage.jsonl}"

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null)
SOURCE=$(jq -r '.source // empty' <<<"$INPUT" 2>/dev/null)

# Fall back if session_id is missing — the transcript filename is the
# session_id by convention.
if [[ -z "$SESSION_ID" && -n "$TRANSCRIPT_PATH" ]]; then
    SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
fi
[[ -n "$SESSION_ID" ]] || SESSION_ID="unknown-$$"

# Provider is anthropic in practice; preserved for the schema the shipper
# already expects (it had a multi-provider future in mind).
PROVIDER="${LLM_PROVIDER:-anthropic}"

jq -nc \
    --arg sid "$SESSION_ID" \
    --arg ts "$(date -Iseconds)" \
    --arg provider "$PROVIDER" \
    --arg pwd "$PWD" \
    --arg source "$SOURCE" \
    '{
        session_id: $sid,
        event_type: "start",
        provider: $provider,
        occurred_at: $ts,
        project_path: $pwd,
        entity: "",
        metadata: { source: $source }
    }' >> "$LOG_FILE" 2>/dev/null || true

exit 0
