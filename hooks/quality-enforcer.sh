#!/bin/bash
# Quality Enforcer v14 - 30 enforcement categories
# v14: Added ABSOLUTE_PATH - blocks /home/forgemaster/ in text output, requires ~/ paths
# v13: Tightened DEPLOYMENT_UNVERIFIED escape - no longer accepts "http 200", "test results"
#      Now requires actual agent invocation evidence (subagent_type, screenshot saved, etc.)
# Hook: Stop
#
# OPTIMIZATIONS (v6+):
# - Combined regex patterns per category (single grep instead of 50+ per category)
# - Fast-path exit when no patterns match
# - Only iterate to find specific pattern when match detected
# - Reduced subprocess spawning
#
# ENFORCED PRINCIPLES (27 categories):
# DEFERRAL | HEDGING | BYPASS | LIFECYCLE | DATA OPS | VERIFICATION
# OBSERVABILITY | BOUNDARIES | DETERMINISM | REVERSIBILITY | SPEED>CORRECT
# WISHY-WASHY | ASSUMPTIONS | IGNORE PATTERNS | INCOMPLETE ANALYSIS
# SCOPE CREEP | NOT VERIFYING | IGNORING ERRORS | INCOMPLETE REQS
# NOT CHECKING | APOLOGY/VALID | UNEXPLAINED | MEMORY
# SECURITY | RESOURCE CLEANUP | BREAKING CHANGES | DEPENDENCIES
# INFRA SUGGESTION (must search RAG before suggesting infrastructure actions)
#
# NON-NEGOTIABLE: Every violation is a HARD BLOCK. No exceptions.

set -uo pipefail

# Kill switch: DISABLE_QUALITY_ENFORCER=1 claude
[[ "${DISABLE_QUALITY_ENFORCER:-}" == "1" ]] && exit 0

LOG_FILE="$HOME/.claude/quality-enforcement.log"
METRICS_FILE="$HOME/.claude/quality-enforcement-metrics.jsonl"
SENSITIVITY_FILE="$HOME/.claude/quality-sensitivity.conf"
WHITELIST_FILE="$HOME/.claude/quality-whitelist.conf"
STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

# Load sensitivity configuration
declare -A CATEGORY_MODE
if [[ -f "$SENSITIVITY_FILE" ]]; then
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        # Remove any trailing whitespace
        value="${value%%[[:space:]]}"
        CATEGORY_MODE["$key"]="$value"
    done < "$SENSITIVITY_FILE"
fi

# Load whitelist patterns into an array
declare -a WHITELIST_PATTERNS
if [[ -f "$WHITELIST_FILE" ]]; then
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] && WHITELIST_PATTERNS+=("$line")
    done < "$WHITELIST_FILE"
fi

# Get category mode (default: block)
get_category_mode() {
    local category_key="$1"
    echo "${CATEGORY_MODE[${category_key}_MODE]:-block}"
}

# Check if response matches any whitelist pattern
is_whitelisted() {
    for pattern in "${WHITELIST_PATTERNS[@]}"; do
        if echo "$RESPONSE_LOWER" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

SESSION_ID="${CLAUDE_SESSION_ID:-$(echo "$PWD" | md5sum | cut -c1-16)}"
SESSION_STATE="$STATE_DIR/${SESSION_ID}.state"

[[ ! -f "$SESSION_STATE" ]] && echo "rag_logged=0" > "$SESSION_STATE"

# Read hook input
INPUT=$(cat)

# Claude Code passes metadata, not response content
# Response must be extracted from transcript file
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

RESPONSE=""
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    # Get the last assistant message with text content from transcript (JSONL format)
    # Claude Code format: {"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}
    RESPONSE=$(tac "$TRANSCRIPT_PATH" 2>/dev/null | while IFS= read -r line; do
        # Check if this is an assistant message (top-level .type field)
        msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        if [[ "$msg_type" == "assistant" ]]; then
            # Extract text content from .message.content array
            text=$(echo "$line" | jq -r '[.message.content[]? | select(.type=="text") | .text] | join("\n")' 2>/dev/null)
            if [[ -n "$text" && "$text" != "null" ]]; then
                echo "$text"
                break
            fi
        fi
    done)
fi

# Skip if no response or too short
[[ -z "$RESPONSE" || "$RESPONSE" == "null" || ${#RESPONSE} -lt 20 ]] && exit 0

# Convert to lowercase once
RESPONSE_LOWER="${RESPONSE,,}"

# Check whitelist - if matched, skip all enforcement
if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]] && is_whitelisted; then
    exit 0
fi

# Helper function: log metrics in JSON-lines format
log_metric() {
    local event_type="$1"
    local category="$2"
    local pattern="$3"
    local escape_used="${4:-}"
    local timestamp
    timestamp=$(date -Iseconds)

    # Escape special chars for JSON
    pattern=$(echo "$pattern" | sed 's/\\/\\\\/g; s/"/\\"/g')

    echo "{\"timestamp\":\"$timestamp\",\"event\":\"$event_type\",\"category\":\"$category\",\"pattern\":\"$pattern\",\"escape_used\":\"$escape_used\",\"session\":\"$SESSION_ID\"}" >> "$METRICS_FILE"
}

# Helper function: check patterns and block if matched
# Args: $1=category_name $2=combined_pattern $3=escape_pattern $4=block_reason $5=category_key
check_and_block() {
    local category="$1"
    local pattern="$2"
    local escape="$3"
    local reason="$4"
    local category_key="${5:-}"

    # Check sensitivity mode if category key provided
    if [[ -n "$category_key" ]]; then
        local mode
        mode=$(get_category_mode "$category_key")
        [[ "$mode" == "disabled" ]] && return 1
    fi

    # Quick check: does ANY pattern match?
    if echo "$RESPONSE_LOWER" | grep -qE "$pattern"; then
        # Find specific matching pattern for detailed message
        local matched=""
        local IFS='|'
        for p in $pattern; do
            if echo "$RESPONSE_LOWER" | grep -qE "$p"; then
                matched="$p"
                break
            fi
        done

        # Check escape hatch
        if [[ -n "$escape" ]] && echo "$RESPONSE_LOWER" | grep -qE "$escape"; then
            # Log escaped violation for metrics
            local escape_matched=""
            local IFS='|'
            for e in $escape; do
                if echo "$RESPONSE_LOWER" | grep -qE "$e"; then
                    escape_matched="$e"
                    break
                fi
            done
            log_metric "escaped" "$category" "$matched" "$escape_matched"
            return 1
        fi

        # Check if this is warn-only mode
        local mode="block"
        [[ -n "$category_key" ]] && mode=$(get_category_mode "$category_key")

        if [[ "$mode" == "warn" ]]; then
            # Warn only - log but don't block
            log_metric "warned" "$category" "$matched"
            echo "[$(date -Iseconds)] WARNING: $category - '$matched'" >> "$LOG_FILE"
            echo "<system-reminder>WARNING: $reason ('$matched')</system-reminder>"
            return 1
        fi

        # Block mode - log and reject
        log_metric "blocked" "$category" "$matched"

        echo "[$(date -Iseconds)] BLOCKED: $category - '$matched'" >> "$LOG_FILE"
        echo "Response excerpt: ${RESPONSE:0:300}..." >> "$LOG_FILE"
        echo "---" >> "$LOG_FILE"

        # Circuit breaker: track consecutive blocks
        BLOCK_COUNT_FILE="$STATE_DIR/${SESSION_ID}.qe_block_count"
        BLOCK_COUNT=0
        [[ -f "$BLOCK_COUNT_FILE" ]] && BLOCK_COUNT=$(cat "$BLOCK_COUNT_FILE")
        BLOCK_COUNT=$((BLOCK_COUNT + 1))
        echo "$BLOCK_COUNT" > "$BLOCK_COUNT_FILE"

        # After 5 consecutive blocks, allow to prevent infinite loops
        if [[ $BLOCK_COUNT -ge 5 ]]; then
            echo "[$(date -Iseconds)] CIRCUIT BREAKER TRIPPED after $BLOCK_COUNT blocks - allowing" >> "$LOG_FILE"
            rm -f "$BLOCK_COUNT_FILE"
            return 1
        fi

        cat << EOF
{"decision": "block", "reason": "STOP GENERATING TEXT. $reason ('$matched') - Use a TOOL CALL to verify/research instead of guessing."}
EOF
        exit 0
    fi
    return 1
}

# =============================================================================
# CATEGORY DEFINITIONS - Combined patterns for efficiency
# =============================================================================

# DEFERRAL
DEFERRAL_P="i'll.*later|do.*later|add.*later|implement.*later|fix.*later|address.*later|handle.*later|update.*later|we can.*later|you can.*later|could.*later|should.*later|for now|for the moment|for the time being|short term|short-term|temporary|temporarily|interim|stopgap|band-aid|bandaid|quick fix|quick solution|quick workaround|simple fix|simple workaround|easy fix|easy workaround|xxx:|xxx |placeholder|stub|skeleton|dummy|mock.*for now|leave.*for now|skip.*for now|ignore.*for now|worry about.*later|deal with.*later|come back to|revisit.*later|circle back|future improvement|future enhancement|future work|out of scope|beyond.*scope|one-off|one off|just this once|quick and dirty|good enough for now|works for now|sufficient for now"

check_and_block "Deferral" "$DEFERRAL_P" "" \
    "DEFERRAL BLOCKED: Complete the work properly NOW, or explicitly state why it cannot be done. No temporary solutions." \
    "DEFERRAL"

# TODO/FIXME CREATION
TODO_P="added.*todo|add.*todo|adding.*todo|left.*todo|leaving.*todo|created.*todo|creating.*todo|put.*todo|putting.*todo|inserted.*todo|wrote.*todo|added.*fixme|left.*fixme|created.*fixme|added.*hack|left.*hack|marked.*todo|marked.*fixme|noted.*todo|noted.*fixme|i'll.*todo|we'll.*todo|todo.*to handle|todo.*to implement|todo.*to fix|fixme.*to handle|left.*unfinished|left.*incomplete|left.*undone|leaving.*unfinished|leaving.*incomplete"

check_and_block "TODO/FIXME Creation" "$TODO_P" "" \
    "TODO/FIXME BLOCKED: Do not defer work via code comments. Complete it NOW or create a proper issue." \
    "TODO_FIXME_CREATION"

# HEDGING
HEDGING_P="should work|should be fine|should be okay|should be enough|probably work|probably fine|probably okay|might work|might be|may work|may be enough|i think this|i think it|i believe this|i believe it|i assume|i'm guessing|i guess|not sure if|not certain|hopefully|fingers crossed|with luck|if all goes well|partial.*implementation|basic.*implementation|minimal.*implementation|simple.*implementation|rough.*implementation|initial.*implementation|first pass|first cut|rough draft|not.*complete|not.*finished|not.*done|work in progress|still need to|still needs|remaining.*todo|left to do|needs more|could be improved|room for improvement|good enough|sufficient|adequate|acceptable|just a simple|just a quick|just a basic|just need to|simply|merely|only need"
HEDGING_ESC="cannot|won't be able|not possible|limitation|constraint|restriction"

check_and_block "Hedging" "$HEDGING_P" "$HEDGING_ESC" \
    "HEDGING BLOCKED: Either VERIFY it works or do more research. No guessing." \
    "HEDGING"

# BYPASS
BYPASS_P="bypass|work.*around|workaround|shortcut|skip.*validation|skip.*check|avoid.*using|instead of using|rather than using|without.*going through|directly.*instead|direct.*call|direct.*access|one-off script|quick script|simple script|small script|helper script|utility script|standalone script|don't need to use|no need to use|skip the|ignore the|forget the|circumvent|get around|avoid the|skip over|send.*directly|call.*directly|post.*directly|directly to.*endpoint|directly to.*api|directly to.*function|directly to.*service|resend.*without|replay.*without|retry.*without|without.*logging|without.*audit|skip.*logging|no.*audit"

check_and_block "Bypass" "$BYPASS_P" "" \
    "BYPASS BLOCKED: Use existing systems. NEVER write one-off scripts or bypass code paths." \
    "BYPASS"

# LIFECYCLE
LIFECYCLE_P="no timeout|no expiration|no expiry|indefinitely|forever|no limit|unlimited retries|keep retrying|retry forever|never expires|never times out|wait indefinitely|wait forever|block until|hang until|stays in.*state|remains.*indefinitely|left in.*state|stuck in.*state|no cleanup|no reconciliation|orphaned|leaked|dangling|assume.*succeeds|assume.*works|assume.*available"
# More specific - require discussion of problem, not just the word
LIFECYCLE_ESC="the problem|this is.*problem|there's.*issue|this is.*bug|to fix|should have|needs to have|must add|is missing"

check_and_block "Lifecycle" "$LIFECYCLE_P" "$LIFECYCLE_ESC" \
    "LIFECYCLE BLOCKED: Every state must have an exit condition. Define timeouts and cleanup." \
    "LIFECYCLE"

# DATA OPERATIONS
DATA_P="not idempotent|isn't idempotent|can't be retried|cannot be retried|unsafe to retry|don't retry|only run once|run.*exactly once|no duplicate.*check|without.*duplicate|skip.*duplicate|ignore.*duplicate|allow.*duplicate|duplicates.*okay|duplicates.*fine|without checking|without verifying|assume.*current|assume.*exists|assume.*ready|assume.*valid|blind.*update|blind.*insert|blind.*send|partial.*commit|partial.*update|half.*written|inconsistent.*state|no transaction|outside.*transaction"
# More specific - require discussion of problem, not just the word
DATA_ESC="the problem|this is.*problem|there's.*issue|this is.*bug|to fix|we should|it should|must have|to avoid|to prevent"

check_and_block "Data Operations" "$DATA_P" "$DATA_ESC" \
    "DATA BLOCKED: Operations must be idempotent with duplicate detection. Never assume - VERIFY." \
    "DATA_OPERATIONS"

# VERIFICATION
VERIF_P="skip.*test|without.*test|no need to test|don't need to test|test.*later|testing.*later|untested|not tested|deploy.*without|push.*without|delete.*without|drop.*without|run.*production.*without|execute.*without.*preview|all at once|everything at once|in one go|single.*batch|bulk.*without|mass.*update|mass.*delete|mass.*insert|without.*approval|without.*review|skip.*approval|skip.*review|auto.*approve|self.*approve"
# More specific - describing what SHOULD be done, not proposing to skip
VERIF_ESC="we should|it should|must have|need to have|requires|the problem|there's.*issue|never skip|don't skip|to avoid"

check_and_block "Verification" "$VERIF_P" "$VERIF_ESC" \
    "VERIFICATION BLOCKED: All code must be tested. Dangerous operations need dry-run and approval." \
    "VERIFICATION"

# OBSERVABILITY
OBSERV_P="no logging|without logging|skip logging|disable logging|remove.*log|delete.*log|silent|silently|quiet mode|no monitoring|no metrics|without metrics|unmonitored|no visibility|no alert|without alert|fail silently|ignore.*error|swallow.*exception|catch.*pass|except.*pass"
# More specific - discussing observability problems, not proposing to skip logging
OBSERV_ESC="the problem|there's.*issue|this is.*bug|to fix|we should add|must add|need to add|should implement"

check_and_block "Observability" "$OBSERV_P" "$OBSERV_ESC" \
    "OBSERVABILITY BLOCKED: All operations must be logged. Never swallow errors silently." \
    "OBSERVABILITY"

# BOUNDARIES
BOUND_P="anyone can|everybody can|shared.*global|global.*variable|global.*state|no owner|unowned|tight.*coupling|tightly coupled|depends on.*internal|access.*internal|reach.*into|reaches.*into|poke.*directly|modify.*directly|ignore.*contract|ignore.*interface|bypass.*interface|skip.*validation|trust.*input|assume.*valid|no validation"
# More specific - discussing boundary violations, not proposing them
BOUND_ESC="the problem|there's.*issue|this is.*bug|to fix|we should|must have|to avoid|should refactor|need to refactor|don't do this"

check_and_block "Boundaries" "$BOUND_P" "$BOUND_ESC" \
    "BOUNDARY BLOCKED: Clear ownership, isolation, and contracts required." \
    "BOUNDARIES"

# DETERMINISM
DETERM_P="random|sometimes|occasionally|intermittent|flaky|unreliable|unpredictable|non-deterministic|nondeterministic|depends on.*time|time-dependent|timing-dependent|race condition|order-dependent|depends on.*order|can't reproduce|cannot reproduce|unreproducible|works on my machine|only works.*sometimes"
DETERM_ESC="problem|issue|bug|fix|investigate|found|discovered|root cause|debugging"

check_and_block "Determinism" "$DETERM_P" "$DETERM_ESC" \
    "DETERMINISM BLOCKED: Code must be deterministic with no hidden dependencies." \
    "DETERMINISM"

# REVERSIBILITY
REVERS_P="cannot.*undo|can't.*undo|no.*undo|irreversible|permanent|permanently|no way to recover|unrecoverable|cannot.*restore|can't.*restore|no.*rollback|cannot.*rollback|point of no return|delete.*without.*backup|drop.*without.*backup|truncate.*without|overwrite.*without|destroy.*without|wipe.*without"
REVERS_ESC="warning|caution|careful|must|should|need|require|ensure|make sure|before"

check_and_block "Reversibility" "$REVERS_P" "$REVERS_ESC" \
    "REVERSIBILITY BLOCKED: Actions must be reversible or explicitly acknowledged as destructive." \
    "REVERSIBILITY"

# SPEED OVER CORRECTNESS
SPEED_P="quickest|fastest|quick.*to|fast.*to|speed.*up|get.*running|up and running|get.*started|hit the ground|running quickly|running fast|easiest|easier|simpler|simplest|less work|less effort|more convenient|path of least|least resistance|low.hanging fruit|quick win|easy win|no-brainer|save.*time|saves.*time|time-saving|faster.*implement|quicker.*implement|less time|shorter.*time|minimal.*effort|minimum.*effort|least.*effort|avoid.*complexity|reduce.*complexity|keep.*simple|simple.*approach|straightforward.*approach|recommend.*because.*quick|recommend.*because.*fast|recommend.*because.*easy|suggest.*because.*quick|suggest.*because.*fast|suggest.*because.*easy"
SPEED_ESC="don't.*because|shouldn't.*because|not.*because|instead.*correct|technically correct|proper|right way|best practice|user prefer|you said|you asked|you want|you prefer"

check_and_block "Speed>Correctness" "$SPEED_P" "$SPEED_ESC" \
    "SPEED BLOCKED: NEVER recommend based on speed/ease. Recommend the TECHNICALLY CORRECT option." \
    "SPEED_CORRECTNESS"

# WISHY-WASHY
WISHY_P="you could.*or.*or|you can.*or.*or|options are|options include|several options|multiple options|few options|some options|different approaches|various approaches|several approaches|multiple approaches|here are.*options|here are.*approaches|here are.*ways|there are.*ways|it depends|depends on|up to you|your choice|your call|either way|both.*valid|all.*valid|each has.*tradeoff|each has.*pros|tradeoffs|trade-offs|pros and cons|hard to say|difficult to say|can't say which|no clear winner|no obvious|matter of preference|personal preference|subjective"
WISHY_ESC="recommend|technically correct|proper.*way|right.*approach|best.*practice|should.*use|must.*use|the.*correct.*option"

check_and_block "Wishy-Washy" "$WISHY_P" "$WISHY_ESC" \
    "WISHY-WASHY BLOCKED: State which option is MOST TECHNICALLY CORRECT and WHY." \
    "WISHY_WASHY"

# ASSUMPTIONS
ASSUME_P="i'll assume|i assume|i'm assuming|assuming that|assuming you|assuming we|let's assume|let me assume|going to assume|safe to assume|i'll go ahead|i'll just|i'll proceed|probably want|probably need|likely want|likely need|you probably|you likely|most likely you|i imagine you|i expect you|guessing you|i guess you|without knowing.*i'll|not sure.*but i'll|unclear.*but i'll|don't know.*but i'll"
ASSUME_ESC="would you like|do you want|should i|can you clarify|could you clarify|what.*prefer|which.*prefer|\?"

check_and_block "Assumptions" "$ASSUME_P" "$ASSUME_ESC" \
    "ASSUMPTION BLOCKED: Do NOT assume requirements - ASK a clarifying question." \
    "ASSUMPTIONS"

# IGNORING PATTERNS
IGNORE_P="ignore.*existing|ignoring.*existing|disregard.*existing|instead of.*existing|rather than.*existing|different from.*existing|unlike.*existing|new.*pattern|new.*approach|new.*style|new.*convention|doesn't match|won't match|different.*style|different.*pattern|different.*convention|my.*approach|my.*style|i prefer|i like to|i usually|i typically|inconsistent.*but|doesn't follow.*but|breaks.*pattern.*but|exception to|special case|one-time"
# More specific - discussing pattern problems, not proposing to ignore
IGNORE_ESC="the problem|there's.*issue|this is.*bug|this is broken|this is wrong|should fix|need to fix|should refactor"

check_and_block "Ignore Patterns" "$IGNORE_P" "$IGNORE_ESC" \
    "PATTERN BLOCKED: Follow existing codebase patterns. No personal preferences." \
    "IGNORE_PATTERNS"

# INCOMPLETE ANALYSIS
INCOMP_A_P="haven't.*considered|haven't.*thought|didn't.*consider|didn't.*think|not sure.*implications|not sure.*impact|not sure.*affect|don't know.*implications|don't know.*impact|unclear.*implications|unclear.*impact|need to.*investigate|need to.*look into|need to.*check|should.*investigate|should.*look into|would need to.*check|might.*affect|might.*impact|might.*break|could.*affect|could.*impact|could.*break|not fully.*understand|don't fully.*understand|not entirely.*sure|not completely.*sure|partial.*understanding|limited.*understanding"
INCOMP_A_ESC="let me.*check|let me.*investigate|i'll.*search|searching|reading|looking at"

check_and_block "Incomplete Analysis" "$INCOMP_A_P" "$INCOMP_A_ESC" \
    "INCOMPLETE BLOCKED: Investigate FIRST, then recommend. Never act on partial knowledge." \
    "INCOMPLETE_ANALYSIS"

# SCOPE CREEP
SCOPE_P="while.*at it|while i'm.*here|while we're.*here|might as well|also.*add|also.*include|also.*implement|bonus|extra|additionally.*add|additionally.*implement|throw in|sneak in|future.*proof|future-proof|in case.*need|in case.*want|just in case|might.*need.*later|might.*want.*later|could.*need.*later|could.*want.*later|anticipat|prepare for|account for.*future|abstract.*for|generalize.*for|make.*generic|make.*reusable|more flexible|more extensible|more configurable|add.*configuration|add.*option|add.*flag|add.*parameter"
SCOPE_ESC="you asked|you requested|you said|as requested|per your|your request"

check_and_block "Scope Creep" "$SCOPE_P" "$SCOPE_ESC" \
    "SCOPE CREEP BLOCKED: Do ONLY what was asked. No unrequested features or gold-plating." \
    "SCOPE_CREEP"

# NOT VERIFYING
# Note: "done" changed to word boundary \bdone\b to avoid matching "undone"
NOTVER_P="that should|this should|should now|should be.*fixed|should be.*working|should be.*resolved|should work now|try.*now|try that|try it|give.*try|see if.*works|let me know if|let me know.*works|hopefully.*works|hopefully.*fixed|\bdone\b|finished|completed|all set|good to go|ready to"
NOTVER_ESC="verified|confirmed|tested|test pass|output shows|result shows|works correctly|successfully|no errors"

check_and_block "Not Verifying" "$NOTVER_P" "$NOTVER_ESC" \
    "NOT VERIFIED BLOCKED: Do NOT assume changes worked. VERIFY by testing or checking output." \
    "NOT_VERIFYING"

# IGNORING ERRORS
IGERR_P="ignore.*error|ignore.*warning|ignoring.*error|ignoring.*warning|can ignore|safe to ignore|not important|not critical|doesn't matter|don't worry|don't concern|not a problem|not an issue|minor.*error|minor.*warning|minor.*issue|despite.*error|despite.*warning|even though.*error|even though.*failed|anyway|regardless|moving on|continue anyway|proceed anyway|not sure why|don't know why|unclear why|strange error|weird error|odd error"
# More specific escape - require explanation pattern, not just connector words
IGERR_ESC="this.*because|error.*because|warning.*because|this is expected|expected behavior|expected error|known issue|false positive|intentional"

check_and_block "Ignoring Errors" "$IGERR_P" "$IGERR_ESC" \
    "IGNORING ERRORS BLOCKED: Every error must be understood. INVESTIGATE, don't dismiss." \
    "IGNORING_ERRORS"

# INCOMPLETE REQUESTS
# Note: "remaining" alone was too broad - catches "remaining work items are documented"
INCOMP_R_P="for now.*just|start with|started with|beginning with|first.*then|first part|part one|step one|phase one|remaining.*to do|remaining.*todo|remaining.*tasks|remaining.*steps|rest of.*later|other.*later|others.*later|others.*next|next.*will|then.*will|after that.*will|following that|subsequently|partial.*complete|partially.*done|some of the.*cases|some of the.*work|some of.*will|most of.*done|majority of|haven't.*all|not.*all of|still need.*to"
INCOMP_R_ESC="you asked|you said|as you requested|shall i continue|want me to continue|should i proceed|documented|issue tracker|tracked"

check_and_block "Incomplete Request" "$INCOMP_R_P" "$INCOMP_R_ESC" \
    "INCOMPLETE BLOCKED: Complete ALL parts of what was asked. No partial work." \
    "INCOMPLETE_REQUEST"

# NOT CHECKING EXISTING
NOTCHK_P="create.*new|creating.*new|write.*new|writing.*new|add.*new|adding.*new|implement.*new|implementing.*new|build.*new|building.*new|new.*function|new.*class|new.*method|new.*component|new.*module|new.*service|new.*utility|new.*helper"
NOTCHK_ESC="searched|checked|looked for|no existing|nothing similar|doesn't exist|does not exist|couldn't find|could not find|grep|glob"

check_and_block "Not Checking Existing" "$NOTCHK_P" "$NOTCHK_ESC" \
    "NOT CHECKED BLOCKED: SEARCH for existing code before creating new. Don't reinvent." \
    "NOT_CHECKING_EXISTING"

# APOLOGIES/VALIDATION
# Note: "definitely", "certainly", "absolutely", "of course" removed - too many false positives in technical context
APOL_P="i apologize|i'm sorry|sorry for|sorry about|my apologies|apologies for|forgive me|my mistake|my bad|i was wrong|great question|good question|excellent question|that's a great|that's a good|you're absolutely right|you're right|you make a great point|you make a good point|if you don't mind|if that's okay|if that's alright|would it be okay|is it okay if|i hope that"

check_and_block "Apology/Validation" "$APOL_P" "" \
    "APOLOGY BLOCKED: No apologies, no sycophancy. Just answer directly." \
    "APOLOGY_VALIDATION"

# UNEXPLAINED CHANGES
UNEXP_P="changed.*to|changing.*to|switched.*to|switching.*to|replaced.*with|replacing.*with|modified.*to|updated.*to|converted.*to|moved.*to|renamed.*to|refactored.*to|instead.*now|now.*instead|different.*approach|different.*direction|new.*approach|new.*direction|going.*different|taking.*different"
UNEXP_ESC="because|since|due to|reason|this is better|this fixes|this resolves|this addresses|the problem was|the issue was"

check_and_block "Unexplained Changes" "$UNEXP_P" "$UNEXP_ESC" \
    "UNEXPLAINED BLOCKED: When changing decisions, EXPLAIN WHY the new approach is better." \
    "UNEXPLAINED_CHANGES"

# SECURITY
SECURITY_P="hardcoded.*password|hardcoded.*secret|hardcoded.*token|hardcoded.*key|password.*hardcoded|secret.*hardcoded|token.*hardcoded|key.*hardcoded|password.*=.*['\"]|api.key.*=.*['\"]|secret.*=.*['\"]|token.*=.*['\"]|eval\(|exec\(|shell.*=.*true|innerhtml|dangerouslysetinnerhtml|unsanitized|unescaped|user input.*directly|directly.*user input|no.*validation|without.*validation|skip.*validation|trust.*input|sql.*\+|sql.*concat|string.*interpolation.*query|f-string.*query|format.*query|\.format\(.*query|inject|injection|xss|cross.site|csrf|command.*injection|path.*traversal|\.\.\/|%2e%2e|unencrypted|plaintext.*password|plaintext.*secret|base64.*secret|exposed.*credential|leaked.*secret|commit.*secret|push.*secret"
SECURITY_ESC="vulnerability|security review|security audit|penetration test|found.*vulnerability|reporting|identified|cve-|owasp|fix.*injection|prevent.*injection|sanitize|escape|validate"

check_and_block "Security" "$SECURITY_P" "$SECURITY_ESC" \
    "SECURITY BLOCKED: Never hardcode secrets, always validate input, prevent injection attacks." \
    "SECURITY"

# RESOURCE CLEANUP
RESOURCE_P="no.*close|don't.*close|doesn't.*close|forgot.*close|never.*close|without.*closing|leak|leaking|leaked|open.*connection.*forever|connection.*open.*indefinitely|open.*handle|open.*file.*indefinitely|never.*released|not.*released|won't.*release|holding.*lock|keep.*lock|lock.*indefinitely|persistent.*connection.*without|background.*thread.*without.*cleanup|spawned.*process.*without|child.*process.*without|socket.*open|file.*descriptor|fd.*leak|memory.*leak|goroutine.*leak|thread.*leak|no.*finally|no.*defer|no.*cleanup|missing.*cleanup|forgot.*cleanup"
RESOURCE_ESC="investigating.*leak|found.*leak|memory.*issue|resource.*issue|fix.*leak|prevent.*leak|ensure.*close|add.*cleanup|need.*cleanup|is a bug|this is.*bug|that's a bug"

check_and_block "Resource Cleanup" "$RESOURCE_P" "$RESOURCE_ESC" \
    "RESOURCE BLOCKED: All resources (connections, handles, locks) must have cleanup. Use defer/finally/context managers." \
    "RESOURCE_CLEANUP"

# BREAKING CHANGES
BREAKING_P="breaking.*change|backward.*incompatible|backwards.*incompatible|remove.*parameter|delete.*parameter|change.*return.*type|change.*signature|change.*contract|rename.*endpoint|remove.*endpoint|delete.*endpoint|remove.*field|delete.*field|rename.*field|change.*schema|alter.*api|modify.*interface|change.*interface|deprecate.*without|drop.*support|remove.*support|no longer.*support|won't.*support|incompatible.*with.*previous|incompatible.*with.*existing|existing.*clients.*break|existing.*users.*break|migration.*required"
BREAKING_ESC="version.*bump|major.*version|semver|migration.*plan|migration.*guide|deprecation.*notice|changelog|documented|announced|communicated"

check_and_block "Breaking Changes" "$BREAKING_P" "$BREAKING_ESC" \
    "BREAKING BLOCKED: Breaking changes require version bump, migration plan, and clear communication." \
    "BREAKING_CHANGES"

# DEPENDENCY ADDITIONS
DEPEND_P="add.*dependency|adding.*dependency|new.*dependency|install.*package|npm.*install|yarn.*add|pip.*install|pip3.*install|go.*get|cargo.*add|composer.*require|gem.*install|nuget.*install|maven.*dependency|gradle.*dependency|add.*to.*requirements|add.*to.*package\.json|add.*to.*go\.mod|add.*to.*cargo\.toml|import.*new.*package|require.*new.*module|pulls.*in|brings.*in.*dependency|need.*to.*install|have.*to.*install"
DEPEND_ESC="you.*asked|you.*requested|necessary.*for|required.*for|no.*alternative|evaluated.*alternative|compared|considered|the.*only.*way|standard.*library.*doesn't|native.*doesn't.*support|existing.*dependency"

check_and_block "Dependency Additions" "$DEPEND_P" "$DEPEND_ESC" \
    "DEPENDENCY BLOCKED: Do NOT add dependencies without justification. Prefer standard library. Evaluate alternatives." \
    "DEPENDENCY_ADDITIONS"

# RAG-FIRST - Must search RAG before filesystem searches for non-specific queries
# Catches: Using glob/grep to search for information that RAG likely has
# Exception: Specific file paths, class definitions, or code patterns
RAG_FIRST_P="let me.*glob|let me.*grep|using glob|using grep|i'll search.*files|searching.*filesystem|looking in.*directory|let me find|let me look for|searching for.*files|searching through.*code|let me check.*files|globbing for|grepping for"
# Escape: Already searched RAG, or looking for specific file/class/pattern
RAG_FIRST_ESC="mcp__rag|search_docs|search_learnings|search_decisions|get_session_context|get_project_context|rag.*search|searched rag|rag showed|specific file|class definition|function definition|\.py$|\.ts$|\.go$|\.rs$|line [0-9]"

check_and_block "RAG-First" "$RAG_FIRST_P" "$RAG_FIRST_ESC" \
    "RAG-FIRST BLOCKED: Search RAG FIRST before filesystem searches. RAG has indexed documentation, decisions, and learnings." \
    "RAG_FIRST"

# INFRASTRUCTURE SUGGESTION - Suggesting infrastructure actions without RAG verification
# Catches: ANY suggestion to check/look at/investigate infrastructure
# Also catches: Questions to user about infrastructure that should be in RAG
# This blocks SUGGESTIONS AND LAZY QUESTIONS, not just commands
INFRA_SUGGEST_P="let me check.*cluster|let me check.*database|let me check.*ceph|let me check.*server|let me check.*status|let me check.*health|let me check.*pod|let me check.*node|let me look at.*health|let me look at.*status|let me look at.*logs|let me verify.*status|let me verify.*health|i'll check.*cluster|i'll check.*database|i'll check.*ceph|i'll check.*server|i'll check.*pods|i'll check.*nodes|let's look at.*status|let's look at.*health|let's look at.*cluster|let's check.*health|let's check.*status|should we check.*cluster|should we check.*database|should i check.*logs|should i check.*status|i can check.*cluster|i can check.*database|i can check.*logs|checking.*cluster.*health|checking.*database.*status|investigating.*cluster|investigating.*server|examining.*ceph|examining.*database|want me to check.*cluster|want me to check.*database|want me to look at|first.*check.*cluster|first.*check.*database|first.*check.*status|start by checking|start by looking at.*logs|do you use this.*domain|do you use this.*cluster|do you use this.*server|do you use this.*database|do you use this.*service|do you use.*ad domain|do you still use|is this.*still in use|are you using this|is this service.*used|is this.*needed|do you need this.*running"
# Escape: Must show RAG was searched in THIS response BEFORE the suggestion
INFRA_SUGGEST_ESC="mcp__rag__search|search_docs.*showed|search_learnings.*showed|search_decisions.*showed|rag.*shows|from rag|per rag|rag indicates|rag confirms|rag says|checked rag|searched rag|rag search.*returned"

check_and_block "Infrastructure Suggestion" "$INFRA_SUGGEST_P" "$INFRA_SUGGEST_ESC" \
    "INFRASTRUCTURE QUESTION/SUGGESTION BLOCKED: You asked user about or suggested checking infrastructure WITHOUT searching RAG first. RAG has this information - search it BEFORE asking the user or suggesting actions." \
    "INFRA_SUGGESTION"

# PROJECT_KNOWLEDGE - Explaining what a known system/project IS without RAG verification
# Catches: Confident explanations of project purpose/function without RAG evidence
# Known projects: empire systems, coldforge infra, personal tools
PROJECT_KNOW_P="elation is a|elation is an|elation is the|elation provides|elation handles|salesforce is a|salesforce is an|salesforce provides|snowflake is a|snowflake is an|snowflake provides|cloistr is a|cloistr is an|cloistr provides|servarr is a|servarr is an|servarr provides|kafka is a|kafka is an|kafka provides|ceph is a|ceph is an|ceph provides|openstack is a|openstack is an|openstack provides|atlas is a|atlas is an|atlas provides|argocd is a|argocd is an|argocd provides|thunderhub is a|thunderhub is an|thunderhub provides|lnd is a|lnd is an|lnd provides|actifai is a|actifai is an|actifai provides|the elation|the salesforce|the snowflake|the cloistr|the servarr system|the kafka|the ceph|the openstack|the atlas system|the argocd"
# Escape: RAG search evidence
PROJECT_KNOW_ESC="mcp__rag__search|search_docs|search_learnings|search_decisions|rag.*showed|rag.*shows|from rag|per rag|rag confirms|checked rag|searched rag|claude\.md.*says|per.*claude\.md"

check_and_block "Project Knowledge" "$PROJECT_KNOW_P" "$PROJECT_KNOW_ESC" \
    "PROJECT KNOWLEDGE BLOCKED: You explained what a system/project IS without searching RAG first. Check RAG or CLAUDE.md before explaining what systems do." \
    "PROJECT_KNOWLEDGE"

# UNVERIFIED TARGET - Running commands against ANY infrastructure without verification
# Catches: ALL infrastructure commands - k8s clusters, databases, VMs, cloud platforms, services
# TWO K8S CLUSTERS: atlantis, pantheon
# DATABASES: standalone and k8s-clustered postgres, redis, etc.
# VMs: ssh to any VM
# CLOUD: openstack, ceph commands
# SERVICES: curl/wget to endpoints, nginx, proxies
UNVERIFIED_P="oc-atlantis|oc-pantheon|kubectl|oc exec|oc get|oc describe|oc logs|psql|mysql|redis-cli|mongo|ssh .*@|openstack |ceph |rbd |rados |curl .*localhost|curl .*\.svc\.|curl .*\.xyz|curl .*\.local|wget .*localhost|wget .*\.svc\.|wget .*\.xyz|nginx|systemctl.*start|systemctl.*stop|systemctl.*restart|ansible-playbook|ansible .*-m|docker exec|podman exec|helm |argocd |let me query|checking.*database|querying|ran.*against|executed.*on|connected to|connecting to"
# Escape requires SPECIFIC verification showing target matches RAG results
# Must show: RAG result content that confirms the specific target being accessed
# Generic mentions of "health_check" or "search_docs" are NOT enough
UNVERIFIED_ESC="rag.*showed.*this|search.*confirmed|verified.*matches|documentation shows.*this|per the docs.*this|ragdb@postgres-rw\.db\.aegis|health_check.*showed.*132k|get_indexed_stats.*showed|the correct database is|verified the target|confirmed this is the right|matches what rag showed"

check_and_block "Unverified Target" "$UNVERIFIED_P" "$UNVERIFIED_ESC" \
    "UNVERIFIED TARGET BLOCKED: You ran infrastructure commands without showing the target matches RAG results. Show SPECIFIC evidence that RAG confirmed THIS is the correct target." \
    "UNVERIFIED_TARGET"

# DEPLOYMENT WITHOUT VERIFICATION - Claiming deployment success without agent verification
# Catches: Completion claims about deployments/sites without site-tester evidence
# This is the specific enforcement for "agents exist but don't get used"
DEPLOY_UNVERIFIED_P="deployment.*complete|deployed.*successfully|successfully deployed|is now working|is now live|site is.*working|site is.*live|site is.*up|application.*deployed|app.*deployed|service.*deployed|verified.*working|confirmed.*working|the deployment|deployment is.*done|deployment.*finished|up and running|live now|now live|works correctly|working correctly|page.*loads|loads correctly|ui.*working|frontend.*working|backend.*working"
# Escape: Evidence of ACTUAL verification via site-tester, ui-tester, or equivalent agent
# STRICT: Must show agent invocation (Task tool call) or actual test output
# REMOVED: http.*200, status.*200, test.*results, test.*passed - too easy to claim without doing
DEPLOY_UNVERIFIED_ESC="subagent_type.*site-tester|subagent_type.*ui-tester|subagent_type.*playwright|subagent_type.*api-tester|subagent_type.*component-tester|site-tester.*agent|ui-tester.*agent|screenshot.*saved.*png|screenshot.*saved.*jpg|playwright.*test.*output|npx playwright test|PASS.*site-tester|Result:.*screenshot|browser-test-runner"

check_and_block "Deployment Without Verification" "$DEPLOY_UNVERIFIED_P" "$DEPLOY_UNVERIFIED_ESC" \
    "DEPLOYMENT WITHOUT VERIFICATION BLOCKED: You claimed deployment success without using site-tester, ui-tester, or equivalent verification agent. Use a testing agent BEFORE claiming it works." \
    "DEPLOYMENT_WITHOUT_VERIFICATION"

# ABSOLUTE PATHS - Must use ~/ when showing paths to user
# Catches: /home/forgemaster/ in text output (tool calls excluded by design)
# User explicitly requested ~/relative paths always
ABSPATH_P="/home/forgemaster/"
# No escape - this is a hard rule for display output
ABSPATH_ESC=""

check_and_block "Absolute Path" "$ABSPATH_P" "$ABSPATH_ESC" \
    "ABSOLUTE PATH BLOCKED: Use ~/relative paths when showing paths to user, not /home/forgemaster/." \
    "ABSOLUTE_PATH"

# =============================================================================
# RAG LOGGING CHECK - Must log significant actions
# =============================================================================

# Check if Memory enforcement is disabled
MEMORY_MODE=$(get_category_mode "MEMORY")
[[ "$MEMORY_MODE" == "disabled" ]] && exit 0

RAG_LOGGED=0
if echo "$RESPONSE" | grep -qiE 'mcp__rag__log_(decision|learning)|logged.*successfully|Learning logged|Decision logged'; then
    RAG_LOGGED=1
    sed -i 's/rag_logged=.*/rag_logged=1/' "$SESSION_STATE" 2>/dev/null || true
fi

# More specific patterns to avoid false positives on explanatory text
# Focus on actions I performed, not discussions
SIGNIFICANT_P="i fixed|i resolved|i solved|i corrected|i repaired|i patched|i've fixed|i've resolved|i've patched|updated the config|changed the setting|modified the configuration|edited.*\.json|edited.*\.yaml|edited.*\.yml|i decided to|i chose|we decided to|we chose|went with.*because|i selected|design decision.*made|architecture.*decision|i discovered|i found.*issue|i found the|the root cause is|the problem was|i realized|i learned that|new process.*created|new workflow|new procedure|from now on we|going forward we|created.*hook|i implemented|i built|i wrote|added.*feature"

if echo "$RESPONSE_LOWER" | grep -qE "$SIGNIFICANT_P"; then
    source "$SESSION_STATE" 2>/dev/null || rag_logged=0

    if [[ "${rag_logged:-0}" -eq 0 ]] && [[ $RAG_LOGGED -eq 0 ]]; then
        if [[ "$MEMORY_MODE" == "warn" ]]; then
            # Warn only mode
            log_metric "warned" "Memory" "significant_action_no_log"
            echo "[$(date -Iseconds)] WARNING: Significant action without RAG logging" >> "$LOG_FILE"
            echo "<system-reminder>WARNING: You performed a significant action but did NOT log it to RAG. Consider using mcp__rag__log_decision or mcp__rag__log_learning.</system-reminder>"
        else
            # Block mode (default)
            log_metric "blocked" "Memory" "significant_action_no_log"
            echo "[$(date -Iseconds)] BLOCKED: Significant action without RAG logging" >> "$LOG_FILE"
            cat << EOF
{"decision": "block", "reason": "MEMORY FAILURE: You performed a significant action but did NOT log it to RAG. Use mcp__rag__log_decision or mcp__rag__log_learning NOW."}
EOF
            exit 0
        fi
    fi
fi

# =============================================================================
# WORKFLOW WARNINGS (non-blocking)
# =============================================================================

if echo "$RESPONSE_LOWER" | grep -qiE "implement.*feature|adding.*feature|new feature|building.*feature"; then
    if ! echo "$RESPONSE_LOWER" | grep -qiE "workflow|/skill|implement-feature|plan.*mode|exploration|council"; then
        echo "<system-reminder>WARNING: Feature without workflow. Consider /skill implement-feature</system-reminder>"
    fi
fi

if echo "$RESPONSE_LOWER" | grep -qiE "fix.*bug|fixing.*issue|debug|troubleshoot"; then
    if ! echo "$RESPONSE_LOWER" | grep -qiE "workflow|/skill|fix-bug|debugger|root cause analysis"; then
        echo "<system-reminder>WARNING: Bug fix without workflow. Consider /skill fix-bug</system-reminder>"
    fi
fi

# Reset circuit breaker on successful response
rm -f "$STATE_DIR/${SESSION_ID}.qe_block_count" 2>/dev/null || true

exit 0
