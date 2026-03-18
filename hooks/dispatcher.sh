#!/bin/bash
# Hot-Reload Hook Dispatcher
#
# This is the ONLY hook registered in settings.json.
# It reads actual hook configuration from ~/.claude/hooks.yaml
# Changes to hooks.yaml take effect immediately without session restart.
#
# Usage: Called by Claude Code for all hook events
# Input: JSON with hook_type and tool_input/response
# Output: Hook results (block decisions, injected content, etc.)

set -uo pipefail

CONFIG_FILE="$HOME/.claude/hooks.yaml"
LOG_FILE="$HOME/.claude/dispatcher.log"
TIMING_LOG="$HOME/.claude/hook-timing.jsonl"

# Timing: capture start
DISPATCH_START=$(date +%s%3N)

# Read input from stdin
INPUT=$(cat)

# Extract hook type from environment or input
HOOK_TYPE="${CLAUDE_HOOK_TYPE:-}"
if [[ -z "$HOOK_TYPE" ]]; then
    HOOK_TYPE=$(echo "$INPUT" | jq -r '.hook_type // empty' 2>/dev/null)
fi

# If still no hook type, try to infer from input structure
if [[ -z "$HOOK_TYPE" ]]; then
    if echo "$INPUT" | jq -e '.tool_input' >/dev/null 2>&1; then
        HOOK_TYPE="PreToolUse"
    elif echo "$INPUT" | jq -e '.response' >/dev/null 2>&1; then
        HOOK_TYPE="Stop"
    fi
fi

# Log for debugging - as early as possible
echo "[$(date -Iseconds)] Hook: $HOOK_TYPE (PWD=$PWD) INPUT_LEN=${#INPUT}" >> "$LOG_FILE"

# Timing metrics storage (using temp file to avoid subshell issues)
TIMING_TMP=$(mktemp)
echo "0" > "$TIMING_TMP.size"  # Track total output size
trap "rm -f '$TIMING_TMP' '$TIMING_TMP.size'" EXIT

# Function to log timing metrics
log_timing() {
    local end_time=$(date +%s%3N)
    local duration_ms=$((end_time - DISPATCH_START))
    local tool_name=""
    tool_name=$(echo "$INPUT" | jq -r '.tool_input.tool_name // .tool_name // ""' 2>/dev/null)

    # Read total output size from temp file
    local total_output_size
    total_output_size=$(cat "$TIMING_TMP.size" 2>/dev/null || echo 0)

    # Build command timings JSON array from temp file
    local cmd_json="["
    if [[ -s "$TIMING_TMP" ]]; then
        cmd_json+=$(paste -sd',' "$TIMING_TMP")
    fi
    cmd_json+="]"

    # Log as JSON-line
    printf '{"ts":"%s","hook":"%s","tool":"%s","pwd":"%s","input_bytes":%d,"output_bytes":%d,"duration_ms":%d,"commands":%s}\n' \
        "$(date -Iseconds)" \
        "$HOOK_TYPE" \
        "$tool_name" \
        "$PWD" \
        "${#INPUT}" \
        "$total_output_size" \
        "$duration_ms" \
        "$cmd_json" >> "$TIMING_LOG"
}

# Function to run a hook command with timing
run_hook() {
    local cmd="$1"
    local timeout="${2:-30}"
    local cmd_start=$(date +%s%3N)

    # Run the command with input piped to it
    local result
    result=$(echo "$INPUT" | timeout "$timeout" bash -c "$cmd" 2>&1)
    local exit_code=$?

    local cmd_end=$(date +%s%3N)
    local cmd_duration=$((cmd_end - cmd_start))
    local cmd_name=$(basename "$cmd" | sed 's/\.sh$//')
    local result_size=${#result}

    # Track output size (update temp file atomically)
    local current_size
    current_size=$(cat "$TIMING_TMP.size" 2>/dev/null || echo 0)
    echo $((current_size + result_size)) > "$TIMING_TMP.size"

    # Store timing for this command in temp file
    echo "{\"cmd\":\"$cmd_name\",\"ms\":$cmd_duration,\"bytes\":$result_size,\"exit\":$exit_code}" >> "$TIMING_TMP"

    echo "$result"
}

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    # No config, log timing and pass through
    log_timing
    exit 0
fi

# Function to check if a matcher matches the current context
check_matcher() {
    local matcher="$1"

    # Empty matcher matches everything
    if [[ -z "$matcher" ]] || [[ "$matcher" == "null" ]]; then
        return 0
    fi

    # For SessionStart hooks, match against session type ("new" or "compact")
    if [[ "$HOOK_TYPE" == "SessionStart" ]]; then
        local session_type=""

        # First check environment variable (passed from settings.json)
        session_type="${CLAUDE_SESSION_TYPE:-}"

        # Fall back to JSON input
        if [[ -z "$session_type" ]]; then
            session_type=$(echo "$INPUT" | jq -r '.session_type // .type // empty' 2>/dev/null)
        fi

        # Also check for common patterns in the input that indicate session type
        if [[ -z "$session_type" ]]; then
            if echo "$INPUT" | jq -e '.is_new_session == true' >/dev/null 2>&1; then
                session_type="new"
            elif echo "$INPUT" | jq -e '.is_compact == true or .compacted == true' >/dev/null 2>&1; then
                session_type="compact"
            fi
        fi

        # Match session type against matcher
        if [[ -n "$session_type" ]] && [[ "$session_type" == "$matcher" ]]; then
            return 0
        fi

        # If no session type detected but matcher is specified, don't match
        return 1
    fi

    # For tool-related hooks, match against tool name
    local tool_name=""
    tool_name=$(echo "$INPUT" | jq -r '.tool_input.tool_name // .tool_name // empty' 2>/dev/null)

    # Check if tool name matches the pattern (regex)
    if [[ -n "$tool_name" ]] && echo "$tool_name" | grep -qE "$matcher"; then
        return 0
    fi

    return 1
}

# Parse hooks.yaml and execute matching hooks
# Using yq if available, otherwise fall back to basic parsing
if command -v yq &>/dev/null; then
    # Get hooks for this hook type
    HOOKS=$(yq -r ".hooks.${HOOK_TYPE} // [] | .[]" "$CONFIG_FILE" 2>/dev/null)

    if [[ -n "$HOOKS" && "$HOOKS" != "null" ]]; then
        # Process each hook entry
        yq -r ".hooks.${HOOK_TYPE}[] | @json" "$CONFIG_FILE" 2>/dev/null | while read -r hook_json; do
            matcher=$(echo "$hook_json" | jq -r '.matcher // empty')

            if check_matcher "$matcher"; then
                # Get commands for this hook
                echo "$hook_json" | jq -r '.commands[]? // empty' 2>/dev/null | while read -r cmd; do
                    if [[ -n "$cmd" ]]; then
                        result=$(run_hook "$cmd")

                        # Check if result is a block decision
                        if echo "$result" | jq -e '.decision == "block"' >/dev/null 2>&1; then
                            echo "$result"
                            log_timing
                            exit 0
                        fi

                        # Output any non-empty result
                        if [[ -n "$result" ]]; then
                            echo "$result"
                        fi
                    fi
                done
            fi
        done
    fi
else
    # Fallback: simple grep-based parsing for common patterns
    # This is less flexible but works without yq

    case "$HOOK_TYPE" in
        "PreToolUse")
            # Look for PreToolUse hooks in config
            if grep -q "PreToolUse:" "$CONFIG_FILE"; then
                # Extract and run commands (basic implementation)
                grep -A10 "PreToolUse:" "$CONFIG_FILE" | grep "command:" | sed 's/.*command: *//' | while read -r cmd; do
                    if [[ -n "$cmd" ]]; then
                        run_hook "$cmd"
                    fi
                done
            fi
            ;;
        "Stop")
            if grep -q "Stop:" "$CONFIG_FILE"; then
                grep -A10 "Stop:" "$CONFIG_FILE" | grep "command:" | sed 's/.*command: *//' | while read -r cmd; do
                    if [[ -n "$cmd" ]]; then
                        result=$(run_hook "$cmd")
                        if echo "$result" | jq -e '.decision == "block"' >/dev/null 2>&1; then
                            echo "$result"
                            log_timing
                            exit 0
                        fi
                    fi
                done
            fi
            ;;
    esac
fi

# Log timing metrics
log_timing

# No blocking, allow through
exit 0
