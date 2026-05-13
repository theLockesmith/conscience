#!/bin/bash
# Pre-completion verification hook - catches "done/complete/finished" claims
# Triggers before declaring work complete to enforce actual testing
#
# Usage: Add to hooks.yaml StopGeneration with patterns like:
# - "fully implemented"
# - "completely verified"
# - "end-to-end tested"

set -euo pipefail

# Read the response content
RESPONSE="${CLAUDE_HOOK_RESPONSE_CONTENT:-}"

# Patterns that indicate completion claims (case insensitive)
COMPLETION_PATTERNS=(
    "fully implemented"
    "completely verified"
    "end-to-end (tested|verified)"
    "all.*(working|complete|done)"
    "successfully (deployed|implemented|verified)"
    "verification.*(complete|successful)"
    "dashboard.*(working|verified|tested)"
    "pipeline.*(verified|tested|working)"
)

# Check each pattern
for pattern in "${COMPLETION_PATTERNS[@]}"; do
    if echo "$RESPONSE" | grep -qiE "$pattern"; then
        echo "⚠️  VERIFICATION CHECKPOINT: '$pattern' detected"
        echo ""
        echo "BEFORE claiming completion, have you:"
        echo "1. ✅ Actually TESTED the component (not just created files)?"
        echo "2. ✅ Verified all data flows work (not just schema exists)?"
        echo "3. ✅ Confirmed external services are accessible?"
        echo "4. ✅ Checked actual output/visualization (not just API calls)?"
        echo ""
        echo "If you answered NO to any of these:"
        echo "→ Test the missing components first"
        echo "→ Report what you ACTUALLY verified vs what needs auth/access"
        echo "→ Be precise about limitations"
        echo ""
        echo "Proceeding with completion claim..."
        break
    fi
done

exit 0  # Allow response, just warn