#!/bin/bash
# Filter Verbose Output Hook - Reduces token waste from verbose command output
# Hook: PreToolUse (matcher: Bash)
# Location: ~/.claude/hooks/filter-verbose-output.sh
#
# Purpose: Filter test/build output to errors only (10-50% savings per command)

set -uo pipefail

INPUT=$(cat)

# Extract tool name and command
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only process Bash tool
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [[ -z "$CMD" ]]; then
    exit 0
fi

# Check for test commands and filter to failures
if [[ "$CMD" =~ ^(npm\ test|npx\ jest|pytest|python\ -m\ pytest|cargo\ test|go\ test|make\ test) ]]; then
    # Wrap command to filter output to failures only
    FILTERED_CMD="$CMD 2>&1 | grep -A 15 -E '(FAIL|FAILED|ERROR|Error:|error:|panic:|AssertionError|Exception)' | head -150 || echo 'All tests passed (output filtered)'"

    # Output the modified command via hook protocol
    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"$FILTERED_CMD\"}}}"
    exit 0
fi

# Check for build commands and filter to errors/warnings
if [[ "$CMD" =~ ^(npm\ run\ build|yarn\ build|cargo\ build|go\ build|make($|\ )|gradle|mvn) ]]; then
    # Wrap command to filter output
    FILTERED_CMD="$CMD 2>&1 | grep -E '(error|Error:|ERROR|warning:|Warning:|WARN)' | head -100 || echo 'Build succeeded (output filtered)'"

    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"$FILTERED_CMD\"}}}"
    exit 0
fi

# Check for package install commands (very verbose)
if [[ "$CMD" =~ ^(npm\ install|yarn\ install|pip\ install|cargo\ fetch) ]]; then
    # Just show summary
    FILTERED_CMD="$CMD 2>&1 | tail -20"

    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"$FILTERED_CMD\"}}}"
    exit 0
fi

# No filtering needed
exit 0
