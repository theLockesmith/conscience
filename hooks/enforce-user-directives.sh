#!/bin/bash
# ENFORCE user directives - HARD BLOCK on violations
# PreToolUse hook for Edit, Write, and Bash tools
#
# This is a ZERO TOLERANCE enforcement. If user said don't do it, we DON'T.
# No exceptions. No "but I think it's helpful". No "the user probably meant".
# The user's explicit instruction is LAW.

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

DIRECTIVES_FILE="$HOME/.claude/user-directives.json"
[[ ! -f "$DIRECTIVES_FILE" ]] && exit 0

DIRECTIVES=$(cat "$DIRECTIVES_FILE")

# Helper function to block
hard_block() {
    local directive_type="$1"
    local reason="$2"
    local prompt="$3"
    local timestamp="$4"

    echo "HARD BLOCK: User gave explicit '$directive_type' directive." >&2
    echo "Reason: $reason" >&2
    echo "Directive timestamp: $timestamp" >&2
    echo "User's words: $prompt" >&2
    echo "" >&2
    echo "You were EXPLICITLY TOLD not to do this. This is NON-NEGOTIABLE." >&2
    echo "To release this block, the user must explicitly grant permission." >&2
    exit 2
}

# ============================================
# EDIT/WRITE - Check do_not_modify directives
# ============================================
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" ]]; then
    COUNT=$(echo "$DIRECTIVES" | jq '.do_not_modify | length')
    if [[ "$COUNT" != "0" ]]; then
        FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

        while IFS= read -r directive; do
            TARGETS=$(echo "$directive" | jq -r '.targets // empty')
            PROMPT=$(echo "$directive" | jq -r '.prompt // empty')
            TIMESTAMP=$(echo "$directive" | jq -r '.timestamp // empty')

            # If GENERAL block, block ALL modifications
            if [[ "$TARGETS" == *"GENERAL_MODIFY_BLOCK"* ]] || [[ "$TARGETS" == *"GENERAL_CODE_BLOCK"* ]]; then
                hard_block "do not modify" "General code modification block active" "$PROMPT" "$TIMESTAMP"
            fi

            # Check if the file matches any target
            for target in $TARGETS; do
                target="${target/#\~/$HOME}"
                if [[ "$FILE_PATH" == "$target" ]] || [[ "$FILE_PATH" == *"$target"* ]] || [[ "$target" == *"$FILE_PATH"* ]]; then
                    hard_block "do not modify" "File '$FILE_PATH' matches blocked target '$target'" "$PROMPT" "$TIMESTAMP"
                fi
            done
        done < <(echo "$DIRECTIVES" | jq -c '.do_not_modify[]' 2>/dev/null)
    fi
fi

# ============================================
# BASH - Check deploy/restart/update directives
# ============================================
if [[ "$TOOL_NAME" == "Bash" ]]; then
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')

    # Deploy patterns - ANY command that could push to production
    DEPLOY_PATTERNS="kubectl apply|kubectl create|kubectl patch|kubectl set|kubectl rollout|oc apply|oc create|oc patch|oc new-app|oc rollout|oc start-build|oc import-image|helm install|helm upgrade|ansible-playbook|atlas deploy|atlas apply|git push|argocd app sync|argocd sync|skopeo copy|buildah push|podman push|docker push"
    COUNT=$(echo "$DIRECTIVES" | jq '.do_not_deploy | length')
    if [[ "$COUNT" != "0" ]]; then
        if echo "$COMMAND_LOWER" | grep -qE "$DEPLOY_PATTERNS"; then
            while IFS= read -r directive; do
                PROMPT=$(echo "$directive" | jq -r '.prompt // empty')
                TIMESTAMP=$(echo "$directive" | jq -r '.timestamp // empty')
                hard_block "do not deploy" "Deploy command detected: $COMMAND" "$PROMPT" "$TIMESTAMP"
            done < <(echo "$DIRECTIVES" | jq -c '.do_not_deploy[0]' 2>/dev/null)
        fi
    fi

    # Restart patterns
    RESTART_PATTERNS="systemctl restart|systemctl stop|systemctl reload|service .* restart|service .* stop|docker restart|docker stop|docker kill|podman restart|podman stop|kubectl delete pod|kubectl rollout restart|oc delete pod|oc rollout restart|kill |pkill |killall "
    COUNT=$(echo "$DIRECTIVES" | jq '.do_not_restart | length')
    if [[ "$COUNT" != "0" ]]; then
        if echo "$COMMAND_LOWER" | grep -qE "$RESTART_PATTERNS"; then
            while IFS= read -r directive; do
                PROMPT=$(echo "$directive" | jq -r '.prompt // empty')
                TIMESTAMP=$(echo "$directive" | jq -r '.timestamp // empty')
                hard_block "do not restart" "Restart/stop command detected: $COMMAND" "$PROMPT" "$TIMESTAMP"
            done < <(echo "$DIRECTIVES" | jq -c '.do_not_restart[0]' 2>/dev/null)
        fi
    fi

    # Update patterns
    UPDATE_PATTERNS="apt install|apt upgrade|apt update|apt-get install|apt-get upgrade|pip install|pip3 install|npm install|npm update|yarn add|yarn upgrade|cargo install|go install|brew install|brew upgrade|dnf install|yum install|pacman -S"
    COUNT=$(echo "$DIRECTIVES" | jq '.do_not_update | length')
    if [[ "$COUNT" != "0" ]]; then
        if echo "$COMMAND_LOWER" | grep -qE "$UPDATE_PATTERNS"; then
            while IFS= read -r directive; do
                PROMPT=$(echo "$directive" | jq -r '.prompt // empty')
                TIMESTAMP=$(echo "$directive" | jq -r '.timestamp // empty')
                hard_block "do not update" "Update/install command detected: $COMMAND" "$PROMPT" "$TIMESTAMP"
            done < <(echo "$DIRECTIVES" | jq -c '.do_not_update[0]' 2>/dev/null)
        fi
    fi
fi

exit 0
