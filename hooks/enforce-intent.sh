#!/bin/bash
# Enforce Intent Classification
# Hook: PreToolUse (matcher: Edit|Write)
#
# When intent="conversation", block file modifications.
# User wants DISCUSSION, not changes.
#
# Intent types:
#   - conversation: explain, compare, don't modify
#   - action: implement immediately
#   - investigate: diagnose, wait for direction
#
# Override phrases (checked in user's last prompt):
#   - "do it", "go ahead", "make the change", "implement", "fix it"
#
# Config: ~/.claude/session-state/current-routing.json (set by model-router.sh)

set -uo pipefail

ROUTING_FILE="$HOME/.claude/session-state/current-routing.json"
PROMPT_FILE="$HOME/.claude/session-state/last-prompt.txt"

# No routing file = no enforcement
[[ ! -f "$ROUTING_FILE" ]] && exit 0

# Read intent
INTENT=$(jq -r '.intent // "unknown"' "$ROUTING_FILE" 2>/dev/null)
INTENT_CONFIDENCE=$(jq -r '.intent_confidence // 0' "$ROUTING_FILE" 2>/dev/null)

# Only enforce for conversation intent with reasonable confidence
[[ "$INTENT" != "conversation" ]] && exit 0

# Check confidence threshold (don't enforce low-confidence classifications)
CONF_OK=$(echo "$INTENT_CONFIDENCE >= 0.8" | bc -l 2>/dev/null || echo "0")
[[ "$CONF_OK" != "1" ]] && exit 0

# Check for override phrases in last prompt
if [[ -f "$PROMPT_FILE" ]]; then
    LAST_PROMPT=$(cat "$PROMPT_FILE" | tr '[:upper:]' '[:lower:]')

    # Override phrases that indicate user wants action despite conversation classification
    if echo "$LAST_PROMPT" | grep -qE "(do it|go ahead|make the change|implement|fix it|update it|change it|apply|execute|run it|send it|ship it|carry on|build|deploy|address|tackle|let.s (do|go|get|build|deploy|tackle|address|create)|create|set up|set them up|write|save|generate|finish|finalize|complete|resolve|sort out|proceed|continue|go for it|do these|do them|now|right now|fucking go|fucking fix|fucking do)"; then
        exit 0  # User explicitly requested action
    fi
fi

# Block the modification
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)

cat << EOF
{"decision": "block", "reason": "INTENT MISMATCH: Your prompt was classified as 'conversation' (confidence: $INTENT_CONFIDENCE) - user wants DISCUSSION, not modifications. Explain the change first. If user wants you to proceed, they'll say 'do it' or 'go ahead'."}
EOF
exit 0
