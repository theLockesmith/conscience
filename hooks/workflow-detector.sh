#!/bin/bash
# Workflow Detector - Suggest full workflows based on task patterns
# Hook: UserPromptSubmit
# Location: ~/.claude/hooks/workflow-detector.sh
#
# Detects when user is starting a multi-step task and suggests
# the appropriate workflow skill for structured execution.

set -uo pipefail

# Read input
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // empty' 2>/dev/null)

# If no prompt extracted, try reading raw input
if [[ -z "$PROMPT" ]]; then
    PROMPT="$INPUT"
fi

PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Skip if prompt is very short (likely a follow-up)
if [[ ${#PROMPT} -lt 20 ]]; then
    exit 0
fi

# Workflow detection functions
detect_implement_feature() {
    local patterns=(
        "implement.*feature"
        "add.*feature"
        "build.*new"
        "create.*feature"
        "add support for"
        "implement.*functionality"
        "add.*capability"
        "build.*component"
        "create.*new.*endpoint"
        "add.*new.*page"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_fix_bug() {
    local patterns=(
        "fix.*bug"
        "fix.*issue"
        "debug.*this"
        "not working"
        "broken"
        "investigate.*bug"
        "figure out why"
        "troubleshoot"
        "something.*wrong"
        "keeps failing"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_refactor() {
    local patterns=(
        "refactor"
        "clean up"
        "restructure"
        "reorganize"
        "improve.*code"
        "simplify"
        "extract.*into"
        "split.*into"
        "consolidate"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_security_audit() {
    local patterns=(
        "security audit"
        "check.*security"
        "vulnerability scan"
        "security review"
        "pentest"
        "find.*vulnerabilities"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_council_review() {
    local patterns=(
        "council review"
        "expert review"
        "thorough review"
        "full review"
        "comprehensive review"
        "multi-expert"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Check for workflow matches and output suggestion
WORKFLOW=""
WORKFLOW_DESC=""
WORKFLOW_STEPS=""

if detect_implement_feature; then
    WORKFLOW="implement-feature"
    WORKFLOW_DESC="Full feature implementation with exploration, planning, review, and testing"
    WORKFLOW_STEPS="1. Explore → 2. Plan (approval) → 3. Implement → 4. Review → 5. Test"
elif detect_fix_bug; then
    WORKFLOW="fix-bug"
    WORKFLOW_DESC="Bug investigation with root cause analysis and verification"
    WORKFLOW_STEPS="1. Investigate → 2. Propose fix (approval) → 3. Implement → 4. Verify → 5. Review"
elif detect_refactor; then
    WORKFLOW="refactor"
    WORKFLOW_DESC="Safe refactoring with exploration and verification"
    WORKFLOW_STEPS="1. Explore deps → 2. Plan (approval) → 3. Implement → 4. Test → 5. Review"
elif detect_security_audit; then
    WORKFLOW="security-audit"
    WORKFLOW_DESC="Comprehensive security review"
    WORKFLOW_STEPS="1. Scan (security agent) → 2. Review secrets → 3. Document findings"
elif detect_council_review; then
    WORKFLOW="smart-council"
    WORKFLOW_DESC="Cost-effective multi-expert code review"
    WORKFLOW_STEPS="1. Quick scan (Haiku) → 2. Route to 2-3 experts (Sonnet) → 3. Synthesize"
fi

# Output workflow suggestion if detected
if [[ -n "$WORKFLOW" ]]; then
    # Generate and store workflow_id for agent correlation
    WORKFLOW_STATE_DIR="$HOME/.claude/workflow-state"
    mkdir -p "$WORKFLOW_STATE_DIR"

    # Create workflow_id: workflow-type + timestamp + random
    WORKFLOW_ID="${WORKFLOW}-$(date +%s)-$RANDOM"
    PWD_HASH=$(echo "$PWD" | md5sum | cut -c1-8)
    WORKFLOW_FILE="$WORKFLOW_STATE_DIR/workflow-${PWD_HASH}.id"

    # Store workflow_id (agent-tracker will read this)
    echo "$WORKFLOW_ID" > "$WORKFLOW_FILE"

    # Log workflow start
    echo "{\"ts\":\"$(date -Iseconds)\",\"event\":\"workflow_start\",\"workflow\":\"$WORKFLOW\",\"workflow_id\":\"$WORKFLOW_ID\",\"pwd\":\"$PWD\"}" >> "$HOME/.claude/agent-activity.jsonl"

    echo "<user-prompt-submit-hook>"
    echo "WORKFLOW DETECTED: $WORKFLOW"
    echo ""
    echo "**$WORKFLOW_DESC**"
    echo ""
    echo "Steps: $WORKFLOW_STEPS"
    echo ""
    echo "To use this workflow, invoke: \`/skill $WORKFLOW\`"
    echo "Or follow the steps manually for more control."
    echo "</user-prompt-submit-hook>"
fi

exit 0
