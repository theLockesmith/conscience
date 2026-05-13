#!/bin/bash
# Session Memory Loader - Loads RAG context at session start
# Hook: SessionStart
#
# PURPOSE: Ensure Claude ALWAYS has access to relevant memory at session start.
#
# This hook:
# 1. Queries RAG for recent decisions related to current project
# 2. Queries RAG for learnings/gotchas related to current project
# 3. On RESUME: Also restores latest checkpoint (todos, key files, context)
# 4. Injects this context so Claude has memory from previous sessions
#
# CRITICAL: Without this, Claude will forget everything learned before.

set -uo pipefail

LOG_FILE="$HOME/.claude/session-memory.log"
STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

# Read input to detect session source (startup, resume, compact, clear)
INPUT=$(cat)
SESSION_SOURCE=$(echo "$INPUT" | jq -r '.source // empty' 2>/dev/null)

# Configuration - matches RAG server settings
POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
# Password from environment or fallback (same as coord-session-register.sh)
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-***REDACTED-cred-rotated-2026-05-13***}"

# Determine project from PWD
PROJECT_PATH="$PWD"
PROJECT_NAME=""

# Extract project name from path
if [[ "$PROJECT_PATH" == *"/claude/"* ]]; then
    PROJECT_NAME=$(echo "$PROJECT_PATH" | sed 's|.*/claude/||' | cut -d'/' -f2)
fi

# Fallback: use directory name
if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME=$(basename "$PROJECT_PATH")
fi

echo "[$(date -Iseconds)] Loading memory for project: $PROJECT_NAME (path: $PROJECT_PATH, source: ${SESSION_SOURCE:-unknown})" >> "$LOG_FILE"

# ============================================================================
# CHECKPOINT RESTORATION (For resume sessions)
# ============================================================================

CHECKPOINT_RESTORED=""
if [[ "$SESSION_SOURCE" == "resume" ]]; then
    # Query for the latest checkpoint for this project (within last 24 hours)
    CHECKPOINT=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A << SQL 2>/dev/null
SELECT json_build_object(
    'id', id,
    'session_id', session_id,
    'description', description,
    'todos', todos,
    'context_summary', context_summary,
    'key_files', key_files,
    'created_at', created_at
)
FROM session_checkpoints
WHERE (project = '$PROJECT_NAME' OR project IS NULL)
  AND created_at > NOW() - INTERVAL '24 hours'
ORDER BY created_at DESC
LIMIT 1;
SQL
)

    if [[ -n "$CHECKPOINT" && "$CHECKPOINT" != "null" && "$CHECKPOINT" != "" ]]; then
        CHECKPOINT_ID=$(echo "$CHECKPOINT" | jq -r '.id // empty')
        CHECKPOINT_TODOS=$(echo "$CHECKPOINT" | jq '.todos // []')
        CHECKPOINT_CONTEXT=$(echo "$CHECKPOINT" | jq -r '.context_summary // empty')
        CHECKPOINT_FILES=$(echo "$CHECKPOINT" | jq '.key_files // []')
        CHECKPOINT_TIME=$(echo "$CHECKPOINT" | jq -r '.created_at // empty')

        TODO_COUNT=$(echo "$CHECKPOINT_TODOS" | jq 'length' 2>/dev/null || echo "0")
        FILE_COUNT=$(echo "$CHECKPOINT_FILES" | jq 'length' 2>/dev/null || echo "0")

        if [[ "$TODO_COUNT" -gt 0 || -n "$CHECKPOINT_CONTEXT" ]]; then
            CHECKPOINT_RESTORED="yes"
            echo "[$(date -Iseconds)] Restoring checkpoint $CHECKPOINT_ID: $TODO_COUNT todos, $FILE_COUNT files" >> "$LOG_FILE"

            # Update checkpoint restore count
            PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
                -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q -c \
                "UPDATE session_checkpoints SET restored_at = NOW(), restore_count = restore_count + 1 WHERE id = '$CHECKPOINT_ID';" 2>/dev/null
        fi
    fi
fi

# ============================================================================
# QUERY RAG FOR RELEVANT CONTEXT
# ============================================================================

# Query recent decisions for this project (last 30 days)
# V10 OPTIMIZED: Limit 5 items, truncate rationale to 150 chars
DECISIONS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A << SQL 2>/dev/null
SELECT json_agg(json_build_object(
    'summary', summary,
    'rationale', LEFT(rationale, 150) || CASE WHEN LENGTH(rationale) > 150 THEN '...' ELSE '' END,
    'date', created_at::date
))
FROM (
    SELECT summary, rationale, created_at
    FROM decisions
    WHERE (project = '$PROJECT_NAME' OR project IS NULL)
      AND created_at > NOW() - INTERVAL '30 days'
    ORDER BY created_at DESC
    LIMIT 5
) sub;
SQL
)

# Query recent learnings for this project (last 30 days)
# V10 OPTIMIZED: Limit 5 items, truncate content to 200 chars
LEARNINGS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A << SQL 2>/dev/null
SELECT json_agg(json_build_object(
    'content', LEFT(content, 200) || CASE WHEN LENGTH(content) > 200 THEN '...' ELSE '' END,
    'category', category,
    'context', LEFT(context, 80)
))
FROM (
    SELECT content, category, context
    FROM learnings
    WHERE (project = '$PROJECT_NAME' OR project IS NULL)
      AND created_at > NOW() - INTERVAL '30 days'
    ORDER BY created_at DESC
    LIMIT 5
) sub;
SQL
)

# Query CRITICAL learnings (any time, category = 'gotcha' or has 'critical' tag)
# V10 OPTIMIZED: Limit 6 items, truncate content to 150 chars
CRITICAL=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A << SQL 2>/dev/null
SELECT json_agg(json_build_object(
    'content', LEFT(content, 150) || CASE WHEN LENGTH(content) > 150 THEN '...' ELSE '' END,
    'context', LEFT(context, 50)
))
FROM (
    SELECT DISTINCT content, context
    FROM learnings
    WHERE (project = '$PROJECT_NAME' OR project IS NULL)
      AND (category = 'gotcha' OR 'critical' = ANY(tags) OR 'mandatory' = ANY(tags))
    ORDER BY content
    LIMIT 6
) sub;
SQL
)

# ============================================================================
# BUILD CONTEXT INJECTION
# ============================================================================

# V10 OPTIMIZED: Minimal fixed text header
echo "<session-memory>"
echo "# Session Memory Context"
echo ""
echo "**Project:** $PROJECT_NAME"
echo "**Loaded at:** $(date -Iseconds)"
echo ""

# Output checkpoint restoration info first (most relevant for resume)
if [[ -n "$CHECKPOINT_RESTORED" ]]; then
    echo "## RESTORED SESSION STATE (from checkpoint $CHECKPOINT_ID)"
    echo ""
    echo "**Checkpoint created:** $CHECKPOINT_TIME"
    echo ""

    # Output todos
    if [[ "$TODO_COUNT" -gt 0 && "$TODO_COUNT" != "null" ]]; then
        echo "### Pending Tasks (from last session)"
        echo ""
        echo "$CHECKPOINT_TODOS" | jq -r '.[] | "- [\(.status)] \(.content)"' 2>/dev/null
        echo ""
    fi

    # Output context summary
    if [[ -n "$CHECKPOINT_CONTEXT" ]]; then
        echo "### Work In Progress"
        echo ""
        echo "$CHECKPOINT_CONTEXT"
        echo ""
    fi

    # Output key files
    if [[ "$FILE_COUNT" -gt 0 && "$FILE_COUNT" != "null" ]]; then
        echo "### Key Files Being Worked On"
        echo ""
        echo "$CHECKPOINT_FILES" | jq -r '.[]' 2>/dev/null | while read -r f; do
            echo "- \`$f\`"
        done
        echo ""
    fi
fi

# Count items
CRITICAL_COUNT=0
DECISION_COUNT=0
LEARNING_COUNT=0

# Add critical learnings first (most important)
if [[ -n "$CRITICAL" && "$CRITICAL" != "null" && "$CRITICAL" != "" ]]; then
    CRITICAL_COUNT=$(echo "$CRITICAL" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$CRITICAL_COUNT" -gt 0 && "$CRITICAL_COUNT" != "null" ]]; then
        echo "## CRITICAL RULES AND GOTCHAS (MUST FOLLOW)"
        echo ""
        # Use jq to format and output directly
        echo "$CRITICAL" | jq -r '.[] | "- **\(.content)**\n  _Context: \(.context // "Always applies")_"' 2>/dev/null
        echo ""
    fi
fi

# Add recent decisions
if [[ -n "$DECISIONS" && "$DECISIONS" != "null" && "$DECISIONS" != "" ]]; then
    DECISION_COUNT=$(echo "$DECISIONS" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$DECISION_COUNT" -gt 0 && "$DECISION_COUNT" != "null" ]]; then
        echo "## Recent Decisions (Last 30 Days)"
        echo ""
        echo "$DECISIONS" | jq -r '.[] | "- **\(.summary)** (\(.date))\n  _Rationale: \(.rationale)_"' 2>/dev/null
        echo ""
    fi
fi

# Add recent learnings
if [[ -n "$LEARNINGS" && "$LEARNINGS" != "null" && "$LEARNINGS" != "" ]]; then
    LEARNING_COUNT=$(echo "$LEARNINGS" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$LEARNING_COUNT" -gt 0 && "$LEARNING_COUNT" != "null" ]]; then
        echo "## Recent Learnings"
        echo ""
        echo "$LEARNINGS" | jq -r '.[] | "- [\(.category | ascii_upcase)] \(.content)\n  _Context: \(.context // "General")_"' 2>/dev/null
        echo ""
    fi
fi

# V10 OPTIMIZED: Compact mandatory reminder
echo "## MANDATORY: Memory Usage Requirements"
echo ""
echo "1. **LOG ALL DECISIONS**: Use \`mcp__rag__log_decision\` for any architectural choice, approach selection, or significant fix"
echo "2. **LOG ALL LEARNINGS**: Use \`mcp__rag__log_learning\` for gotchas, patterns, preferences, and insights discovered"
echo "3. **CHECK BEFORE ACTING**: Use \`mcp__rag__search_decisions\` and \`mcp__rag__search_learnings\` before making decisions"
echo "4. **NO DEFERRALS**: Never say 'I'll do it later' - do it NOW or explain why it cannot be done"
echo "5. **NO HALF-ASSING**: Complete every task fully. No placeholders, no stubs, no 'good enough'"
echo ""
echo "</session-memory>"

# Log what we loaded
echo "[$(date -Iseconds)] Loaded: ${CRITICAL_COUNT:-0} critical, ${DECISION_COUNT:-0} decisions, ${LEARNING_COUNT:-0} learnings" >> "$LOG_FILE"

# Initialize session state
SESSION_ID=$(echo "$PWD" | md5sum | cut -c1-16)
echo "rag_called=0" > "$STATE_DIR/${SESSION_ID}.state"
echo "session_start=$(date -Iseconds)" >> "$STATE_DIR/${SESSION_ID}.state"
echo "project=$PROJECT_NAME" >> "$STATE_DIR/${SESSION_ID}.state"

exit 0
