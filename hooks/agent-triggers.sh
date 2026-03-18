#!/bin/bash
# Agent Triggers - Suggest appropriate agents based on user prompt patterns
# Hook: UserPromptSubmit
# Location: ~/.claude/hooks/agent-triggers.sh

set -uo pipefail

# Read user prompt from stdin
USER_PROMPT=$(cat)
PROMPT_LOWER=$(echo "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')

# Track suggestions to avoid duplicates
SUGGESTIONS=()

# Pattern detection functions
detect_debugger() {
    local patterns=(
        "why isn't"
        "why won't"
        "why doesn't"
        "doesn't work"
        "isn't working"
        "won't work"
        "not working"
        "broken"
        "failing"
        "keeps crashing"
        "throws.*error"
        "getting.*error"
        "investigate.*bug"
        "debug"
        "what's wrong"
        "help.*fix"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_explorer() {
    local patterns=(
        "what's the architecture"
        "how does.*work"
        "how is.*structured"
        "where is.*defined"
        "find.*implementation"
        "understand.*codebase"
        "explore.*code"
        "what files"
        "show me.*structure"
        "how are.*organized"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_planner() {
    local patterns=(
        "how should i implement"
        "best way to"
        "approach for"
        "design.*for"
        "plan.*implementation"
        "architect"
        "strategy for"
        "before i start"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_security() {
    local patterns=(
        "security"
        "vulnerab"
        "auth.*bypass"
        "injection"
        "xss"
        "csrf"
        "owasp"
        "penetration"
        "secrets"
        "credentials.*exposed"
        "audit.*security"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_test_writer() {
    local patterns=(
        "write.*tests"
        "add.*tests"
        "create.*tests"
        "need.*tests"
        "test coverage"
        "unit test"
        "integration test"
        "missing.*tests"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_reviewer() {
    local patterns=(
        "review.*code"
        "code review"
        "check.*quality"
        "any issues"
        "look.*over"
        "feedback on"
        "improve.*code"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Build suggestions
if detect_debugger; then
    SUGGESTIONS+=("debugger: Use the debugger agent to investigate the root cause")
fi

if detect_explorer; then
    SUGGESTIONS+=("Explore: Use the Explore agent to map out the codebase structure")
fi

if detect_planner; then
    SUGGESTIONS+=("Plan: Use the Plan agent to design an implementation approach")
fi

if detect_security; then
    SUGGESTIONS+=("security: Use the security agent to scan for vulnerabilities")
fi

if detect_test_writer; then
    SUGGESTIONS+=("test-writer: Use the test-writer agent to generate tests")
fi

if detect_reviewer; then
    SUGGESTIONS+=("reviewer: Use the reviewer agent for code quality analysis")
fi

# Output suggestions if any
if [[ ${#SUGGESTIONS[@]} -gt 0 ]]; then
    echo "<user-prompt-submit-hook>"
    echo "AGENT SUGGESTIONS based on your request:"
    echo ""
    for suggestion in "${SUGGESTIONS[@]}"; do
        echo "- $suggestion"
    done
    echo ""
    echo "You can invoke these with: Task tool, subagent_type=\"<agent-name>\""
    echo "</user-prompt-submit-hook>"
fi

exit 0
