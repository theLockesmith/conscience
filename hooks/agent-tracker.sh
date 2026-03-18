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

set -uo pipefail

AGENT_LOG="$HOME/.claude/agent-activity.jsonl"
WORKFLOW_STATE_DIR="$HOME/.claude/workflow-state"

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

SESSION_ID=$(get_session_id)
WORKFLOW_ID=$(get_workflow_id)

# Read hook input
HOOK_INPUT=$(cat)
HOOK_TYPE="${CLAUDE_HOOK_TYPE:-SubagentStop}"

# For PreToolUse on Task tool - log agent invocation
if [[ "$HOOK_TYPE" == "PreToolUse" ]]; then
    TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_input.tool_name // ""' 2>/dev/null)

    if [[ "$TOOL_NAME" == "Task" ]]; then
        # Extract agent info from Task tool input
        SUBAGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.tool_input.input.subagent_type // "unknown"' 2>/dev/null)
        DESCRIPTION=$(echo "$HOOK_INPUT" | jq -r '.tool_input.input.description // ""' 2>/dev/null)
        PROMPT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.input.prompt // ""' 2>/dev/null | head -c 200)
        BACKGROUND=$(echo "$HOOK_INPUT" | jq -r '.tool_input.input.run_in_background // false' 2>/dev/null)
        MODEL=$(echo "$HOOK_INPUT" | jq -r '.tool_input.input.model // "default"' 2>/dev/null)

        # Log invocation
        printf '{"ts":"%s","event":"invoke","agent":"%s","desc":"%s","prompt":"%s","background":%s,"model":"%s","pwd":"%s","session_id":"%s","workflow_id":"%s"}\n' \
            "$(date -Iseconds)" \
            "$SUBAGENT_TYPE" \
            "$DESCRIPTION" \
            "$(echo "$PROMPT" | tr -d '\n' | sed 's/"/\\"/g')" \
            "$BACKGROUND" \
            "$MODEL" \
            "$PWD" \
            "$SESSION_ID" \
            "$WORKFLOW_ID" >> "$AGENT_LOG"
    fi
fi

# For SubagentStop - log agent completion
if [[ "$HOOK_TYPE" == "SubagentStop" ]]; then
    # Extract completion info
    AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '.agent_id // .task_id // "unknown"' 2>/dev/null)
    AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.agent_type // .task_type // "unknown"' 2>/dev/null)
    SUCCESS=$(echo "$HOOK_INPUT" | jq -r '.success // true' 2>/dev/null)
    DURATION=$(echo "$HOOK_INPUT" | jq -r '.duration_ms // 0' 2>/dev/null)
    RESULT_LEN=$(echo "$HOOK_INPUT" | jq -r '.result // "" | length' 2>/dev/null || echo 0)

    # Log completion
    printf '{"ts":"%s","event":"complete","agent":"%s","agent_id":"%s","success":%s,"duration_ms":%d,"result_bytes":%d,"pwd":"%s","session_id":"%s","workflow_id":"%s"}\n' \
        "$(date -Iseconds)" \
        "$AGENT_TYPE" \
        "$AGENT_ID" \
        "$SUCCESS" \
        "$DURATION" \
        "$RESULT_LEN" \
        "$PWD" \
        "$SESSION_ID" \
        "$WORKFLOW_ID" >> "$AGENT_LOG"
fi

exit 0
