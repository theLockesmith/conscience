#!/bin/bash
# Pre-Compaction Extractor - Extracts decisions/learnings AND creates checkpoint before compaction
# Hook: PreCompact
#
# Unlike context-extractor.sh (Stop hook), this runs ONCE before compaction and:
# 1. Creates a session checkpoint (todos, key files, context) for recovery
# 2. Extracts decisions/learnings from the session transcript
#
# The checkpoint enables restoring session state after compaction via restore_checkpoint MCP tool.

set -uo pipefail

LOG_FILE="/tmp/pre-compaction-extractor.log"
echo "[$(date -Iseconds)] PreCompact hook invoked" >> "$LOG_FILE"

# Configuration - LocalAI for LLM, Ollama for embeddings
LOCALAI_URL="${LOCALAI_URL:-http://10.0.4.10:8000}"
LOCALAI_MODEL="${LOCALAI_MODEL:-qwen2.5-coder-7b}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
# Password from environment or fallback (same as coord-session-register.sh)
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD env var required}"

# Read input from stdin (PreCompact provides trigger and custom_instructions)
INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

echo "[$(date -Iseconds)] Trigger: $TRIGGER, Transcript: $TRANSCRIPT_PATH" >> "$LOG_FILE"

if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
    echo "[$(date -Iseconds)] No transcript file found" >> "$LOG_FILE"
    exit 0
fi

# ============================================================================
# PHASE 1: Create Session Checkpoint (via unified script)
# ============================================================================

# Extract session_id from input or transcript filename
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
fi

echo "[$(date -Iseconds)] Creating pre-compaction checkpoint for session: $SESSION_ID" >> "$LOG_FILE"

# Use unified checkpoint script (extracts todos, key files, context from transcript)
CHECKPOINT_ID=$("$HOME/.claude/scripts/unified-checkpoint.sh" \
    --transcript "$TRANSCRIPT_PATH" \
    --session-id "$SESSION_ID" \
    --description "Pre-compaction checkpoint" \
    --trigger "precompact" \
    2>/dev/null)

if [[ -n "$CHECKPOINT_ID" && "$CHECKPOINT_ID" =~ ^[0-9a-f-]{36}$ ]]; then
    echo "[$(date -Iseconds)] Checkpoint created: $CHECKPOINT_ID" >> "$LOG_FILE"
else
    echo "[$(date -Iseconds)] Checkpoint creation failed or skipped" >> "$LOG_FILE"
fi

# ============================================================================
# PHASE 2: Extract Decisions and Learnings (existing logic)
# ============================================================================

# Extract assistant messages from transcript (last 50 to keep prompt manageable)
# The transcript is JSONL format with message objects
ASSISTANT_MESSAGES=$(tail -500 "$TRANSCRIPT_PATH" | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null | tail -c 15000)

if [[ -z "$ASSISTANT_MESSAGES" ]] || [[ ${#ASSISTANT_MESSAGES} -lt 500 ]]; then
    echo "[$(date -Iseconds)] Not enough assistant content to extract (${#ASSISTANT_MESSAGES} chars)" >> "$LOG_FILE"
    exit 0
fi

echo "[$(date -Iseconds)] Extracting from ${#ASSISTANT_MESSAGES} chars of assistant messages" >> "$LOG_FILE"

# Create extraction prompt
EXTRACTION_PROMPT=$(cat << 'PROMPT_END'
Analyze this session transcript and extract significant decisions and learnings that should be preserved.

IMPORTANT: Only extract items that are:
- Architectural decisions (chose X over Y because...)
- Technical learnings (discovered that X requires Y)
- User preferences discovered (user prefers X style)
- Gotchas or pitfalls encountered (X doesn't work because Y)
- Important patterns established (always do X before Y)
- Bug discoveries or workarounds found

DO NOT extract:
- Routine code changes
- Simple explanations
- Status updates
- Task completions without insight

Return JSON in this exact format (empty arrays if nothing significant):
{
  "decisions": [
    {
      "summary": "Brief description of decision",
      "rationale": "Why this was decided",
      "project": "project_name or null if global",
      "tags": ["tag1", "tag2"]
    }
  ],
  "learnings": [
    {
      "content": "The learning or insight",
      "category": "pattern|gotcha|preference|architecture|insight",
      "context": "When/where this applies",
      "project": "project_name or null if global",
      "tags": ["tag1", "tag2"]
    }
  ]
}

Session transcript to analyze:
PROMPT_END
)

# Call LocalAI for extraction (120s timeout for larger extraction)
echo "[$(date -Iseconds)] Calling LocalAI..." >> "$LOG_FILE"
LOCALAI_RESPONSE=$(curl -s --max-time 120 "$LOCALAI_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$LOCALAI_MODEL" --arg prompt "$EXTRACTION_PROMPT

$ASSISTANT_MESSAGES" '{
        model: $model,
        messages: [{role: "user", content: $prompt}],
        temperature: 0.1,
        max_tokens: 2000
    }')" 2>&1)

CURL_EXIT=$?
echo "[$(date -Iseconds)] Curl exit code: $CURL_EXIT, response length: ${#LOCALAI_RESPONSE}" >> "$LOG_FILE"

if [[ -z "$LOCALAI_RESPONSE" ]]; then
    echo "[$(date -Iseconds)] LocalAI timeout or error" >> "$LOG_FILE"
    exit 0
fi

# Extract the response text (OpenAI format)
EXTRACTION=$(echo "$LOCALAI_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

if [[ -z "$EXTRACTION" ]]; then
    echo "[$(date -Iseconds)] No response from LocalAI" >> "$LOG_FILE"
    exit 0
fi

echo "[$(date -Iseconds)] LocalAI returned ${#EXTRACTION} chars" >> "$LOG_FILE"

# Try to parse JSON from response
JSON_CONTENT=$(echo "$EXTRACTION" | sed -n '/```json/,/```/p' | sed '1d;$d')
if [[ -z "$JSON_CONTENT" ]]; then
    JSON_CONTENT=$(echo "$EXTRACTION" | grep -oP '\{[\s\S]*\}' | head -1)
fi

if [[ -z "$JSON_CONTENT" ]]; then
    echo "[$(date -Iseconds)] No JSON found in LLM response" >> "$LOG_FILE"
    exit 0
fi

# Validate JSON
if ! echo "$JSON_CONTENT" | jq empty 2>/dev/null; then
    echo "[$(date -Iseconds)] Invalid JSON from LLM" >> "$LOG_FILE"
    exit 0
fi

# Check counts
DECISION_COUNT=$(echo "$JSON_CONTENT" | jq '.decisions | length' 2>/dev/null || echo "0")
LEARNING_COUNT=$(echo "$JSON_CONTENT" | jq '.learnings | length' 2>/dev/null || echo "0")

if [[ "$DECISION_COUNT" == "0" ]] && [[ "$LEARNING_COUNT" == "0" ]]; then
    echo "[$(date -Iseconds)] LLM found nothing to extract" >> "$LOG_FILE"
    exit 0
fi

# Store decisions
if [[ "$DECISION_COUNT" != "0" ]]; then
    SESSION_ID="precompact-$(date +%Y%m%d-%H%M%S)"
    echo "$JSON_CONTENT" | jq -c '.decisions[]' 2>/dev/null | while read -r decision; do
        summary=$(echo "$decision" | jq -r '.summary // empty')
        rationale=$(echo "$decision" | jq -r '.rationale // empty')
        project=$(echo "$decision" | jq -r '.project // empty')
        # Convert JSON array to PostgreSQL array format
        tags=$(echo "$decision" | jq -r '.tags // [] | "{" + (map("\"" + . + "\"") | join(",")) + "}"')

        if [[ -n "$summary" ]]; then
            SQL_RESULT=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
                -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
INSERT INTO decisions (summary, rationale, project, tags, session_id)
VALUES (
    '$(echo "$summary" | sed "s/'/''/g")',
    '$(echo "$rationale" | sed "s/'/''/g")',
    $(if [[ -n "$project" && "$project" != "null" ]]; then echo "'$project'"; else echo "NULL"; fi),
    '${tags}'::text[],
    '$SESSION_ID'
)
ON CONFLICT DO NOTHING;
" 2>&1)
            echo "[$(date -Iseconds)] Decision SQL result: $SQL_RESULT" >> "$LOG_FILE"
        fi
    done
fi

# Store learnings
if [[ "$LEARNING_COUNT" != "0" ]]; then
    SESSION_ID="precompact-$(date +%Y%m%d-%H%M%S)"
    echo "$JSON_CONTENT" | jq -c '.learnings[]' 2>/dev/null | while read -r learning; do
        content=$(echo "$learning" | jq -r '.content // empty')
        category=$(echo "$learning" | jq -r '.category // "insight"')
        lcontext=$(echo "$learning" | jq -r '.context // empty')
        project=$(echo "$learning" | jq -r '.project // empty')
        # Convert JSON array to PostgreSQL array format
        tags=$(echo "$learning" | jq -r '.tags // [] | "{" + (map("\"" + . + "\"") | join(",")) + "}"')

        if [[ -n "$content" ]]; then
            SQL_RESULT=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
                -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
INSERT INTO learnings (content, category, context, project, tags, source_session)
VALUES (
    '$(echo "$content" | sed "s/'/''/g")',
    '$category',
    '$(echo "$lcontext" | sed "s/'/''/g")',
    $(if [[ -n "$project" && "$project" != "null" ]]; then echo "'$project'"; else echo "NULL"; fi),
    '${tags}'::text[],
    '$SESSION_ID'
)
ON CONFLICT DO NOTHING;
" 2>&1)
            echo "[$(date -Iseconds)] Learning SQL result: $SQL_RESULT" >> "$LOG_FILE"
        fi
    done
fi

echo "[$(date -Iseconds)] PreCompact extracted: $DECISION_COUNT decisions, $LEARNING_COUNT learnings" >> "$LOG_FILE"

exit 0
