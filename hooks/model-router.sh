#!/bin/bash
# Model Router v2.1 - Classifies prompts for model tier AND intent
# Hook: UserPromptSubmit
# Location: ~/.claude/hooks/model-router.sh
#
# Classifies two dimensions:
# 1. TIER (model complexity): fast/balanced/reasoning/local
# 2. INTENT (user expectation): action/conversation/investigate/ambiguous
#
# Uses RAG server's classify_prompt MCP tool via GraphQL for tier classification.
# Falls back to regex patterns if GraphQL unavailable.
# Intent classification is always regex-based (fast, predictable).
#
# Generic Tiers (V12 - Provider Portable):
#   fast      - Simple lookups, status checks, formatting
#   balanced  - Code review, documentation, exploration
#   reasoning - Complex architecture, novel problems, multi-step planning
#   local     - Simple tasks suitable for local LLMs
#
# Legacy aliases (for Anthropic): haiku=fast, sonnet=balanced, opus=reasoning
#
# Intents:
#   action       - User wants changes applied (fix, implement, add, deploy)
#   conversation - User wants discussion/explanation (why, how, compare, options)
#   investigate  - User wants diagnosis (check, debug, what's wrong, explore)
#   ambiguous    - Intent unclear, ask before modifying

set -uo pipefail

ROUTING_LOG="$HOME/.claude/routing-decisions.jsonl"
WORKFLOW_STATE_DIR="$HOME/.claude/workflow-state"
# Per-call deadline for the MCP classify_prompt round-trip. 41% of routing
# decisions historically defaulted because the legacy local GraphQL endpoint
# (127.0.0.1:8765) wasn't listening; we now go through the surface-aware
# rag-mcp tool. Keep the deadline well under the hook cap so the regex
# fallback fires fast when the classifier is cold.
TIMEOUT=3

# Read input
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // empty' 2>/dev/null)

# If no prompt extracted, try reading raw input
if [[ -z "$PROMPT" ]]; then
    PROMPT="$INPUT"
fi

# Save prompt for intent enforcement (override phrase detection)
mkdir -p "$HOME/.claude/session-state"
echo "$PROMPT" > "$HOME/.claude/session-state/last-prompt.txt" 2>/dev/null || true

# Skip very short prompts (likely follow-ups or confirmations)
if [[ ${#PROMPT} -lt 15 ]]; then
    exit 0
fi

PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')
PROMPT_SNIPPET=$(echo "$PROMPT" | head -c 200 | tr -d '\n' | sed 's/"/\\"/g')
PROMPT_HASH=$(echo "$PROMPT" | md5sum | cut -c1-16)

# Get session and workflow context
get_session_id() {
    local pwd_hash=$(echo "$PWD" | sed 's|/|-|g' | sed 's|^-||')
    local transcript_dir="$HOME/.claude/projects/-${pwd_hash}"
    if [[ -d "$transcript_dir" ]]; then
        local latest=$(ls -t "$transcript_dir"/*.jsonl 2>/dev/null | head -1)
        if [[ -n "$latest" ]]; then
            stat -c '%i-%Y' "$latest" 2>/dev/null || echo "unknown"
            return
        fi
    fi
    echo "pid-$$-${pwd_hash:0:16}"
}

get_workflow_id() {
    local pwd_hash=$(echo "$PWD" | md5sum | cut -c1-8)
    local workflow_file="$WORKFLOW_STATE_DIR/workflow-${pwd_hash}.id"
    if [[ -f "$workflow_file" ]]; then
        local file_age=$(( $(date +%s) - $(stat -c %Y "$workflow_file") ))
        if (( file_age < 1800 )); then
            cat "$workflow_file"
            return
        fi
    fi
    echo ""
}

# Classification patterns for fallback
HAIKU_PATTERNS=(
    "^what is "
    "^what does "
    "^what's "
    "^how do i "
    "^how to "
    "^list "
    "^show me "
    "^show the "
    "^check "
    "^status "
    "^is there "
    "^are there "
    "^where is "
    "^which "
    "^when "
    "^tell me "
    "^explain briefly"
    "^quick "
    "^simple "
    "^just "
    "^format "
    "^convert "
    "^yes$"
    "^no$"
    "^ok$"
    "^continue$"
)

SONNET_PATTERNS=(
    "review"
    "document"
    "explain.*how"
    "explain.*why"
    "explore"
    "search.*for"
    "find.*all"
    "analyze"
    "compare"
    "summarize"
    "describe"
    "investigate"
    "understand"
    "look.*at"
    "read.*and"
    "check.*for.*issues"
    "test"
    "verify"
    "validate"
)

OPUS_PATTERNS=(
    "implement"
    "build"
    "create.*new"
    "design"
    "architect"
    "refactor"
    "rewrite"
    "optimize"
    "fix.*bug"
    "debug"
    "complex"
    "multi-step"
    "plan.*implementation"
    "help me with"
    "i need.*feature"
    "add.*feature"
    "integrate"
    "migrate"
    "upgrade"
    "restructure"
)

LOCAL_PATTERNS=(
    "^run "
    "^execute "
    "^start "
    "^stop "
    "^restart "
    "^grep "
    "^find "
    "^ls "
    "^cat "
    "^read the "
    "^show file"
    "^git status"
    "^git log"
    "^git diff"
    "^kubectl get"
    "^oc get"
)

# Map internal tier names to generic portable names (V12)
tier_to_generic() {
    local tier="$1"
    case "$tier" in
        haiku)     echo "fast" ;;
        sonnet)    echo "balanced" ;;
        opus)      echo "reasoning" ;;
        local)     echo "local" ;;
        # Already generic
        fast|balanced|reasoning) echo "$tier" ;;
        *)         echo "$tier" ;;
    esac
}

# Map generic names back to Claude-specific (for backward compatibility)
tier_to_claude() {
    local tier="$1"
    case "$tier" in
        fast)      echo "haiku" ;;
        balanced)  echo "sonnet" ;;
        reasoning) echo "opus" ;;
        local)     echo "local" ;;
        # Already Claude-specific
        haiku|sonnet|opus) echo "$tier" ;;
        *)         echo "$tier" ;;
    esac
}

# Intent classification patterns
# ACTION: User wants something done/changed/built
ACTION_PATTERNS=(
    "^fix "
    "^implement"
    "^build "
    "^create "
    "^add "
    "^remove "
    "^delete "
    "^update "
    "^change "
    "^modify "
    "^apply "
    "^deploy "
    "^install "
    "^configure "
    "^set up"
    "^setup "
    "^enable "
    "^disable "
    "^do "
    "^make "
    "^write "
    "^refactor"
    "^rewrite"
    "^migrate"
    "go ahead"
    "do it"
    "please fix"
    "please implement"
    "please add"
    "i need you to"
    "can you fix"
    "can you implement"
    "can you add"
)

# CONVERSATION: User wants discussion/explanation (no changes)
CONVERSATION_PATTERNS=(
    "^explain "
    "^why "
    "^how does"
    "^how do "
    "^what is"
    "^what are"
    "^what does"
    "^what's "
    "^tell me"
    "^describe "
    "^can you explain"
    "^help me understand"
    "^i don't understand"
    "^what would"
    "^what options"
    "^options for"
    "^alternatives"
    "^pros and cons"
    "^trade-?offs"
    "^difference between"
    "^compare "
    "^comparison"
    "^should i"
    "^should we"
    "^is it better"
    "^which is better"
    "^thoughts on"
    "^opinion on"
)

# INVESTIGATE: User wants research/diagnosis (report findings, wait for direction)
# Includes problem descriptions that don't explicitly ask for action
INVESTIGATE_PATTERNS=(
    "^look at"
    "^look into"
    "^check "
    "^what's wrong"
    "^what went wrong"
    "^why is.*broken"
    "^why is.*failing"
    "^why is.*not working"
    "^debug "
    "^diagnose"
    "^investigate"
    "^find out"
    "^figure out"
    "^trace "
    "^where is"
    "^find the"
    "^search for"
    "^explore "
    "^review "
    "^analyze "
    "^what happened"
    "^what's happening"
    "^status of"
    "^is.*working"
    "^is.*running"
    # Problem descriptions (implicit request to investigate)
    "keeps crashing"
    "keeps failing"
    "is broken"
    "is failing"
    "not working"
    "doesn't work"
    "won't start"
    "won't run"
    "getting.*error"
    "seeing.*error"
    "throwing.*error"
    "returns.*error"
    "is down"
    "is slow"
    "is stuck"
    "is hanging"
)

# Intent classification (action vs conversation vs investigate)
classify_intent_with_regex() {
    local prompt="$1"

    # Check ACTION patterns first (explicit requests to do something)
    for pattern in "${ACTION_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            echo "action|0.85|matched action pattern: $pattern"
            return
        fi
    done

    # Check CONVERSATION patterns (wants discussion, not changes)
    for pattern in "${CONVERSATION_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            echo "conversation|0.80|matched conversation pattern: $pattern"
            return
        fi
    done

    # Check INVESTIGATE patterns (research/diagnose, report back)
    for pattern in "${INVESTIGATE_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            echo "investigate|0.80|matched investigate pattern: $pattern"
            return
        fi
    done

    # Default: ambiguous - could be either
    # Short prompts lean toward action, long prompts lean toward conversation
    local len=${#prompt}
    if (( len < 30 )); then
        echo "action|0.50|short prompt, assuming action"
    elif (( len > 200 )); then
        echo "conversation|0.50|long prompt, assuming conversation"
    else
        echo "ambiguous|0.40|no clear intent signals"
    fi
}

# Regex fallback classification
classify_with_regex() {
    local prompt="$1"
    local classification="sonnet"
    local confidence="0.50"
    local reason="default"

    # Check LOCAL patterns first (most specific)
    for pattern in "${LOCAL_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            echo "local|0.80|matched local pattern: $pattern"
            return
        fi
    done

    # Check HAIKU patterns (simple tasks)
    for pattern in "${HAIKU_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            echo "haiku|0.75|matched haiku pattern: $pattern"
            return
        fi
    done

    # Check OPUS patterns (complex tasks)
    for pattern in "${OPUS_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            echo "opus|0.80|matched opus pattern: $pattern"
            return
        fi
    done

    # Check SONNET patterns (moderate complexity)
    for pattern in "${SONNET_PATTERNS[@]}"; do
        if echo "$prompt" | grep -qiE "$pattern"; then
            echo "sonnet|0.70|matched sonnet pattern: $pattern"
            return
        fi
    done

    # Length-based heuristic
    local len=${#prompt}
    if (( len < 50 )); then
        echo "haiku|0.60|short prompt ($len chars)"
    elif (( len > 500 )); then
        echo "opus|0.65|long detailed prompt ($len chars)"
    else
        echo "sonnet|0.50|default (no patterns matched)"
    fi
}

# Classification via the surface-aware rag-mcp classify_prompt tool. This
# replaces the legacy local GraphQL path (which silently went dark and made
# every prompt fall through to regex). Returns "tier|confidence|reasoning
# (via method)" on success, non-zero on failure; the caller falls back to
# regex on non-zero.
classify_with_mcp() {
    local prompt="$1"

    local mc="$HOME/.claude/hooks/lib/mcp-call.sh"
    [[ -x "$mc" ]] || return 1

    # Resolve the right rag-mcp surface for this cwd (Coldforge vs Empire).
    # surface-resolve.sh sets _SURFACE/MCP_URL/TOKEN_FILE from cwd.
    [[ -f "$HOME/.claude/hooks/lib/surface-resolve.sh" ]] || return 1
    # shellcheck source=lib/surface-resolve.sh
    . "$HOME/.claude/hooks/lib/surface-resolve.sh" 2>/dev/null || return 1
    local resolved
    resolved=$(sr_resolve "${PWD:-$HOME}" 2>/dev/null) || return 1
    local _surface _company _server mcp_url token_file
    IFS='|' read -r _surface _company _server mcp_url token_file <<< "$resolved"
    [[ -n "$mcp_url" && -n "$token_file" ]] || return 1

    local args
    args=$(jq -nc --arg p "$prompt" '{prompt:$p}') || return 1

    local response
    response=$(timeout "$TIMEOUT" "$mc" "$mcp_url" "$token_file" classify_prompt "$args" 2>/dev/null) || return 1
    [[ -n "$response" ]] || return 1

    # Response is markdown with **Tier:** / **Confidence:** / **Reasoning:**
    # / **Method:** fields. Extract by line prefix.
    local tier confidence reasoning method
    tier=$(awk -F'\\*\\*Tier:\\*\\*' '/Tier:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}' <<<"$response")
    confidence=$(awk -F'\\*\\*Confidence:\\*\\*' '/Confidence:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}' <<<"$response")
    reasoning=$(awk -F'\\*\\*Reasoning:\\*\\*' '/Reasoning:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}' <<<"$response")
    method=$(awk -F'\\*\\*Method:\\*\\*' '/Method:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}' <<<"$response")

    if [[ -n "$tier" && -n "$confidence" ]]; then
        echo "$tier|$confidence|$reasoning (via $method)"
        return 0
    fi
    return 1
}

# Try the MCP classifier first, fall back to regex.
classify_prompt() {
    local prompt="$1"
    local result
    if result=$(classify_with_mcp "$prompt"); then
        echo "$result"
        return
    fi
    classify_with_regex "$prompt"
}

# Classify the prompt (tier and intent)
IFS='|' read -r CLASSIFICATION CONFIDENCE REASON <<< "$(classify_prompt "$PROMPT_LOWER")"
IFS='|' read -r INTENT INTENT_CONFIDENCE INTENT_REASON <<< "$(classify_intent_with_regex "$PROMPT_LOWER")"

SESSION_ID=$(get_session_id)
WORKFLOW_ID=$(get_workflow_id)

# Capture current session model and provider info (V11 Phase 4.1)
CURRENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-unknown}"
CURRENT_PROVIDER="anthropic"  # Default assumption

# Detect provider based on environment variables
if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    if [[ "$ANTHROPIC_BASE_URL" == *"ollama"* ]]; then
        CURRENT_PROVIDER="ollama"
    elif [[ "$ANTHROPIC_BASE_URL" == *"openai"* ]]; then
        CURRENT_PROVIDER="openai"
    elif [[ -n "${COPILOT_URL:-}" && "$ANTHROPIC_BASE_URL" == "$COPILOT_URL" ]]; then
        CURRENT_PROVIDER="copilot"
    fi
fi

# Log the routing decision (V11: now includes session model/provider)
printf '{"ts":"%s","prompt_hash":"%s","prompt_snippet":"%s","classification":"%s","confidence":%s,"reason":"%s","intent":"%s","intent_confidence":%s,"intent_reason":"%s","project_path":"%s","session_id":"%s","workflow_id":"%s","session_model":"%s","session_provider":"%s"}\n' \
    "$(date -Iseconds)" \
    "$PROMPT_HASH" \
    "$PROMPT_SNIPPET" \
    "$CLASSIFICATION" \
    "$CONFIDENCE" \
    "${REASON//\"/\\\"}" \
    "$INTENT" \
    "$INTENT_CONFIDENCE" \
    "${INTENT_REASON//\"/\\\"}" \
    "$PWD" \
    "$SESSION_ID" \
    "$WORKFLOW_ID" \
    "$CURRENT_MODEL" \
    "$CURRENT_PROVIDER" >> "$ROUTING_LOG"

# Save current routing for Stop hook enforcement (now includes intent).
# The prompt_hash is the canonical routing_decision_id — agent-tracker
# picks this up on Task PreToolUse and stamps it on the agent's invoke
# event so we can later join routing_decisions to agent_metrics at the
# decision level (closing the routing_compliance view gap documented
# 2026-05-05 — time-window matching alone is insufficient).
ROUTING_STATE_FILE="$HOME/.claude/session-state/current-routing.json"
mkdir -p "$HOME/.claude/session-state"
printf '{"classification":"%s","confidence":%s,"intent":"%s","intent_confidence":%s,"timestamp":"%s","prompt_hash":"%s","session_id":"%s","workflow_id":"%s"}\n' \
    "$CLASSIFICATION" "$CONFIDENCE" "$INTENT" "$INTENT_CONFIDENCE" "$(date -Iseconds)" "$PROMPT_HASH" "$SESSION_ID" "$WORKFLOW_ID" > "$ROUTING_STATE_FILE"

# Map to generic tier names (V12)
GENERIC_TIER=$(tier_to_generic "$CLASSIFICATION")

# Output suggestions to Claude
echo "<model-routing-suggestion>"

# Tier suggestion (only for non-reasoning tier)
if [[ "$GENERIC_TIER" != "reasoning" ]]; then
    echo "Task complexity: $GENERIC_TIER (confidence: $CONFIDENCE)"
    if [[ "$GENERIC_TIER" == "fast" ]]; then
        echo "  → When spawning subagents, use model: haiku (98% savings vs opus)"
    elif [[ "$GENERIC_TIER" == "balanced" ]]; then
        echo "  → Default sonnet model for subagents is appropriate (80% savings vs opus)"
    elif [[ "$GENERIC_TIER" == "local" ]]; then
        echo "  → Consider local LLMs: qwen2.5-coder-7b, deepseek-r1-7b"
    fi
fi

# Intent classification (always output)
echo ""
echo "Intent: $INTENT (confidence: $INTENT_CONFIDENCE)"
case "$INTENT" in
    action)
        echo "  → User wants RESULTS. Apply fixes immediately. Don't just explain - DO IT."
        ;;
    conversation)
        echo "  → User wants DISCUSSION. Explain, compare options, don't modify anything."
        ;;
    investigate)
        echo "  → User wants DIAGNOSIS. Research and report findings, then WAIT for direction."
        ;;
    ambiguous)
        echo "  → Intent unclear. If you identify a fix, ASK before applying it."
        ;;
esac

# Auto-escalation to reasoning-tier agent (Phase 2.2 - V11 roadmap, V12 portable)
if [[ "$GENERIC_TIER" == "reasoning" && "$CONFIDENCE" > "0.7" ]]; then
    CURRENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-unknown}"
    if [[ "$CURRENT_MODEL" == *"sonnet"* || "$CURRENT_MODEL" == *"balanced"* ]]; then
        echo ""
        echo "🧠 Auto-escalation suggestion:"
        echo "  → This task requires reasoning-tier capabilities but you're in a balanced session"
        echo "  → Consider: Task tool with subagent_type='opus-reasoner'"
        echo "  → Use case: Complex architecture, multi-step planning, architectural tradeoffs"
        echo "  → This keeps your main conversation cost-efficient while accessing deep reasoning"
    fi
fi

echo "</model-routing-suggestion>"

exit 0
