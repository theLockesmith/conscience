#!/bin/bash
# Custom Slash Commands Hook
# Hook: UserPromptSubmit
# Expands user-defined /commands from ~/.claude/commands.yaml

set -uo pipefail

COMMANDS_FILE="$HOME/.claude/commands.yaml"

# Read user prompt from stdin
USER_PROMPT=$(cat)

# Check if prompt starts with / (custom command)
if [[ ! "$USER_PROMPT" =~ ^/ ]]; then
    exit 0
fi

# Check if commands file exists
if [[ ! -f "$COMMANDS_FILE" ]]; then
    exit 0
fi

# Extract command name and arguments
COMMAND_LINE="${USER_PROMPT#/}"
COMMAND_NAME=$(echo "$COMMAND_LINE" | awk '{print $1}')
COMMAND_ARGS=$(echo "$COMMAND_LINE" | cut -d' ' -f2- 2>/dev/null || echo "")

# Skip built-in commands (let Claude Code handle them)
BUILTIN_COMMANDS="help|clear|compact|config|cost|doctor|init|login|logout|memory|model|mcp|permissions|pr-comments|review|status|terminal-setup|vim|bug|hooks|skills"
if echo "$COMMAND_NAME" | grep -qE "^($BUILTIN_COMMANDS)$"; then
    exit 0
fi

# Look up command in YAML (simple parsing without yq dependency)
# Extract the template for the command
TEMPLATE=$(awk -v cmd="$COMMAND_NAME" '
    BEGIN { in_cmd = 0; in_template = 0; template = "" }
    /^  [a-z_-]+:/ {
        if (in_template) { in_template = 0 }
        gsub(/^  /, "")
        gsub(/:.*/, "")
        if ($0 == cmd) { in_cmd = 1 } else { in_cmd = 0 }
    }
    in_cmd && /template: \|/ { in_template = 1; next }
    in_template && /^      / {
        gsub(/^      /, "")
        template = template $0 "\n"
    }
    in_template && /^  [a-z]/ { in_template = 0 }
    END { printf "%s", template }
' "$COMMANDS_FILE")

# If no template found, exit silently (might be a built-in or typo)
if [[ -z "$TEMPLATE" ]]; then
    exit 0
fi

# Get description
DESCRIPTION=$(awk -v cmd="$COMMAND_NAME" '
    BEGIN { in_cmd = 0 }
    /^  [a-z_-]+:/ {
        gsub(/^  /, "")
        gsub(/:.*/, "")
        if ($0 == cmd) { in_cmd = 1 } else { in_cmd = 0 }
    }
    in_cmd && /description:/ {
        gsub(/.*description: *"?/, "")
        gsub(/"$/, "")
        print
        exit
    }
' "$COMMANDS_FILE")

# Expand variables in template
EXPANDED="$TEMPLATE"

# $* - all arguments
EXPANDED="${EXPANDED//\$\*/$COMMAND_ARGS}"

# $1, $2, etc. - positional arguments
set -- $COMMAND_ARGS
for i in 1 2 3 4 5 6 7 8 9; do
    eval "ARG=\${$i:-}"
    EXPANDED="${EXPANDED//\$$i/$ARG}"
done

# $PROJECT - current project name
PROJECT_NAME=$(basename "$(pwd)")
EXPANDED="${EXPANDED//\$PROJECT/$PROJECT_NAME}"

# Output the expansion
echo "<user-prompt-submit-hook>"
echo "CUSTOM COMMAND: /$COMMAND_NAME"
if [[ -n "$DESCRIPTION" ]]; then
    echo "($DESCRIPTION)"
fi
echo ""
echo "Expanded prompt:"
echo "---"
echo "$EXPANDED"
echo "---"
echo "</user-prompt-submit-hook>"

exit 0
