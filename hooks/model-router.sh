#!/bin/bash
# Model Router - Suggests optimal model tier for subagent invocations
# Hook: UserPromptSubmit
# Location: ~/.claude/hooks/model-router.sh
#
# Classifies incoming prompts and suggests which model tier to use
# for any subagent (Task tool) invocations.
#
# Tiers:
#   haiku  - Simple lookups, status checks, formatting ($1.25/MTok output)
#   sonnet - Code review, documentation, exploration ($15/MTok output)
#   opus   - Complex architecture, novel problems, multi-step planning ($75/MTok output)

set -uo pipefail

ROUTING_LOG="$HOME/.claude/routing-decisions.jsonl"
WORKFLOW_STATE_DIR="$HOME/.claude/workflow-state"

# Read input
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // empty' 2>/dev/null)

# If no prompt extracted, try reading raw input
if [[ -z "$PROMPT" ]]; then
    PROMPT="$INPUT"
fi

# Skip very short prompts (likely follow-ups or confirmations)
if [[ ${#PROMPT} -lt 15 ]]; then
    exit 0
fi

PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')
PROMPT_SNIPPET=$(echo "$PROMPT" | head -c 200 | tr -d '\n' | sed 's/"/\\"/g')
PROMPT_HASH=$(echo "$PROMPT" | md5sum | cut -c1-16)

# Get session and workflow context
get_session_id() {
    local pwd_hash=$(echo "$PWD" | sed 's|/|-|g' | sed 's|^-||')
    local transcript_dir="$HOME/.claude/projects/-${pwd_hash}"
    if [[ -d "$transcript_dir" ]]; then
        local latest=$(ls -t "$transcript_dir"/*.jsonl 2>/dev/null | head -1)
        if [[ -n "$latest" ]]; then
            stat -c '%i-%Y' "$latest" 2>/dev/null || echo "unknown"
            return
        fi
    fi
    echo "pid-$$-${pwd_hash:0:16}"
}

get_workflow_id() {
    local pwd_hash=$(echo "$PWD" | md5sum | cut -c1-8)
    local workflow_file="$WORKFLOW_STATE_DIR/workflow-${pwd_hash}.id"
    if [[ -f "$workflow_file" ]]; then
        local file_age=$(( $(date +%s) - $(stat -c %Y "$workflow_file") ))
        if (( file_age < 1800 )); then
            cat "$workflow_file"
            return
        fi
    fi
    echo ""
}

# Classification patterns
# Haiku: Simple, factual, lookup tasks
HAIKU_PATTERNS=(
    "^what is "
    "^what does "
    "^what's "
    "^how do i "
    "^how to "
    "^list "
    "^show me "
    "^show the "
    "^check "
    "^status "
    "^is there "
    "^are there "
    "^where is "
    "^which "
    "^when "
    "^tell me "
    "^can you "
    "^explain briefly"
    "^quick "
    "^simple "
    "^just "
    "^format "
    "^convert "
)

# Sonnet: Moderate complexity, review, documentation
SONNET_PATTERNS=(
    "review"
    "document"
    "explain.*how"
    "explain.*why"
    "explore"
    "search.*for"
    "find.*all"
    "analyze"
    "compare"
    "summarize"
    "describe"
    "investigate"
    "understand"
    "look.*at"
    "read.*and"
    "check.*for.*issues"
    "test"
    "verify"
    "validate"
)

# Opus: Complex, multi-step, architectural
OPUS_PATTERNS=(
    "implement"
    "build"
    "create.*new"
    "design"
    "architect"
    "refactor"
    "rewrite"
    "optimize"
    "fix.*bug"
    "debug"
    "complex"
    "multi-step"
    "plan.*implementation"
    "help me with"
    "i need.*feature"
    "add.*feature"
    "integrate"
    "migrate"
    "upgrade"
    "restructure"
)

# Classification function
classify_prompt() {
    local prompt="$1"
    local classification="sonnet"  # Default
    local confidence="0.50"
    local reason="default"

    # Check Haiku patterns first (simple tasks)
    for pattern in "${HAIKU_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            classification="haiku"
            confidence="0.75"
            reason="matched pattern: $pattern"
            echo "$classification|$confidence|$reason"
            return
        fi
    done

    # Check Opus patterns (complex tasks)
    for pattern in "${OPUS_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            classification="opus"
            confidence="0.80"
            reason="matched pattern: $pattern"
            echo "$classification|$confidence|$reason"
            return
        fi
    done

    # Check Sonnet patterns (moderate tasks)
    for pattern in "${SONNET_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            classification="sonnet"
            confidence="0.70"
            reason="matched pattern: $pattern"
            echo "$classification|$confidence|$reason"
            return
        fi
    done

    # Length-based heuristic: very short = simple, very long = complex
    local len=${#prompt}
    if (( len < 50 )); then
        classification="haiku"
        confidence="0.60"
        reason="short prompt ($len chars)"
    elif (( len > 500 )); then
        classification="opus"
        confidence="0.65"
        reason="long detailed prompt ($len chars)"
    fi

    echo "$classification|$confidence|$reason"
}

# Classify the prompt
IFS='|' read -r CLASSIFICATION CONFIDENCE REASON <<< "$(classify_prompt "$PROMPT_LOWER")"

SESSION_ID=$(get_session_id)
WORKFLOW_ID=$(get_workflow_id)

# Log the routing decision
printf '{"ts":"%s","prompt_hash":"%s","prompt_snippet":"%s","classification":"%s","confidence":%s,"reason":"%s","project_path":"%s","session_id":"%s","workflow_id":"%s"}\n' \
    "$(date -Iseconds)" \
    "$PROMPT_HASH" \
    "$PROMPT_SNIPPET" \
    "$CLASSIFICATION" \
    "$CONFIDENCE" \
    "$REASON" \
    "$PWD" \
    "$SESSION_ID" \
    "$WORKFLOW_ID" >> "$ROUTING_LOG"

# Output suggestion to Claude (only for non-opus classifications)
# We don't need to suggest Opus since that's the default behavior
if [[ "$CLASSIFICATION" != "opus" ]]; then
    echo "<model-routing-suggestion>"
    echo "Task complexity: $CLASSIFICATION (confidence: $CONFIDENCE)"
    echo ""
    if [[ "$CLASSIFICATION" == "haiku" ]]; then
        echo "This appears to be a simple task. When spawning subagents, consider using model: haiku"
        echo "Example: Task tool with model parameter set to 'haiku'"
    elif [[ "$CLASSIFICATION" == "sonnet" ]]; then
        echo "This appears to be a moderate complexity task. The default sonnet model for subagents is appropriate."
    fi
    echo "</model-routing-suggestion>"
fi

exit 0
