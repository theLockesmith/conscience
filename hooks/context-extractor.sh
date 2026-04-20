#!/bin/bash
# Context Extractor - Preservation of decisions and learnings before compaction
# Hook: Stop
#
# Extracts decisions and learnings from Claude's responses and stores them
# in PostgreSQL for cross-session memory.
#
# IMPORTANT: Only runs when context usage is HIGH (>70%) to avoid token waste.
# Checks transcript file size directly (same logic as MCP get_context_usage tool).

set -uo pipefail

# Debug: log that hook was called
echo "[$(date -Iseconds)] Hook invoked" >> /tmp/context-extractor.log

# Configuration
OLLAMA_URL="${OLLAMA_URL:-http://10.0.4.10:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:7b}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

# Context thresholds
MIN_USAGE_PERCENT=70  # Only run extraction above this threshold
MAX_TOKENS=200000
CHARS_PER_TOKEN=5     # Rough estimate for JSON transcript

# Skip if no password configured
if [[ -z "$POSTGRES_PASSWORD" ]]; then
    # Try to read from MCP config
    MCP_CONFIG="$HOME/claude/personal/localhost/.mcp.json"
    if [[ -f "$MCP_CONFIG" ]]; then
        POSTGRES_PASSWORD=$(jq -r '.mcpServers.rag.env.POSTGRES_PASSWORD // empty' "$MCP_CONFIG" 2>/dev/null)
    fi
fi

if [[ -z "$POSTGRES_PASSWORD" ]]; then
    exit 0  # Silent exit if no credentials
fi

# ============================================================================
# CHECK CONTEXT USAGE - Only proceed if above threshold
# ============================================================================

# Find current session transcript (most recent .jsonl that's not an agent)
CLAUDE_PROJECTS="$HOME/.claude/projects"
PROJECT_DIR=""

# Derive project dir from PWD - convert /home/forgemaster/foo to -home-forgemaster-foo
if [[ -n "$PWD" ]]; then
    PROJECT_DIR_NAME=$(echo "$PWD" | sed 's|^/||; s|/|-|g')
    PROJECT_DIR="$CLAUDE_PROJECTS/-$PROJECT_DIR_NAME"
fi

# Fallback: find most recently modified directory (may be wrong but better than nothing)
if [[ -z "$PROJECT_DIR" ]] || [[ ! -d "$PROJECT_DIR" ]]; then
    PROJECT_DIR=$(find "$CLAUDE_PROJECTS" -maxdepth 1 -type d -name "-home-forgemaster-*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
fi
echo "[$(date -Iseconds)] DEBUG: PROJECT_DIR=$PROJECT_DIR (PWD=$PWD)" >> /tmp/context-extractor.log

if [[ -z "$PROJECT_DIR" ]] || [[ ! -d "$PROJECT_DIR" ]]; then
    echo "[$(date -Iseconds)] No project dir found, tried: $CLAUDE_PROJECTS/-home-forgemaster-*" >> /tmp/context-extractor.log
    exit 0  # Can't find project dir, skip silently
fi

# Find most recent non-agent session file
CURRENT_SESSION=$(find "$PROJECT_DIR" -maxdepth 1 -name "*.jsonl" ! -name "agent-*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

if [[ -z "$CURRENT_SESSION" ]] || [[ ! -f "$CURRENT_SESSION" ]]; then
    exit 0  # No session file, skip
fi

# Calculate context usage percentage
FILE_SIZE=$(stat -c%s "$CURRENT_SESSION" 2>/dev/null || echo "0")
ESTIMATED_TOKENS=$((FILE_SIZE / CHARS_PER_TOKEN))
CONTEXT_PERCENT=$((ESTIMATED_TOKENS * 100 / MAX_TOKENS))

# Only run if above threshold
if [[ $CONTEXT_PERCENT -lt $MIN_USAGE_PERCENT ]]; then
    echo "[$(date -Iseconds)] Skipped: context at ${CONTEXT_PERCENT}% (threshold: ${MIN_USAGE_PERCENT}%)" >> /tmp/context-extractor.log
    exit 0  # Below threshold, skip extraction
fi

echo "[$(date -Iseconds)] Running extraction: context at ${CONTEXT_PERCENT}%" >> /tmp/context-extractor.log

# ============================================================================
# EXTRACTION LOGIC - Only reached if context usage > 70%
# ============================================================================

# Read input from stdin
INPUT=$(cat)
echo "[$(date -Iseconds)] Input keys: $(echo "$INPUT" | jq -r 'keys | join(",")' 2>/dev/null)" >> /tmp/context-extractor.log
RESPONSE=$(echo "$INPUT" | jq -r '.response // empty' 2>/dev/null)

# Skip if no response or response too short (< 500 chars for high-value extraction)
if [[ -z "$RESPONSE" ]]; then
    echo "[$(date -Iseconds)] Skipped: no response in input" >> /tmp/context-extractor.log
    exit 0
fi
if [[ ${#RESPONSE} -lt 500 ]]; then
    echo "[$(date -Iseconds)] Skipped: response too short (${#RESPONSE} chars)" >> /tmp/context-extractor.log
    exit 0
fi

# Skip if response is just code without explanation
if echo "$RESPONSE" | grep -qE '^```' && ! echo "$RESPONSE" | grep -qiE '(decided|chose|because|reason|learned|discovered|found that|realized|important|note that|architecture|design|approach)'; then
    echo "[$(date -Iseconds)] Skipped: code-only response" >> /tmp/context-extractor.log
    exit 0
fi

# Truncate very long responses for analysis
RESPONSE_TRUNCATED="${RESPONSE:0:8000}"

# Create extraction prompt
EXTRACTION_PROMPT=$(cat << 'PROMPT_END'
Analyze this assistant response and extract any significant decisions or learnings that should be preserved for future sessions.

IMPORTANT: Only extract items that are:
- Architectural decisions (chose X over Y because...)
- Technical learnings (discovered that X requires Y)
- User preferences discovered (user prefers X style)
- Gotchas or pitfalls encountered (X doesn't work because Y)
- Important patterns established (always do X before Y)

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

Response to analyze:
PROMPT_END
)

# Call Ollama for extraction (60s timeout - model loading can take 20s+)
OLLAMA_RESPONSE=$(curl -s --max-time 60 "$OLLAMA_URL/api/generate" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$OLLAMA_MODEL" --arg prompt "$EXTRACTION_PROMPT

$RESPONSE_TRUNCATED" '{
        model: $model,
        prompt: $prompt,
        stream: false,
        options: {
            temperature: 0.1,
            num_predict: 1000
        }
    }')" 2>/dev/null)

if [[ -z "$OLLAMA_RESPONSE" ]]; then
    echo "[$(date -Iseconds)] Skipped: Ollama timeout or error" >> /tmp/context-extractor.log
    exit 0
fi

# Extract the response text
EXTRACTION=$(echo "$OLLAMA_RESPONSE" | jq -r '.response // empty' 2>/dev/null)

if [[ -z "$EXTRACTION" ]]; then
    echo "[$(date -Iseconds)] Skipped: no response field in Ollama output" >> /tmp/context-extractor.log
    exit 0
fi

echo "[$(date -Iseconds)] Ollama returned ${#EXTRACTION} chars" >> /tmp/context-extractor.log

# Try to parse JSON from response (handle markdown code blocks)
JSON_CONTENT=$(echo "$EXTRACTION" | sed -n '/```json/,/```/p' | sed '1d;$d')
if [[ -z "$JSON_CONTENT" ]]; then
    # Try without code blocks
    JSON_CONTENT=$(echo "$EXTRACTION" | grep -oP '\{[\s\S]*\}' | head -1)
fi

if [[ -z "$JSON_CONTENT" ]]; then
    echo "[$(date -Iseconds)] Skipped: no JSON found in LLM response" >> /tmp/context-extractor.log
    exit 0
fi

# Validate JSON
if ! echo "$JSON_CONTENT" | jq empty 2>/dev/null; then
    echo "[$(date -Iseconds)] Skipped: invalid JSON from LLM" >> /tmp/context-extractor.log
    exit 0
fi

# Check if there's anything to store
DECISION_COUNT=$(echo "$JSON_CONTENT" | jq '.decisions | length' 2>/dev/null || echo "0")
LEARNING_COUNT=$(echo "$JSON_CONTENT" | jq '.learnings | length' 2>/dev/null || echo "0")

if [[ "$DECISION_COUNT" == "0" ]] && [[ "$LEARNING_COUNT" == "0" ]]; then
    echo "[$(date -Iseconds)] Skipped: LLM found nothing to extract" >> /tmp/context-extractor.log
    exit 0
fi

# Store decisions
if [[ "$DECISION_COUNT" != "0" ]]; then
    echo "$JSON_CONTENT" | jq -c '.decisions[]' 2>/dev/null | while read -r decision; do
        summary=$(echo "$decision" | jq -r '.summary // empty')
        rationale=$(echo "$decision" | jq -r '.rationale // empty')
        project=$(echo "$decision" | jq -r '.project // empty')
        tags=$(echo "$decision" | jq -c '.tags // []')

        if [[ -n "$summary" ]]; then
            # Insert into decisions table
            PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
                -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q << SQL 2>/dev/null
INSERT INTO decisions (summary, rationale, project, tags, session_id)
VALUES (
    '$(echo "$summary" | sed "s/'/''/g")',
    '$(echo "$rationale" | sed "s/'/''/g")',
    $(if [[ -n "$project" && "$project" != "null" ]]; then echo "'$project'"; else echo "NULL"; fi),
    '${tags}'::text[],
    '$(echo "$CLAUDE_SESSION_ID" | head -c 50)'
)
ON CONFLICT DO NOTHING;
SQL
        fi
    done
fi

# Store learnings
if [[ "$LEARNING_COUNT" != "0" ]]; then
    echo "$JSON_CONTENT" | jq -c '.learnings[]' 2>/dev/null | while read -r learning; do
        content=$(echo "$learning" | jq -r '.content // empty')
        category=$(echo "$learning" | jq -r '.category // "insight"')
        context=$(echo "$learning" | jq -r '.context // empty')
        project=$(echo "$learning" | jq -r '.project // empty')
        tags=$(echo "$learning" | jq -c '.tags // []')

        if [[ -n "$content" ]]; then
            # Insert into learnings table
            PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
                -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q << SQL 2>/dev/null
INSERT INTO learnings (content, category, context, project, tags, source_session)
VALUES (
    '$(echo "$content" | sed "s/'/''/g")',
    '$category',
    '$(echo "$context" | sed "s/'/''/g")',
    $(if [[ -n "$project" && "$project" != "null" ]]; then echo "'$project'"; else echo "NULL"; fi),
    '${tags}'::text[],
    '$(echo "$CLAUDE_SESSION_ID" | head -c 50)'
)
ON CONFLICT DO NOTHING;
SQL
        fi
    done
fi

# Log extraction for debugging
echo "[$(date -Iseconds)] Extracted: $DECISION_COUNT decisions, $LEARNING_COUNT learnings (context: ${CONTEXT_PERCENT}%)" >> /tmp/context-extractor.log

exit 0
