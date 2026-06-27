#!/bin/bash
# Agent Activity Tracker
# Hook: SubagentStop (and PreToolUse for Task tool)
# Logs agent invocations and completions for visualization
#
# Creates ~/.claude/agent-activity.jsonl
#
# Tracks:
#   - session_id: derived from Claude transcript path (unique per session)
#   - workflow_id: from workflow-detector hook (groups agents in workflow)
#   - parallel_group_id: groups agents launched within same second (parallel execution)

set -uo pipefail

AGENT_LOG="$HOME/.claude/agent-activity.jsonl"
WORKFLOW_STATE_DIR="$HOME/.claude/workflow-state"
PARALLEL_STATE_DIR="$HOME/.claude/parallel-state"
mkdir -p "$PARALLEL_STATE_DIR"

# Derive session_id from Claude's transcript path pattern
# Claude stores transcripts at ~/.claude/projects/-{path-with-dashes}/
get_session_id() {
    local pwd_hash=$(echo "$PWD" | sed 's|/|-|g' | sed 's|^-||')
    local transcript_dir="$HOME/.claude/projects/-${pwd_hash}"

    if [[ -d "$transcript_dir" ]]; then
        # Use the most recent .jsonl file's inode + mtime as session ID
        local latest=$(ls -t "$transcript_dir"/*.jsonl 2>/dev/null | head -1)
        if [[ -n "$latest" ]]; then
            stat -c '%i-%Y' "$latest" 2>/dev/null || echo "unknown"
            return
        fi
    fi

    # Fallback: use PPID + PWD hash
    echo "pid-$$-${pwd_hash:0:16}"
}

# Get current workflow_id if one is active for this project
get_workflow_id() {
    local pwd_hash=$(echo "$PWD" | md5sum | cut -c1-8)
    local workflow_file="$WORKFLOW_STATE_DIR/workflow-${pwd_hash}.id"

    if [[ -f "$workflow_file" ]]; then
        # Check if workflow file is recent (within last 30 minutes)
        local file_age=$(( $(date +%s) - $(stat -c %Y "$workflow_file") ))
        if (( file_age < 1800 )); then
            cat "$workflow_file"
            return
        fi
    fi
    echo ""
}

# Get or create parallel_group_id for agents launched in the same second
# This detects parallel execution by grouping agents invoked within 1 second
get_parallel_group_id() {
    local current_ts=$(date +%s)
    local pwd_hash=$(echo "$PWD" | md5sum | cut -c1-8)
    local parallel_file="$PARALLEL_STATE_DIR/parallel-${pwd_hash}.state"

    if [[ -f "$parallel_file" ]]; then
        # Read last timestamp and group ID
        local last_ts last_group_id
        read -r last_ts last_group_id < "$parallel_file"

        # If within 1 second, reuse the same group ID
        if (( current_ts - last_ts <= 1 )); then
            echo "$last_group_id"
            return
        fi
    fi

    # Create new group ID (timestamp-based)
    local new_group_id="pg-${current_ts}-$$"
    echo "$current_ts $new_group_id" > "$parallel_file"
    echo "$new_group_id"
}

SESSION_ID=$(get_session_id)
WORKFLOW_ID=$(get_workflow_id)
PARALLEL_GROUP_ID=""

# Read hook input
HOOK_INPUT=$(cat)
HOOK_TYPE="${CLAUDE_HOOK_TYPE:-SubagentStop}"

# Per-session FIFO queue file pairs invoke→complete so we can compute
# duration_ms (Claude Code's SubagentStop does NOT send duration_ms; the
# pre-2026-06-27 hook defaulted it to 0). Each invoke appends one line
# with {start_ms, routing_decision_id, agent_type, model}; SubagentStop
# shifts the oldest entry and computes duration. FIFO ordering is wrong
# for parallel agents (completion order ≠ invoke order), but the
# parallel_group_id field already captures parallelism and aggregate
# stats survive the per-event mis-pairing.
QUEUE_DIR="$PARALLEL_STATE_DIR/agent-queue"
mkdir -p "$QUEUE_DIR"
QUEUE_FILE="$QUEUE_DIR/${SESSION_ID}.jsonl"
LOCK_FILE="$QUEUE_DIR/${SESSION_ID}.lock"

# Pull the current routing decision (model-router writes prompt_hash here
# at UserPromptSubmit time; we propagate it as routing_decision_id so the
# routing_compliance view can join routing_decisions ↔ agent_metrics on a
# stable key instead of a flaky time window).
ROUTING_STATE_FILE="$HOME/.claude/session-state/current-routing.json"
ROUTING_DECISION_ID=""
if [[ -f "$ROUTING_STATE_FILE" ]]; then
    ROUTING_DECISION_ID=$(jq -r '.prompt_hash // ""' "$ROUTING_STATE_FILE" 2>/dev/null)
fi

# Millisecond timestamp without Math.random/Date.now -- portable via date %N
now_ms() {
    local ns
    ns=$(date +%s%N)
    echo "$(( ns / 1000000 ))"
}

# For PreToolUse on Task tool - log agent invocation
if [[ "$HOOK_TYPE" == "PreToolUse" ]]; then
    TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null)

    if [[ "$TOOL_NAME" == "Task" ]]; then
        # Extract agent info from Task tool input
        SUBAGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // "unknown"' 2>/dev/null)
        DESCRIPTION=$(echo "$HOOK_INPUT" | jq -r '.tool_input.description // ""' 2>/dev/null)
        PROMPT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null | head -c 200)
        BACKGROUND=$(echo "$HOOK_INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
        MODEL=$(echo "$HOOK_INPUT" | jq -r '.tool_input.model // "default"' 2>/dev/null)

        # Get parallel group ID for detecting parallel agent launches
        PARALLEL_GROUP_ID=$(get_parallel_group_id)
        START_MS=$(now_ms)

        # Push to per-session FIFO queue so SubagentStop can compute duration
        (
            flock -x 9
            jq -nc \
                --arg start_ms "$START_MS" \
                --arg routing_id "$ROUTING_DECISION_ID" \
                --arg agent_type "$SUBAGENT_TYPE" \
                --arg model "$MODEL" \
                --arg parallel_group_id "$PARALLEL_GROUP_ID" \
                '{start_ms:($start_ms|tonumber), routing_decision_id:$routing_id, agent_type:$agent_type, model:$model, parallel_group_id:$parallel_group_id}' \
                >> "$QUEUE_FILE"
        ) 9>"$LOCK_FILE"

        # Log invocation with parallel_group_id and routing_decision_id
        printf '{"ts":"%s","event":"invoke","agent":"%s","desc":"%s","prompt":"%s","background":%s,"model":"%s","pwd":"%s","session_id":"%s","workflow_id":"%s","parallel_group_id":"%s","routing_decision_id":"%s"}\n' \
            "$(date -Iseconds)" \
            "$SUBAGENT_TYPE" \
            "$DESCRIPTION" \
            "$(echo "$PROMPT" | tr -d '\n' | sed 's/"/\\"/g')" \
            "$BACKGROUND" \
            "$MODEL" \
            "$PWD" \
            "$SESSION_ID" \
            "$WORKFLOW_ID" \
            "$PARALLEL_GROUP_ID" \
            "$ROUTING_DECISION_ID" >> "$AGENT_LOG"
    fi
fi

# For SubagentStop - log agent completion
if [[ "$HOOK_TYPE" == "SubagentStop" ]]; then
    # Claude Code's SubagentStop payload only reliably carries agent_id;
    # the rest (agent_type, duration_ms, success) is missing or zero.
    # We recover them by popping the oldest invoke off the queue.
    AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '.agent_id // .task_id // "unknown"' 2>/dev/null)
    SUCCESS=$(echo "$HOOK_INPUT" | jq -r '.success // true' 2>/dev/null)
    RESULT_LEN=$(echo "$HOOK_INPUT" | jq -r '.result // "" | length' 2>/dev/null || echo 0)

    AGENT_TYPE="unknown"
    DURATION=0
    POPPED_ROUTING_ID=""
    POPPED_MODEL=""
    POPPED_PARALLEL_GROUP=""

    if [[ -f "$QUEUE_FILE" ]]; then
        (
            flock -x 9
            FIRST=$(head -1 "$QUEUE_FILE" 2>/dev/null)
            if [[ -n "$FIRST" ]]; then
                # Atomic shift: rewrite without the first line
                sed -i '1d' "$QUEUE_FILE"
                # If queue is empty after pop, remove the file
                [[ -s "$QUEUE_FILE" ]] || rm -f "$QUEUE_FILE"
                # Surface the popped values to the outer scope via stdout
                # of this subshell, parsed below.
                echo "$FIRST" > "$QUEUE_FILE.popped.$$"
            fi
        ) 9>"$LOCK_FILE"

        if [[ -f "$QUEUE_FILE.popped.$$" ]]; then
            FIRST=$(cat "$QUEUE_FILE.popped.$$" 2>/dev/null)
            rm -f "$QUEUE_FILE.popped.$$"
            if [[ -n "$FIRST" ]]; then
                START_MS=$(echo "$FIRST" | jq -r '.start_ms // 0' 2>/dev/null)
                POPPED_ROUTING_ID=$(echo "$FIRST" | jq -r '.routing_decision_id // ""' 2>/dev/null)
                AGENT_TYPE=$(echo "$FIRST" | jq -r '.agent_type // "unknown"' 2>/dev/null)
                POPPED_MODEL=$(echo "$FIRST" | jq -r '.model // ""' 2>/dev/null)
                POPPED_PARALLEL_GROUP=$(echo "$FIRST" | jq -r '.parallel_group_id // ""' 2>/dev/null)
                NOW_MS=$(now_ms)
                if [[ "$START_MS" != "0" && -n "$START_MS" ]]; then
                    DURATION=$(( NOW_MS - START_MS ))
                fi
            fi
        fi
    fi

    # Log completion with computed duration_ms and propagated routing_decision_id
    printf '{"ts":"%s","event":"complete","agent":"%s","agent_id":"%s","success":%s,"duration_ms":%d,"result_bytes":%d,"pwd":"%s","session_id":"%s","workflow_id":"%s","parallel_group_id":"%s","routing_decision_id":"%s","model":"%s"}\n' \
        "$(date -Iseconds)" \
        "$AGENT_TYPE" \
        "$AGENT_ID" \
        "$SUCCESS" \
        "$DURATION" \
        "$RESULT_LEN" \
        "$PWD" \
        "$SESSION_ID" \
        "$WORKFLOW_ID" \
        "$POPPED_PARALLEL_GROUP" \
        "$POPPED_ROUTING_ID" \
        "$POPPED_MODEL" >> "$AGENT_LOG"
fi

exit 0
