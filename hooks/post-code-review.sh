#!/bin/bash
# Post-Code Review Suggester - Suggests review after significant code edits
# Hook: PostToolUse (matcher: Edit|Write)
# Location: ~/.claude/hooks/post-code-review.sh
#
# Tracks edited files and suggests review after:
# - 3+ unique code files edited, OR
# - 50+ total lines changed
#
# Uses session file to track state. Resets after suggestion is shown.

set -uo pipefail

# Session tracking file (unique per terminal session)
SESSION_FILE="/tmp/claude-code-edits-$$"
# Fallback if $$ doesn't work well with hooks
if [[ ! -f "$SESSION_FILE" ]]; then
    SESSION_FILE="/tmp/claude-code-edits-$(date +%Y%m%d)"
fi

# Code file extensions to track
CODE_EXTENSIONS="py|rs|ts|tsx|js|jsx|go|java|c|cpp|h|hpp|rb|php|swift|kt|scala|sh|bash|zsh"

# Read hook input (JSON with tool info)
HOOK_INPUT=$(cat)

# Extract file path from the hook input
# PostToolUse receives the tool call result
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.toolInput.file_path // .toolInput.path // empty' 2>/dev/null)

# Exit if we couldn't parse the file path
if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Check if it's a code file
EXTENSION="${FILE_PATH##*.}"
if ! echo "$EXTENSION" | grep -qiE "^($CODE_EXTENSIONS)$"; then
    exit 0
fi

# Initialize session file if needed
if [[ ! -f "$SESSION_FILE" ]]; then
    echo "0" > "$SESSION_FILE"  # Line 1: files count
    echo "0" >> "$SESSION_FILE" # Line 2: lines changed estimate
    echo "0" >> "$SESSION_FILE" # Line 3: suggestion shown (0/1)
fi

# Read current state
FILES_COUNT=$(sed -n '1p' "$SESSION_FILE")
LINES_CHANGED=$(sed -n '2p' "$SESSION_FILE")
SUGGESTION_SHOWN=$(sed -n '3p' "$SESSION_FILE")

# Skip if we already showed the suggestion this session
if [[ "$SUGGESTION_SHOWN" == "1" ]]; then
    exit 0
fi

# Update counts
FILES_COUNT=$((FILES_COUNT + 1))
# Estimate lines changed (we don't have exact count, assume 10 per edit)
LINES_CHANGED=$((LINES_CHANGED + 10))

# Save updated state
echo "$FILES_COUNT" > "$SESSION_FILE"
echo "$LINES_CHANGED" >> "$SESSION_FILE"
echo "$SUGGESTION_SHOWN" >> "$SESSION_FILE"

# Check thresholds
SUGGEST_REVIEW=false
REASON=""

if [[ $FILES_COUNT -ge 3 ]]; then
    SUGGEST_REVIEW=true
    REASON="$FILES_COUNT code files edited"
elif [[ $LINES_CHANGED -ge 50 ]]; then
    SUGGEST_REVIEW=true
    REASON="significant code changes (~$LINES_CHANGED lines)"
fi

# Output suggestion if threshold met
if [[ "$SUGGEST_REVIEW" == "true" ]]; then
    # Mark suggestion as shown
    echo "$FILES_COUNT" > "$SESSION_FILE"
    echo "$LINES_CHANGED" >> "$SESSION_FILE"
    echo "1" >> "$SESSION_FILE"

    # Output to stderr (PostToolUse output goes to model context)
    cat << EOF
<post-tool-hook>
CODE REVIEW SUGGESTION ($REASON):

Consider using the reviewer agent to check for:
- Code quality and readability
- Potential bugs or edge cases
- Best practices adherence

Invoke with: Task tool, subagent_type="reviewer"
Or for security-sensitive code: subagent_type="security"
</post-tool-hook>
EOF
fi

exit 0
