#!/bin/bash
# Agent resource limits - prevent runaway agent spawning
# Location: ~/.claude/hooks/agent-resource-limits.sh
# Hook type: PreToolUse (for Task tool)
#
# NOTE: This hook only limits NEW spawns. It does NOT:
# - Kill running processes
# - Enforce timeouts on tests
# - Interfere with long-running legitimate work

set -uo pipefail

# Load config or use defaults
CONFIG_FILE="$HOME/.claude/security/config.yml"
if [[ -f "$CONFIG_FILE" ]]; then
    MAX_CONCURRENT=$(grep -A1 'max_concurrent_heavy:' "$CONFIG_FILE" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "8")
    CPU_THRESHOLD=$(grep 'cpu_threshold:' "$CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+' || echo "50")
else
    MAX_CONCURRENT=8
    CPU_THRESHOLD=50
fi

# Disable if set to 0
[[ "$MAX_CONCURRENT" == "0" ]] && exit 0

# Read tool input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only apply to Task tool (agent spawning)
if [[ "$TOOL_NAME" != "Task" ]]; then
    exit 0
fi

# Count running agents
# Agents show up as subprocesses with specific patterns
RUNNING_AGENTS=$(pgrep -cf "claude.*agent|Task.*subagent" 2>/dev/null || echo "0")

# Also count heavy child processes from previous agents (playwright, vitest, etc.)
HEAVY_PROCESSES=$(ps aux --no-headers | awk -v thresh="$CPU_THRESHOLD" '$3 > thresh {print}' | grep -cE 'playwright|vitest|firefox|chromium|webkit|puppeteer' 2>/dev/null || echo "0")

TOTAL_LOAD=$((RUNNING_AGENTS + HEAVY_PROCESSES))

if [[ $TOTAL_LOAD -ge $MAX_CONCURRENT ]]; then
    cat >&2 << EOF
BLOCKED: Too many concurrent agents or heavy processes running.
  - Active agents: $RUNNING_AGENTS
  - Heavy test processes (>${CPU_THRESHOLD}% CPU): $HEAVY_PROCESSES
  - Total: $TOTAL_LOAD (max: $MAX_CONCURRENT)

Wait for current agents to complete, or manually kill stale processes:
  ~/.claude/scripts/cleanup-orphaned-agents.sh

To adjust limits, edit: ~/.claude/security/config.yml
EOF
    exit 2
fi

# Log agent spawn for monitoring
AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // "unknown"')
DESCRIPTION=$(echo "$INPUT" | jq -r '.tool_input.description // "no description"')
echo "[$(date -Iseconds)] Spawning agent: type=$AGENT_TYPE desc=\"$DESCRIPTION\" load=$TOTAL_LOAD" >> /tmp/claude-agent-spawns.log

# Allow the agent to spawn
exit 0
