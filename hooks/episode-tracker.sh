#!/bin/bash
# Episode Tracker — V18.1 P1 client write-path
# Hook: UserPromptSubmit
#
# Detects episode boundaries (the unit of operator intent/task) and emits
# events to ~/.claude/episodes.jsonl for the shipper. Episodes are
# HYPOTHESES at write-time, refinable at consolidation. The boundary
# detection is soft on purpose: when uncertain, default to continuation
# so we don't over-segment. Consolidation can merge if it goes too fine.
#
# Per-session state at ~/.claude/session-state/episode-${session_id}.json:
#   { episode_id, started_at, last_prompt_at, intent }
#
# Defaults (P1 ships without surfaces.yaml config; tunable in P2):
#   continuation_patterns: yes / no / ok / continue / go ahead / and also / actually
#   new_intent_patterns:   let's / now / I want / switch to / new task
#   min_chars_for_new:     40
#   max_idle_minutes:      30

set -uo pipefail

EPISODES_LOG="$HOME/.claude/episodes.jsonl"
STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

# Read hook input
INPUT=$(cat || true)
PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // empty' 2>/dev/null)
SESSION_ID_CC=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[[ -n "$CWD" ]] || CWD="$PWD"
[[ -n "$PROMPT" && "$PROMPT" != "null" ]] || exit 0

# Resolve surface (sovereignty: episodes are surface-scoped)
SURFACE="unknown"
COMPANY=""
if [[ -f "$HOME/.claude/hooks/lib/surface-resolve.sh" ]]; then
    # shellcheck source=lib/surface-resolve.sh
    . "$HOME/.claude/hooks/lib/surface-resolve.sh" 2>/dev/null || true
    SR=$(sr_resolve "$CWD" 2>/dev/null) || SR=""
    IFS='|' read -r _SR_SURFACE _SR_COMPANY _SR_SERVER _SR_MCP _SR_TOKEN <<<"$SR"
    [[ -n "$_SR_SURFACE" ]] && SURFACE="$_SR_SURFACE"
    [[ -n "$_SR_COMPANY" ]] && COMPANY="$_SR_COMPANY"
fi

# Derive project from cwd (matches the convention used elsewhere)
PROJECT=""
if [[ "$CWD" =~ arbiter/([^/]+)/([^/]+) ]]; then
    PROJECT="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
elif [[ "$CWD" =~ arbiter/([^/]+)$ ]]; then
    PROJECT="${BASH_REMATCH[1]}"
fi

# Stable session_id (Claude Code's if provided, else inode+mtime of transcript)
if [[ -z "$SESSION_ID_CC" ]]; then
    pwd_hash=$(echo "$CWD" | sed 's|/|-|g' | sed 's|^-||')
    transcript_dir="$HOME/.claude/projects/-${pwd_hash}"
    if [[ -d "$transcript_dir" ]]; then
        latest=$(ls -t "$transcript_dir"/*.jsonl 2>/dev/null | head -1)
        [[ -n "$latest" ]] && SESSION_ID_CC=$(stat -c '%i-%Y' "$latest" 2>/dev/null)
    fi
fi
[[ -n "$SESSION_ID_CC" ]] || SESSION_ID_CC="unknown-$$"

STATE_FILE="$STATE_DIR/episode-${SESSION_ID_CC}.json"
NOW_TS=$(date -Iseconds)
NOW_EPOCH=$(date +%s)

# Boundary detection — soft heuristic, defaults to continuation on uncertainty
PROMPT_LEN=${#PROMPT}
PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

is_continuation() {
    # Operator's explicit override patterns from the V18.1 design
    [[ "$PROMPT_LOWER" =~ ^(yes|no|ok|okay|continue|go ahead|and also|actually|fine|sure|please|drop it)( |$|\.|,|\!) ]] && return 0
    # Length: very short prompts are almost always follow-ups
    (( PROMPT_LEN < 40 )) && return 0
    return 1
}

is_new_intent() {
    [[ "$PROMPT_LOWER" =~ ^(let.?s|now |i want|switch to|new task|let me|new question) ]] && return 0
    return 1
}

# Decide: do we have a current episode for this session, and is this prompt
# continuing it or starting a new one?
DECISION="new"          # new | continue
BOUNDARY_SIGNAL="heuristic"

CURRENT_EPISODE_ID=""
CURRENT_STARTED_AT=""
LAST_PROMPT_EPOCH=0
if [[ -f "$STATE_FILE" ]]; then
    CURRENT_EPISODE_ID=$(jq -r '.episode_id // ""' "$STATE_FILE" 2>/dev/null)
    CURRENT_STARTED_AT=$(jq -r '.started_at // ""' "$STATE_FILE" 2>/dev/null)
    LAST_PROMPT_EPOCH=$(jq -r '.last_prompt_epoch // 0' "$STATE_FILE" 2>/dev/null)
fi

if [[ -z "$CURRENT_EPISODE_ID" ]]; then
    DECISION="new"; BOUNDARY_SIGNAL="bootstrap"
elif (( NOW_EPOCH - LAST_PROMPT_EPOCH > 1800 )); then
    # 30+ minute idle gap — close + open
    DECISION="new"; BOUNDARY_SIGNAL="idle"
elif is_new_intent; then
    DECISION="new"; BOUNDARY_SIGNAL="new_intent_pattern"
elif is_continuation; then
    DECISION="continue"; BOUNDARY_SIGNAL="continuation"
else
    # Uncertain — default to continuation. Consolidation can split if wrong.
    DECISION="continue"; BOUNDARY_SIGNAL="default_continue"
fi

# Generate episode_id from session + timestamp (stable, no random)
make_episode_id() {
    local sid="$1"
    local ts="$2"
    # take last 12 hex of an SHA1 over sid+ts for a short stable id
    printf '%s|%s' "$sid" "$ts" | sha1sum | cut -c1-12 | xargs printf 'ep-%s'
}

PROMPT_HEAD=$(printf '%s' "$PROMPT" | tr '\n' ' ' | head -c 200 | sed 's/"/\\"/g')

if [[ "$DECISION" == "new" ]]; then
    # Close previous episode if any
    if [[ -n "$CURRENT_EPISODE_ID" ]]; then
        jq -nc \
            --arg event "end" \
            --arg episode_id "$CURRENT_EPISODE_ID" \
            --arg ended_at "$NOW_TS" \
            --arg boundary_signal "$BOUNDARY_SIGNAL" \
            '{event:$event, episode_id:$episode_id, ended_at:$ended_at, boundary_signal:$boundary_signal}' \
            >> "$EPISODES_LOG"
    fi
    # Open new
    NEW_EPISODE_ID=$(make_episode_id "$SESSION_ID_CC" "$NOW_TS")
    jq -nc \
        --arg event "start" \
        --arg episode_id "$NEW_EPISODE_ID" \
        --arg surface "$SURFACE" \
        --arg company "$COMPANY" \
        --arg project "$PROJECT" \
        --arg cwd "$CWD" \
        --arg session_id "$SESSION_ID_CC" \
        --arg started_at "$NOW_TS" \
        --arg boundary_signal "$BOUNDARY_SIGNAL" \
        --arg intent "$PROMPT_HEAD" \
        '{event:$event, episode_id:$episode_id, surface:$surface, company:$company, project:$project, cwd:$cwd, session_id:$session_id, started_at:$started_at, boundary_signal:$boundary_signal, intent:$intent}' \
        >> "$EPISODES_LOG"
    # Update per-session state
    jq -n \
        --arg episode_id "$NEW_EPISODE_ID" \
        --arg started_at "$NOW_TS" \
        --argjson last_prompt_epoch "$NOW_EPOCH" \
        --arg intent "$PROMPT_HEAD" \
        '{episode_id:$episode_id, started_at:$started_at, last_prompt_epoch:$last_prompt_epoch, intent:$intent}' \
        > "$STATE_FILE"
else
    # Continuation: append a prompt event to the existing episode
    jq -nc \
        --arg event "prompt" \
        --arg episode_id "$CURRENT_EPISODE_ID" \
        --arg ts "$NOW_TS" \
        --arg text "$PROMPT_HEAD" \
        --arg source "continuation" \
        '{event:$event, episode_id:$episode_id, ts:$ts, text:$text, source:$source}' \
        >> "$EPISODES_LOG"
    # Bump last_prompt_epoch
    if [[ -f "$STATE_FILE" ]]; then
        tmp=$(mktemp)
        jq --argjson epoch "$NOW_EPOCH" '.last_prompt_epoch = $epoch' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    fi
fi

exit 0
