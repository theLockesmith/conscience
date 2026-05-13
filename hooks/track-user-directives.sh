#!/bin/bash
# Track explicit user directives (do not modify, leave alone, don't touch)
# UserPromptSubmit hook - extracts directives and persists them
#
# When user says "don't modify X", "leave X alone", "don't touch X", etc.
# this records the directive to a persistent file that Edit/Write hooks check.

set -uo pipefail

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // empty')
[[ -z "$PROMPT" ]] && exit 0

DIRECTIVES_FILE="$HOME/.claude/user-directives.json"

# Initialize file if missing
if [[ ! -f "$DIRECTIVES_FILE" ]]; then
    echo '{"do_not_modify": [], "do_not_deploy": [], "do_not_restart": [], "do_not_update": [], "session_id": ""}' > "$DIRECTIVES_FILE"
fi

# Patterns that indicate "do not modify" directives
# Captures: don't modify, do not alter, leave alone, don't touch, don't change, do not edit
DO_NOT_MODIFY_PATTERNS=(
    "don't modify"
    "do not modify"
    "don't alter"
    "do not alter"
    "don't touch"
    "do not touch"
    "don't change"
    "do not change"
    "don't edit"
    "do not edit"
    "leave .* alone"
    "leave .* as is"
    "don't mess with"
    "do not mess with"
    "hands off"
    "stay away from"
    "no changes to"
    "do not make changes"
    "don't make changes"
    "read .* instead"
    "just read"
    "only read"
    "instead of modifying"
    "instead of changing"
    "don't write to"
    "do not write to"
)

# Patterns for deploy/restart/update directives
DO_NOT_DEPLOY_PATTERNS=(
    "don't deploy"
    "do not deploy"
    "don't push"
    "do not push"
    "don't apply"
    "do not apply"
    "don't roll out"
    "do not roll out"
    "don't release"
    "do not release"
    "no deployments"
    "no deploys"
    # Indirect production restrictions
    "doesn't go into production"
    "not.*production"
    "only.*development"
    "only doing development"
    "dev only"
    "development only"
    "until i say so"
    "until noon"
    "until i tell you"
    "until i approve"
    "not production ready"
    "don't go to prod"
    "don't go live"
    "no production"
    "wait for.*approval"
    "need.*approval.*before"
    "hold off.*deploy"
    "hold off.*production"
)

DO_NOT_RESTART_PATTERNS=(
    "don't restart"
    "do not restart"
    "don't reboot"
    "do not reboot"
    "don't stop"
    "do not stop"
    "don't kill"
    "do not kill"
    "don't bounce"
    "do not bounce"
    "no restarts"
    "keep .* running"
    "leave .* running"
)

DO_NOT_UPDATE_PATTERNS=(
    "don't update"
    "do not update"
    "don't upgrade"
    "do not upgrade"
    "don't install"
    "do not install"
    "don't pip"
    "do not pip"
    "don't npm"
    "do not npm"
    "don't apt"
    "do not apt"
    "no updates"
    "no upgrades"
    "no installs"
)

# Check if prompt contains any directive pattern
PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Function to check patterns and record directive
check_and_record_directive() {
    local directive_type="$1"
    local list_key="$2"
    shift 2
    local patterns=("$@")

    for pattern in "${patterns[@]}"; do
        if echo "$PROMPT_LOWER" | grep -qiE "$pattern"; then
            TIMESTAMP=$(date -Iseconds)

            # Try to extract file/path references
            TARGETS=""
            PATHS=$(echo "$PROMPT" | grep -oE '(/[a-zA-Z0-9_./-]+|~/[a-zA-Z0-9_./-]+|[a-zA-Z0-9_-]+\.(py|sh|js|ts|go|rs|yaml|yml|json|md|txt))' | head -5)
            if [[ -n "$PATHS" ]]; then
                TARGETS="$PATHS"
            fi

            # If no specific paths, record as general block for this type
            if [[ -z "$TARGETS" ]]; then
                TARGETS="GENERAL_${directive_type}_BLOCK"
            fi

            # Read current directives
            CURRENT=$(cat "$DIRECTIVES_FILE")

            # Add new directive
            NEW_ENTRY=$(jq -n \
                --arg type "$directive_type" \
                --arg pattern "$pattern" \
                --arg prompt "$PROMPT" \
                --arg targets "$TARGETS" \
                --arg timestamp "$TIMESTAMP" \
                '{type: $type, pattern: $pattern, prompt: $prompt, targets: $targets, timestamp: $timestamp}')

            # Append to the appropriate list
            echo "$CURRENT" | jq --argjson entry "$NEW_ENTRY" ".$list_key += [\$entry]" > "$DIRECTIVES_FILE"

            # Output warning to Claude
            echo "<user-directive-recorded>"
            echo "USER DIRECTIVE RECORDED: '$directive_type' - '$pattern' detected."
            echo "Targets: $TARGETS"
            echo "This directive is NOW ENFORCED. Violations will be HARD BLOCKED."
            echo "Only the user can release this block."
            echo "</user-directive-recorded>"

            return 0
        fi
    done
    return 1
}

# Check all directive categories
check_and_record_directive "MODIFY" "do_not_modify" "${DO_NOT_MODIFY_PATTERNS[@]}"
check_and_record_directive "DEPLOY" "do_not_deploy" "${DO_NOT_DEPLOY_PATTERNS[@]}"
check_and_record_directive "RESTART" "do_not_restart" "${DO_NOT_RESTART_PATTERNS[@]}"
check_and_record_directive "UPDATE" "do_not_update" "${DO_NOT_UPDATE_PATTERNS[@]}"

# Check for release patterns
RELEASE_PATTERNS=(
    "you can modify"
    "you can change"
    "you can edit"
    "you can deploy"
    "you can restart"
    "you can update"
    "you can install"
    "go ahead and modify"
    "go ahead and change"
    "go ahead and deploy"
    "go ahead and restart"
    "go ahead and update"
    "ok to modify"
    "okay to modify"
    "ok to deploy"
    "ok to restart"
    "ok to update"
    "clear the block"
    "clear all blocks"
    "remove the block"
    "release the block"
    "release all blocks"
)

for pattern in "${RELEASE_PATTERNS[@]}"; do
    if echo "$PROMPT_LOWER" | grep -qiE "$pattern"; then
        # User is releasing blocks - clear all directives
        echo '{"do_not_modify": [], "do_not_deploy": [], "do_not_restart": [], "do_not_update": [], "session_id": ""}' > "$DIRECTIVES_FILE"
        echo "<user-directive-released>"
        echo "USER DIRECTIVE RELEASED: All blocks have been cleared."
        echo "</user-directive-released>"
        break
    fi
done

exit 0
