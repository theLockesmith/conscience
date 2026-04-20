#!/bin/bash
# Enforce answering user questions directly
# Location: ~/.claude/hooks/enforce-question-answering.sh
# Hook type: Stop (checks response before showing to user)
#
# PURPOSE: Block responses that don't directly answer user questions
# User requirement: "ANSWER ME WHEN I ASK YOU A QUESTION"

set -uo pipefail

INPUT=$(cat)

# Extract user's last message and assistant's response
USER_MESSAGE=$(echo "$INPUT" | jq -r '.messages[-2].content // empty' 2>/dev/null)
ASSISTANT_RESPONSE=$(echo "$INPUT" | jq -r '.messages[-1].content // empty' 2>/dev/null)

# If we can't extract messages, pass through
[[ -z "$USER_MESSAGE" || -z "$ASSISTANT_RESPONSE" ]] && exit 0

# Detect if user message contains a direct question
# Questions end with ? or start with question words
QUESTION_PATTERNS=(
    '\?$'                           # Ends with ?
    '\?\s*$'                        # Ends with ? (with trailing space)
    '^(do|does|did|is|are|was|were|have|has|had|can|could|would|should|will|shall)\s'  # Yes/no questions
    '^(what|where|when|why|how|which|who|whom)\s'  # WH-questions
    'do you (need|want|have|know|think|understand)'  # Specific patterns
    'can you (tell|show|explain|help)'
    'is (this|that|it|there)'
    'are (you|we|they|there)'
)

IS_QUESTION=false
for pattern in "${QUESTION_PATTERNS[@]}"; do
    if echo "$USER_MESSAGE" | grep -qiE "$pattern"; then
        IS_QUESTION=true
        break
    fi
done

# If not a question, pass through
[[ "$IS_QUESTION" != "true" ]] && exit 0

# Check if response starts with a direct answer
# Direct answers: yes, no, specific answer, not deflection/summary
DIRECT_ANSWER_PATTERNS=(
    '^yes[,.\s!]'
    '^no[,.\s!]'
    '^i (do|don.t|did|didn.t|can|can.t|will|won.t|have|haven.t|need|don.t need)'
    '^(the|it|they|this|that) (is|are|was|were)'
    '^[0-9]'                        # Starts with number (specific answer)
    '^here'                         # "Here is..."
    '^there (is|are)'
)

STARTS_WITH_ANSWER=false
# Get first 200 chars of response for checking
RESPONSE_START=$(echo "$ASSISTANT_RESPONSE" | head -c 200 | tr '[:upper:]' '[:lower:]')

for pattern in "${DIRECT_ANSWER_PATTERNS[@]}"; do
    if echo "$RESPONSE_START" | grep -qiE "$pattern"; then
        STARTS_WITH_ANSWER=true
        break
    fi
done

# Check for deflection patterns (bad responses)
DEFLECTION_PATTERNS=(
    '^let me'                       # "Let me first..." (deflection)
    '^first,? (i.ll|let me|we)'    # "First, I'll..." (deflection)
    '^i.ll start by'               # Deflection
    '^to answer that'              # Deflection
    '^before (i|we) (answer|address)'  # Deflection
    '^i understand'                # Validation before answer
    '^great question'              # Validation
    '^that.s a good'               # Validation
)

IS_DEFLECTION=false
for pattern in "${DEFLECTION_PATTERNS[@]}"; do
    if echo "$RESPONSE_START" | grep -qiE "$pattern"; then
        IS_DEFLECTION=true
        break
    fi
done

# Block if response starts with deflection
if [[ "$IS_DEFLECTION" == "true" ]]; then
    cat << EOF
{"decision": "block", "reason": "Response deflects instead of answering the question directly. User asked a question - answer it FIRST, then provide context."}
EOF
    exit 0
fi

# If question detected but no direct answer pattern found, warn but don't block
# (False positives are worse than false negatives here)
if [[ "$STARTS_WITH_ANSWER" != "true" ]]; then
    # Log for monitoring but don't block - pattern matching isn't perfect
    echo "[QUESTION-ANSWER] User question may not have been directly answered" >> "$HOME/.claude/security/audit.log" 2>/dev/null || true
fi

exit 0
