#!/bin/bash
# Workflow Checkpoint - Automatic checkpoints and drift detection
# Hook: Stop
# Location: ~/.claude/hooks/workflow-checkpoint.sh
#
# Tracks workflow progress and creates automatic checkpoints:
# - Every 50 tool calls
# - Every 30 minutes of active work
# - When explicitly requested via /checkpoint
#
# Also detects drift from original task using local LLM.

set -uo pipefail

STATE_DIR="$HOME/.claude/workflow-state"
CHECKPOINT_LOG="$HOME/.claude/workflow-checkpoints.log"
CONFIG_FILE="$HOME/.claude/workflow-config.yaml"
GRAPHQL_URL="${RAG_GRAPHQL_URL:-http://127.0.0.1:8765/graphql}"
OLLAMA_URL="${OLLAMA_URL:-http://10.0.4.10:11434}"

# Thresholds - read from YAML config
if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
    TOOL_CALL_THRESHOLD=$(yq -r '.checkpoints.tool_call_threshold // 50' "$CONFIG_FILE")
    TIME_THRESHOLD_MINUTES=$(yq -r '.checkpoints.time_threshold_minutes // 30' "$CONFIG_FILE")
    DRIFT_DETECTION=$(yq -r '.checkpoints.drift_detection // true' "$CONFIG_FILE")
    DRIFT_WARN_FREQUENCY=$(yq -r '.checkpoints.drift_warn_frequency // 3' "$CONFIG_FILE")
else
    TOOL_CALL_THRESHOLD=50
    TIME_THRESHOLD_MINUTES=30
    DRIFT_DETECTION=true
    DRIFT_WARN_FREQUENCY=3
fi

mkdir -p "$STATE_DIR"

# Get current workflow state file based on PWD
PWD_HASH=$(echo "$PWD" | md5sum | cut -c1-8)
WORKFLOW_STATE="$STATE_DIR/checkpoint-state-${PWD_HASH}.json"

# Read input (Stop hook receives response)
INPUT=$(cat)

# Initialize state if doesn't exist
init_state() {
    local first_prompt="$1"
    cat > "$WORKFLOW_STATE" << EOF
{
    "workflow_id": "workflow-$(date +%s)-$RANDOM",
    "original_task": $(echo "$first_prompt" | head -c 500 | jq -Rs '.'),
    "started_at": "$(date -Iseconds)",
    "tool_call_count": 0,
    "last_checkpoint_at": "$(date -Iseconds)",
    "last_checkpoint_id": null,
    "drift_warnings": 0
}
EOF
}

# Read current state
read_state() {
    if [[ -f "$WORKFLOW_STATE" ]]; then
        cat "$WORKFLOW_STATE"
    else
        echo "{}"
    fi
}

# Update state field
update_state() {
    local key="$1"
    local value="$2"
    local current
    current=$(read_state)
    echo "$current" | jq --arg k "$key" --argjson v "$value" '.[$k] = $v' > "$WORKFLOW_STATE.tmp"
    mv "$WORKFLOW_STATE.tmp" "$WORKFLOW_STATE"
}

# Increment tool call count
increment_tool_calls() {
    local current
    current=$(read_state)
    local count
    count=$(echo "$current" | jq -r '.tool_call_count // 0')
    update_state "tool_call_count" "$((count + 1))"
    echo "$((count + 1))"
}

# Check if checkpoint needed
check_checkpoint_needed() {
    local state
    state=$(read_state)

    local tool_count
    tool_count=$(echo "$state" | jq -r '.tool_call_count // 0')

    local last_checkpoint
    last_checkpoint=$(echo "$state" | jq -r '.last_checkpoint_at // empty')

    # Check tool call threshold
    if (( tool_count >= TOOL_CALL_THRESHOLD )); then
        echo "tool_calls:$tool_count"
        return 0
    fi

    # Check time threshold
    if [[ -n "$last_checkpoint" ]]; then
        local last_ts
        last_ts=$(date -d "$last_checkpoint" +%s 2>/dev/null || echo 0)
        local now_ts
        now_ts=$(date +%s)
        local diff_minutes
        diff_minutes=$(( (now_ts - last_ts) / 60 ))

        if (( diff_minutes >= TIME_THRESHOLD_MINUTES )); then
            echo "time:${diff_minutes}m"
            return 0
        fi
    fi

    return 1
}

# Create checkpoint via unified script (extracts todos, key files, context from transcript)
create_checkpoint() {
    local trigger_reason="$1"
    local state
    state=$(read_state)

    local original_task
    original_task=$(echo "$state" | jq -r '.original_task // "Unknown task"')
    local tool_count
    tool_count=$(echo "$state" | jq -r '.tool_call_count // 0')

    # Build checkpoint description
    local description="Auto-checkpoint ($trigger_reason): $tool_count tool calls. Task: ${original_task:0:100}"

    # Call unified checkpoint script (extracts todos/files from transcript automatically)
    local checkpoint_id
    checkpoint_id=$("$HOME/.claude/scripts/unified-checkpoint.sh" \
        --description "$description" \
        --trigger "periodic" \
        2>/dev/null)

    if [[ -n "$checkpoint_id" && "$checkpoint_id" =~ ^[0-9a-f-]{36}$ ]]; then
        # Update state
        update_state "last_checkpoint_at" "\"$(date -Iseconds)\""
        update_state "last_checkpoint_id" "\"$checkpoint_id\""
        update_state "tool_call_count" "0"

        # Log
        echo "[$(date -Iseconds)] Checkpoint created: $checkpoint_id ($trigger_reason)" >> "$CHECKPOINT_LOG"

        # Output notification to Claude
        echo "<workflow-checkpoint>"
        echo "Automatic checkpoint saved (trigger: $trigger_reason)"
        echo "Checkpoint ID: $checkpoint_id"
        echo "Original task: ${original_task:0:100}..."
        echo "</workflow-checkpoint>"

        return 0
    else
        echo "[$(date -Iseconds)] Checkpoint failed: $checkpoint_id" >> "$CHECKPOINT_LOG"
        return 1
    fi
}

# Detect drift using local LLM
detect_drift() {
    local state
    state=$(read_state)

    local original_task
    original_task=$(echo "$state" | jq -r '.original_task // empty')

    # Skip if no original task
    [[ -z "$original_task" ]] && return 1

    # Get recent activity summary from response
    local recent_activity
    recent_activity=$(echo "$INPUT" | jq -r '.response // empty' | head -c 500)

    # Skip if no recent activity
    [[ -z "$recent_activity" ]] && return 1

    # Use local LLM to assess drift
    local prompt="Original task: $original_task

Recent activity: $recent_activity

Question: Is the recent activity still aligned with the original task?
Answer with just 'aligned' or 'drifted' followed by a brief reason."

    local response
    response=$(curl -s --max-time 5 \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"qwen2.5-coder:7b\", \"prompt\": $(echo "$prompt" | jq -Rs '.'), \"stream\": false}" \
        "$OLLAMA_URL/api/generate" 2>/dev/null)

    local answer
    answer=$(echo "$response" | jq -r '.response // empty' | tr '[:upper:]' '[:lower:]')

    if echo "$answer" | grep -q "drifted"; then
        local drift_count
        drift_count=$(echo "$state" | jq -r '.drift_warnings // 0')
        update_state "drift_warnings" "$((drift_count + 1))"

        # Only warn on every Nth drift detection (configurable, reduces noise)
        if (( (drift_count + 1) % DRIFT_WARN_FREQUENCY == 0 )); then
            echo "<workflow-drift-warning>"
            echo "**Drift detected** from original task:"
            echo "> ${original_task:0:150}..."
            echo ""
            echo "Current activity appears to have diverged. Consider:"
            echo "- Returning to original task"
            echo "- Explicitly expanding scope"
            echo "- Creating checkpoint and starting new workflow"
            echo "</workflow-drift-warning>"
        fi

        return 0
    fi

    return 1
}

# Main logic

# Check if workflow state exists, if not check if this is workflow start
if [[ ! -f "$WORKFLOW_STATE" ]]; then
    # Check if workflow-detector created a workflow ID
    WORKFLOW_ID_FILE="$STATE_DIR/workflow-${PWD_HASH}.id"
    if [[ -f "$WORKFLOW_ID_FILE" ]]; then
        # Workflow just started - initialize state
        # Try to get original prompt from routing state
        ROUTING_STATE="$HOME/.claude/session-state/current-routing.json"
        if [[ -f "$ROUTING_STATE" ]]; then
            # We don't have the original prompt here, will capture on next run
            init_state "Task in progress (capturing context)"
        fi
    else
        # No workflow active
        exit 0
    fi
fi

# Increment tool call count
CURRENT_COUNT=$(increment_tool_calls)

# Check if checkpoint needed
if TRIGGER=$(check_checkpoint_needed); then
    create_checkpoint "$TRIGGER"
fi

# Check for drift (only every 10 tool calls to avoid overhead)
if [[ "$DRIFT_DETECTION" == "true" ]] && (( CURRENT_COUNT % 10 == 0 )); then
    detect_drift
fi

exit 0
