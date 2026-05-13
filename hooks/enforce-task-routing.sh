#!/bin/bash
# Enforce Task Routing - Blocks Task calls that ignore model routing suggestions
# Hook: PreToolUse (matcher: Task)
#
# When model-router.sh suggests haiku/sonnet/local with high confidence,
# Task calls MUST include the model parameter. This prevents wasting
# 90-98% cost savings by running subagents on opus unnecessarily.
#
# Enforces:
#   - Block if model parameter is missing when cheaper tier suggested
#   - Allow if model is explicitly specified (conscious choice)
#   - Allow if opus suggested (task genuinely needs it)
#   - Allow if low confidence (below threshold)
#
# Note: We don't block tier upgrades because the Task tool doesn't support
# model_reason parameter. If someone explicitly specifies a model, they made
# a conscious choice. The goal is to catch missing model params, not second-guess.
#
# Config: ~/.claude/routing-config.yaml
#   min_confidence: 0.7       # Minimum confidence to enforce (0.0-1.0)
#   stale_seconds: 300        # Max age of routing before ignoring (seconds)
#   enabled: true             # Master switch to disable enforcement
#
# Logs: ~/.claude/routing-overrides.log - records when explicit model overrides suggestion

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Task tool
[[ "$TOOL_NAME" != "Task" ]] && exit 0

STATE_DIR="$HOME/.claude/session-state"
ROUTING_FILE="$STATE_DIR/current-routing.json"
CONFIG_FILE="$HOME/.claude/routing-config.yaml"

# Load config with defaults
MIN_CONFIDENCE=0.7
STALE_SECONDS=300
ENABLED=true

if [[ -f "$CONFIG_FILE" ]]; then
    # Parse YAML config (simple grep-based, no yq dependency)
    _conf_enabled=$(grep -E "^enabled:" "$CONFIG_FILE" 2>/dev/null | awk '{print $2}')
    _conf_min=$(grep -E "^min_confidence:" "$CONFIG_FILE" 2>/dev/null | awk '{print $2}')
    _conf_stale=$(grep -E "^stale_seconds:" "$CONFIG_FILE" 2>/dev/null | awk '{print $2}')

    [[ "$_conf_enabled" == "false" ]] && ENABLED=false
    [[ -n "$_conf_min" ]] && MIN_CONFIDENCE="$_conf_min"
    [[ -n "$_conf_stale" ]] && STALE_SECONDS="$_conf_stale"
fi

# Master switch
[[ "$ENABLED" != "true" ]] && exit 0

# No routing file = first prompt or routing disabled, allow
[[ ! -f "$ROUTING_FILE" ]] && exit 0

# Read routing suggestion
SUGGESTED=$(jq -r '.classification // empty' "$ROUTING_FILE" 2>/dev/null)
CONFIDENCE=$(jq -r '.confidence // 0' "$ROUTING_FILE" 2>/dev/null)
TIMESTAMP=$(jq -r '.timestamp // empty' "$ROUTING_FILE" 2>/dev/null)

# Skip if no suggestion or opus (opus = task needs full power)
[[ -z "$SUGGESTED" || "$SUGGESTED" == "opus" || "$SUGGESTED" == "null" ]] && exit 0

# Skip if low confidence (below configured threshold)
CONF_OK=$(echo "$CONFIDENCE >= $MIN_CONFIDENCE" | bc -l 2>/dev/null || echo "0")
[[ "$CONF_OK" != "1" ]] && exit 0

# Check if routing is stale (older than configured threshold)
if [[ -n "$TIMESTAMP" ]]; then
    ROUTE_EPOCH=$(date -d "$TIMESTAMP" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE=$((NOW_EPOCH - ROUTE_EPOCH))
    if [[ $AGE -gt $STALE_SECONDS ]]; then
        # Stale routing - allow but don't enforce
        exit 0
    fi
fi

# Extract model from Task tool input
MODEL=$(echo "$INPUT" | jq -r '.tool_input.model // empty')

# Define tier costs (lower = cheaper)
get_tier_cost() {
    case "$1" in
        local) echo 0 ;;
        haiku) echo 1 ;;
        sonnet) echo 2 ;;
        opus) echo 3 ;;
        *) echo 99 ;;  # Unknown = expensive
    esac
}

SUGGESTED_COST=$(get_tier_cost "$SUGGESTED")

if [[ -z "$MODEL" || "$MODEL" == "null" ]]; then
    # No model specified - block
    SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // "unknown"')
    DESCRIPTION=$(echo "$INPUT" | jq -r '.tool_input.description // ""' | head -c 100)

    # Log block for analysis and shipping to PostgreSQL
    printf '{"ts":"%s","event":"block","suggested":"%s","confidence":%s,"subagent_type":"%s","description":"%s","project_path":"%s"}\n' \
        "$(date -Iseconds)" \
        "$SUGGESTED" \
        "$CONFIDENCE" \
        "$SUBAGENT_TYPE" \
        "${DESCRIPTION//\"/\\\"}" \
        "$PWD" >> "$HOME/.claude/routing-blocks.jsonl" 2>/dev/null || true

    echo "TASK ROUTING BLOCKED: Routing suggests '$SUGGESTED' (confidence: $CONFIDENCE) but no model parameter provided." >&2
    echo "Add: model: \"$SUGGESTED\" to your Task call to save ~90-98% on this subagent." >&2
    exit 2
fi

# Model explicitly specified - allow (conscious choice made)
# Log the override for analysis but don't block
MODEL_COST=$(get_tier_cost "$MODEL")
if [[ $MODEL_COST -gt $SUGGESTED_COST ]]; then
    # Log tier upgrade for future analysis (non-blocking)
    echo "[$(date -Iseconds)] TIER_UPGRADE: suggested=$SUGGESTED, used=$MODEL, subagent=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // "unknown"')" \
        >> "$HOME/.claude/routing-overrides.log" 2>/dev/null || true
fi

exit 0
