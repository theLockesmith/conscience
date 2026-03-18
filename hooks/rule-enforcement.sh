#!/bin/bash
# Rule Enforcement Hook - Pattern-based validation
# Hook: Stop
# Checks assistant response against critical rules and blocks violations
#
# Output format for blocking:
# {"decision": "block", "reason": "explanation"}

set -uo pipefail

RULES_FILE="$HOME/.claude/critical-rules.yaml"
LOG_FILE="$HOME/.claude/rule-violations.log"

# Read hook input (contains the response to validate)
HOOK_INPUT=$(cat)

# Extract the response text
# The Stop hook receives the full response context
RESPONSE=$(echo "$HOOK_INPUT" | jq -r '.response // .content // .text // .' 2>/dev/null)

# If we couldn't extract response, let it through
if [[ -z "$RESPONSE" ]] || [[ "$RESPONSE" == "null" ]]; then
    exit 0
fi

# Convert to lowercase for matching
RESPONSE_LOWER=$(echo "$RESPONSE" | tr '[:upper:]' '[:lower:]')

# Critical patterns that MUST block
# Includes both literal commands AND natural language announcements
declare -A CRITICAL_PATTERNS=(
    # Docker restart - commands
    ["systemctl restart docker"]="BLOCKED: Never restart Docker daemon"
    ["service docker restart"]="BLOCKED: Never restart Docker daemon"
    # Docker restart - natural language
    ["restart.*docker"]="BLOCKED: Never restart Docker daemon"
    ["docker.*restart"]="BLOCKED: Never restart Docker daemon"

    # Force delete pods - commands
    ["kubectl delete.*--force"]="BLOCKED: Never force delete pods"
    ["kubectl delete.*--grace-period=0"]="BLOCKED: Never force delete pods"
    ["oc delete.*--force"]="BLOCKED: Never force delete pods"
    # Force delete - natural language
    ["force.?delete"]="BLOCKED: Never force delete pods"
    ["delete.*force"]="BLOCKED: Never force delete pods"

    # Vault decrypt - commands
    ["ansible-vault decrypt"]="BLOCKED: Never decrypt vault values"
    ["ansible-vault view"]="BLOCKED: Never view vault values"
    # Vault - natural language
    ["decrypt.*vault"]="BLOCKED: Never decrypt vault values"
    ["view.*vault.*secret"]="BLOCKED: Never view vault secrets"

    # Session termination
    ["loginctl terminate-session"]="BLOCKED: Never terminate login sessions"
    ["terminate.*session"]="BLOCKED: Never terminate login sessions"

    # CronJob triggers - commands
    ["kubectl create job --from=cronjob"]="BLOCKED: Never manually trigger CronJobs without asking"
    # CronJob - natural language
    ["trigger.*cronjob"]="BLOCKED: Never manually trigger CronJobs without asking"
    ["run.*cronjob.*manually"]="BLOCKED: Never manually trigger CronJobs without asking"
)

# Check critical patterns
for pattern in "${!CRITICAL_PATTERNS[@]}"; do
    if echo "$RESPONSE_LOWER" | grep -qE "$pattern"; then
        REASON="${CRITICAL_PATTERNS[$pattern]}"

        # Log violation
        echo "$(date -Iseconds) CRITICAL: $REASON" >> "$LOG_FILE"
        echo "Pattern: $pattern" >> "$LOG_FILE"
        echo "---" >> "$LOG_FILE"

        # Output block decision
        echo "{\"decision\": \"block\", \"reason\": \"$REASON\"}"
        exit 0
    fi
done

# Warning patterns (don't block, but inject reminder)
declare -A WARNING_PATTERNS=(
    ["i'll go ahead and"]="WARNING: Acting without asking - did user request this?"
    ["i'll just"]="WARNING: Acting without asking - did user request this?"
    ["i went ahead"]="WARNING: Acting without asking - did user request this?"
    ["i assume"]="WARNING: Don't assume - verify or ask"
    ["probably just"]="WARNING: Don't assume - verify or ask"
    ["should be fine"]="WARNING: Don't assume - verify or ask"
    ["good enough"]="WARNING: 'Good enough' is not acceptable"
    ["close enough"]="WARNING: 'Close enough' is not acceptable"
    ["quick fix"]="WARNING: No quick fixes - do it properly"
    ["as a workaround"]="WARNING: Workarounds are not solutions"
)

WARNINGS=()
for pattern in "${!WARNING_PATTERNS[@]}"; do
    if echo "$RESPONSE_LOWER" | grep -qF "$pattern"; then
        WARNINGS+=("${WARNING_PATTERNS[$pattern]}")
    fi
done

# If warnings found, log them (but don't block)
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo "$(date -Iseconds) WARNINGS:" >> "$LOG_FILE"
    for warn in "${WARNINGS[@]}"; do
        echo "  - $warn" >> "$LOG_FILE"
    done
    echo "---" >> "$LOG_FILE"
fi

# No critical violations - allow response
exit 0
