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

# NEW DETECTORS - Added to increase agent coverage from 22% to 60%+

detect_site_tester() {
    local patterns=(
        "deploy"
        "deployed"
        "deployment"
        "verify.*site"
        "verify.*url"
        "verify.*working"
        "check.*site"
        "check.*url"
        "check.*deployed"
        "test.*site"
        "test.*url"
        "test.*deployment"
        "is it working"
        "is.*up"
        "site.*live"
        "page.*load"
        "screenshot"
        "browser.*test"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_ui_tester() {
    local patterns=(
        "frontend.*test"
        "test.*frontend"
        "run.*build"
        "type.*check"
        "lint"
        "unit test.*react"
        "react.*test"
        "vitest"
        "jest"
        "test.*component"
        "after.*frontend.*change"
        "verify.*build"
        "check.*build"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_api_tester() {
    local patterns=(
        "test.*api"
        "api.*test"
        "test.*endpoint"
        "endpoint.*test"
        "rest.*test"
        "graphql.*test"
        "verify.*api"
        "check.*endpoint"
        "api.*working"
        "postman"
        "curl.*test"
        "authentication.*test"
        "auth.*endpoint"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_component_tester() {
    local patterns=(
        "test.*react.*component"
        "react.*component.*test"
        "testing.*library"
        "render.*test"
        "component.*isolation"
        "test.*in isolation"
        "mock.*component"
        "snapshot.*test"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_performance() {
    local patterns=(
        "performance"
        "slow"
        "optimize"
        "speed up"
        "faster"
        "bundle.*size"
        "load.*time"
        "rendering.*slow"
        "memory.*usage"
        "profil"
        "bottleneck"
        "core.*web.*vital"
        "lighthouse"
        "lazy.*load"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_playwright_generator() {
    local patterns=(
        "create.*e2e"
        "write.*e2e"
        "generate.*e2e"
        "playwright.*test"
        "create.*playwright"
        "end.to.end"
        "e2e.*test"
        "browser.*automation"
        "cypress.*test"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_accessibility() {
    local patterns=(
        "accessib"
        "a11y"
        "wcag"
        "aria"
        "screen.*reader"
        "keyboard.*nav"
        "color.*contrast"
        "alt.*text"
        "focus.*management"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_styler() {
    local patterns=(
        "css"
        "styling"
        "tailwind"
        "design.*system"
        "responsive"
        "mobile.*layout"
        "breakpoint"
        "theme"
        "dark.*mode"
        "color.*scheme"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_go_tester() {
    local patterns=(
        "go.*test"
        "test.*go"
        "golang.*test"
        "table.*driven"
        "benchmark.*go"
        "race.*detect"
        "go.*coverage"
    )
    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

detect_documenter() {
    local patterns=(
        "document"
        "readme"
        "add.*comment"
        "code.*comment"
        "jsdoc"
        "godoc"
        "docstring"
        "update.*docs"
        "write.*docs"
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

# NEW SUGGESTIONS - Added to increase agent coverage

if detect_site_tester; then
    SUGGESTIONS+=("site-tester: Use the site-tester agent to verify deployed websites with Playwright")
fi

if detect_ui_tester; then
    SUGGESTIONS+=("ui-tester: Use the ui-tester agent for frontend builds, type checks, linting, and tests")
fi

if detect_api_tester; then
    SUGGESTIONS+=("api-tester: Use the api-tester agent to test REST/GraphQL endpoints")
fi

if detect_component_tester; then
    SUGGESTIONS+=("component-tester: Use the component-tester agent for React component testing")
fi

if detect_performance; then
    SUGGESTIONS+=("performance-frontend: Use the performance-frontend agent for bundle size and rendering optimization")
fi

if detect_playwright_generator; then
    SUGGESTIONS+=("playwright-generator: Use the playwright-generator agent to create E2E test suites")
fi

if detect_accessibility; then
    SUGGESTIONS+=("accessibility: Use the accessibility agent for WCAG compliance and ARIA checks")
fi

if detect_styler; then
    SUGGESTIONS+=("styler: Use the styler agent for CSS/Tailwind and design system compliance")
fi

if detect_go_tester; then
    SUGGESTIONS+=("go-tester: Use the go-tester agent for Go tests, benchmarks, and race detection")
fi

if detect_documenter; then
    SUGGESTIONS+=("documenter: Use the documenter agent to update docs and add code comments")
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
