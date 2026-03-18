#!/bin/bash
# Test suite for quality-enforcer.sh
# Verifies each category blocks violations and allows escape hatches

set -uo pipefail

ENFORCER="$HOME/.claude/hooks/quality-enforcer.sh"
PASSED=0
FAILED=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test helper: expect block
expect_block() {
    local category="$1"
    local response="$2"
    local description="$3"

    TOTAL=$((TOTAL + 1))
    local result
    result=$(echo "{\"response\": \"$response\"}" | bash "$ENFORCER" 2>/dev/null)

    if echo "$result" | grep -q '"decision": "block"'; then
        PASSED=$((PASSED + 1))
        echo -e "${GREEN}✓${NC} BLOCK: $category - $description"
    else
        FAILED=$((FAILED + 1))
        echo -e "${RED}✗${NC} BLOCK: $category - $description"
        echo "  Expected block but got: $result"
    fi
}

# Test helper: expect allow
expect_allow() {
    local category="$1"
    local response="$2"
    local description="$3"

    TOTAL=$((TOTAL + 1))
    local result
    result=$(echo "{\"response\": \"$response\"}" | bash "$ENFORCER" 2>/dev/null)

    if [[ -z "$result" ]] || ! echo "$result" | grep -q '"decision": "block"'; then
        PASSED=$((PASSED + 1))
        echo -e "${GREEN}✓${NC} ALLOW: $category - $description"
    else
        FAILED=$((FAILED + 1))
        echo -e "${RED}✗${NC} ALLOW: $category - $description"
        echo "  Expected allow but got blocked: $result"
    fi
}

echo "=============================================="
echo "Quality Enforcer Test Suite"
echo "=============================================="
echo ""

# =============================================================================
# DEFERRAL TESTS
# =============================================================================
echo -e "${YELLOW}Testing: DEFERRAL${NC}"
expect_block "Deferral" "I'll add the validation later when we have more time." "later pattern"
expect_block "Deferral" "For now, this simple solution will work." "for now pattern"
expect_block "Deferral" "This is a temporary workaround until the API is ready." "temporary pattern"
expect_block "Deferral" "Let's use a placeholder for the config." "placeholder pattern"
expect_block "Deferral" "We can circle back to this after the launch." "circle back pattern"
expect_allow "Deferral" "The function returns the computed value immediately." "normal response"
echo ""

# =============================================================================
# TODO/FIXME CREATION TESTS
# =============================================================================
echo -e "${YELLOW}Testing: TODO/FIXME${NC}"
expect_block "TODO" "I added a TODO to handle the edge case." "added todo"
expect_block "TODO" "Left a FIXME for the error handling." "left fixme"
expect_block "TODO" "The TODO to implement this is marked in the code." "todo to implement"
expect_allow "TODO" "I found an existing TODO in the codebase that we should address." "found existing (discuss)"
expect_allow "TODO" "The remaining work items are documented in the issue tracker." "discuss remaining work"
echo ""

# =============================================================================
# HEDGING TESTS
# =============================================================================
echo -e "${YELLOW}Testing: HEDGING${NC}"
expect_block "Hedging" "This should work but I haven't tested it." "should work"
expect_block "Hedging" "I think this is the right approach." "i think"
expect_block "Hedging" "This is probably fine for our use case." "probably"
expect_block "Hedging" "The basic implementation covers most cases." "basic implementation"
expect_allow "Hedging" "This approach cannot work due to API limitations." "explaining limitation"
expect_allow "Hedging" "There's a constraint that prevents this." "explaining constraint"
echo ""

# =============================================================================
# BYPASS TESTS
# =============================================================================
echo -e "${YELLOW}Testing: BYPASS${NC}"
expect_block "Bypass" "Let's bypass the validation for now." "bypass"
expect_block "Bypass" "Here's a workaround for the issue." "workaround"
expect_block "Bypass" "I wrote a quick script to send directly to the API." "quick script send directly"
expect_block "Bypass" "We can skip the logging to make it faster." "skip logging"
expect_allow "Bypass" "I used the standard API client to make the request." "normal response"
echo ""

# =============================================================================
# LIFECYCLE TESTS
# =============================================================================
echo -e "${YELLOW}Testing: LIFECYCLE${NC}"
expect_block "Lifecycle" "The retry loop will keep retrying forever until it succeeds." "retry forever"
expect_block "Lifecycle" "The connection stays open indefinitely." "indefinitely"
expect_block "Lifecycle" "There's no timeout on this operation." "no timeout"
expect_allow "Lifecycle" "The problem is there's no timeout - we need to add one." "discussing problem"
expect_allow "Lifecycle" "This is a bug - the connection stays open indefinitely." "identifying bug"
echo ""

# =============================================================================
# DATA OPERATIONS TESTS
# =============================================================================
echo -e "${YELLOW}Testing: DATA OPS${NC}"
expect_block "Data Ops" "This operation is not idempotent so be careful." "not idempotent"
expect_block "Data Ops" "We're doing a blind update without checking the current state." "blind update"
expect_block "Data Ops" "The function skips duplicate detection for performance." "skip duplicate"
expect_allow "Data Ops" "The problem is the operation isn't idempotent - we should fix that." "discussing problem"
echo ""

# =============================================================================
# VERIFICATION TESTS
# =============================================================================
echo -e "${YELLOW}Testing: VERIFICATION${NC}"
expect_block "Verification" "Let's skip the tests for now and deploy." "skip test"
expect_block "Verification" "I'll push without running the test suite." "push without"
expect_block "Verification" "Let's do a mass update on all records at once." "mass update"
expect_allow "Verification" "We should never push without testing." "discussing what we should do"
echo ""

# =============================================================================
# OBSERVABILITY TESTS
# =============================================================================
echo -e "${YELLOW}Testing: OBSERVABILITY${NC}"
expect_block "Observability" "The function fails silently if the API is down." "fails silently"
expect_block "Observability" "I removed the logging since it was too verbose." "removed logging"
expect_block "Observability" "The error is swallowed in the except pass block." "swallow exception"
expect_allow "Observability" "The problem is it fails silently - we need to add error handling." "discussing problem"
echo ""

# =============================================================================
# BOUNDARIES TESTS
# =============================================================================
echo -e "${YELLOW}Testing: BOUNDARIES${NC}"
expect_block "Boundaries" "Anyone can access this endpoint without auth." "anyone can"
expect_block "Boundaries" "I'm using a global variable to store the state." "global variable"
expect_block "Boundaries" "The module reaches into the internal implementation." "reach into"
expect_allow "Boundaries" "The problem is anyone can access this - we should add auth." "discussing problem"
echo ""

# =============================================================================
# DETERMINISM TESTS
# =============================================================================
echo -e "${YELLOW}Testing: DETERMINISM${NC}"
expect_block "Determinism" "This test is flaky and sometimes fails." "flaky"
expect_block "Determinism" "It works on my machine but not in CI." "works on my machine"
expect_block "Determinism" "There might be a race condition here." "race condition"
expect_allow "Determinism" "I found a race condition that's causing the bug." "investigating"
echo ""

# =============================================================================
# REVERSIBILITY TESTS
# =============================================================================
echo -e "${YELLOW}Testing: REVERSIBILITY${NC}"
expect_block "Reversibility" "This operation cannot be undone once executed." "cannot undo"
expect_block "Reversibility" "We'll delete the table without a backup." "delete without backup"
expect_block "Reversibility" "This is a permanent change to the schema." "permanent"
expect_allow "Reversibility" "Warning: this operation cannot be undone. Ensure you have backups." "warning with caution"
echo ""

# =============================================================================
# SPEED OVER CORRECTNESS TESTS
# =============================================================================
echo -e "${YELLOW}Testing: SPEED>CORRECT${NC}"
expect_block "Speed>Correct" "I recommend option A because it's the quickest to implement." "quickest"
expect_block "Speed>Correct" "Let's go with the easier approach to save time." "easier save time"
expect_block "Speed>Correct" "This is the path of least resistance." "path of least resistance"
expect_allow "Speed>Correct" "I recommend option A because it's technically correct." "technically correct"
expect_allow "Speed>Correct" "Don't use the quick approach because it has problems." "warning against quick"
echo ""

# =============================================================================
# WISHY-WASHY TESTS
# =============================================================================
echo -e "${YELLOW}Testing: WISHY-WASHY${NC}"
expect_block "Wishy-Washy" "You could use option A or option B or option C." "multiple options no rec"
expect_block "Wishy-Washy" "It depends on your preference." "it depends"
expect_block "Wishy-Washy" "Both approaches are valid with their own tradeoffs." "both valid"
expect_allow "Wishy-Washy" "I recommend option A because it's the technically correct approach." "with recommendation"
echo ""

# =============================================================================
# ASSUMPTIONS TESTS
# =============================================================================
echo -e "${YELLOW}Testing: ASSUMPTIONS${NC}"
expect_block "Assumptions" "I'll assume you want the data in JSON format." "i'll assume"
expect_block "Assumptions" "You probably need error handling here." "you probably"
expect_block "Assumptions" "Going to assume we're targeting Python 3.10+." "going to assume"
expect_allow "Assumptions" "Would you like me to use JSON or XML format?" "asking question"
expect_allow "Assumptions" "Should I add error handling here?" "asking question"
echo ""

# =============================================================================
# IGNORE PATTERNS TESTS
# =============================================================================
echo -e "${YELLOW}Testing: IGNORE PATTERNS${NC}"
expect_block "Ignore Patterns" "I prefer to use my own coding style instead of the existing patterns." "my style"
expect_block "Ignore Patterns" "This is a new approach that's different from the existing code." "new approach different"
expect_block "Ignore Patterns" "I usually write functions this way." "i usually"
expect_allow "Ignore Patterns" "The problem is the existing pattern is broken - we should refactor." "discussing problem"
echo ""

# =============================================================================
# INCOMPLETE ANALYSIS TESTS
# =============================================================================
echo -e "${YELLOW}Testing: INCOMPLETE ANALYSIS${NC}"
expect_block "Incomplete Analysis" "I haven't considered all the edge cases yet." "haven't considered"
expect_block "Incomplete Analysis" "Not sure what the implications are for the other services." "not sure implications"
expect_block "Incomplete Analysis" "This might affect the downstream systems." "might affect"
expect_allow "Incomplete Analysis" "Let me check the other services before recommending." "investigating first"
echo ""

# =============================================================================
# SCOPE CREEP TESTS
# =============================================================================
echo -e "${YELLOW}Testing: SCOPE CREEP${NC}"
expect_block "Scope Creep" "While I'm at it, I'll also add some error handling." "while at it"
expect_block "Scope Creep" "I'll make this more flexible for future use cases." "future proof"
expect_block "Scope Creep" "Let me add an extra configuration option just in case." "just in case"
expect_allow "Scope Creep" "You asked me to add the configuration option, so here it is." "user requested"
echo ""

# =============================================================================
# NOT VERIFYING TESTS
# =============================================================================
echo -e "${YELLOW}Testing: NOT VERIFYING${NC}"
expect_block "Not Verifying" "That should fix the issue. Try it now." "should fix try now"
expect_block "Not Verifying" "The change is done. Let me know if it works." "done let me know"
expect_block "Not Verifying" "Hopefully this resolves the problem." "hopefully resolves"
expect_allow "Not Verifying" "I verified the fix works. The output shows no errors." "verified with evidence"
echo ""

# =============================================================================
# IGNORING ERRORS TESTS
# =============================================================================
echo -e "${YELLOW}Testing: IGNORING ERRORS${NC}"
expect_block "Ignoring Errors" "You can ignore that error, it's not important." "ignore not important"
expect_block "Ignoring Errors" "That's a minor warning, don't worry about it." "minor don't worry"
expect_block "Ignoring Errors" "Not sure why that error appears but let's continue anyway." "not sure why continue"
expect_allow "Ignoring Errors" "This error is expected because we're in test mode." "expected behavior"
echo ""

# =============================================================================
# INCOMPLETE REQUEST TESTS
# =============================================================================
echo -e "${YELLOW}Testing: INCOMPLETE REQUEST${NC}"
expect_block "Incomplete Req" "For now I'll just do the first part of what you asked." "for now just first part"
expect_block "Incomplete Req" "I've done most of the work, the rest can come later." "most of rest later"
expect_block "Incomplete Req" "This handles some of the cases, I'll add the others next." "some of others next"
expect_allow "Incomplete Req" "As you requested, I've implemented the first feature. Shall I continue?" "asking to continue"
echo ""

# =============================================================================
# NOT CHECKING EXISTING TESTS
# =============================================================================
echo -e "${YELLOW}Testing: NOT CHECKING EXISTING${NC}"
expect_block "Not Checking" "I'll create a new helper function for this." "create new helper"
expect_block "Not Checking" "Let me write a new utility class." "write new utility"
expect_allow "Not Checking" "I searched and couldn't find an existing utility for this." "searched couldn't find"
expect_allow "Not Checking" "I checked with grep and nothing similar exists." "checked with grep"
echo ""

# =============================================================================
# APOLOGY/VALIDATION TESTS
# =============================================================================
echo -e "${YELLOW}Testing: APOLOGY/VALIDATION${NC}"
expect_block "Apology" "I apologize for the confusion earlier." "i apologize"
expect_block "Apology" "That's a great question about the API design." "great question"
expect_block "Apology" "You're absolutely right about that approach." "you're absolutely right"
expect_allow "Apology" "The API returns a 404 when the resource is not found." "direct answer"
echo ""

# =============================================================================
# UNEXPLAINED CHANGES TESTS
# =============================================================================
echo -e "${YELLOW}Testing: UNEXPLAINED CHANGES${NC}"
expect_block "Unexplained" "I changed the implementation to use async/await." "changed to without why"
expect_block "Unexplained" "I'm switching to a different database for this." "switching to no reason"
expect_allow "Unexplained" "I changed to async/await because the current sync approach blocks the event loop." "changed with reason"
echo ""

# =============================================================================
# SECURITY TESTS
# =============================================================================
echo -e "${YELLOW}Testing: SECURITY${NC}"
expect_block "Security" "I'll use eval() to parse the user configuration." "eval"
expect_block "Security" "The password is hardcoded as admin123 for simplicity." "hardcoded password"
expect_block "Security" "We can concatenate the user input directly into the SQL query." "sql concat"
expect_block "Security" "Using innerHTML to render the user content." "innerHTML"
expect_allow "Security" "Found a vulnerability - the SQL query has an injection risk. We need to sanitize." "reporting vulnerability"
echo ""

# =============================================================================
# RESOURCE CLEANUP TESTS
# =============================================================================
echo -e "${YELLOW}Testing: RESOURCE CLEANUP${NC}"
expect_block "Resource Cleanup" "The connection stays open but we don't close it." "don't close"
expect_block "Resource Cleanup" "This might cause a memory leak but it's unlikely." "memory leak"
expect_block "Resource Cleanup" "The file handle is never released after reading." "never released"
expect_allow "Resource Cleanup" "I found a memory leak in this function - we need to add cleanup." "investigating leak"
echo ""

# =============================================================================
# BREAKING CHANGES TESTS
# =============================================================================
echo -e "${YELLOW}Testing: BREAKING CHANGES${NC}"
expect_block "Breaking Changes" "This is a breaking change to the API schema." "breaking change"
expect_block "Breaking Changes" "I'll remove the deprecated parameter from the endpoint." "remove parameter"
expect_block "Breaking Changes" "Existing clients will break when this is deployed." "clients break"
expect_allow "Breaking Changes" "This breaking change is documented in the changelog and announced." "with communication"
echo ""

# =============================================================================
# DEPENDENCY ADDITIONS TESTS
# =============================================================================
echo -e "${YELLOW}Testing: DEPENDENCIES${NC}"
expect_block "Dependencies" "Let me add lodash as a dependency for this function." "add dependency"
expect_block "Dependencies" "We need to npm install axios for the HTTP client." "npm install"
expect_block "Dependencies" "I'll pip install requests for the API calls." "pip install"
expect_allow "Dependencies" "You asked me to add moment.js for date handling." "user requested"
expect_allow "Dependencies" "The standard library doesn't support this, so we need an external package." "no alternative"
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=============================================="
echo "RESULTS"
echo "=============================================="
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
echo "Total:  $TOTAL"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
