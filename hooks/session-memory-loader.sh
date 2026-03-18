#!/bin/bash
# Session Memory Loader - Loads RAG context at session start
# Hook: SessionStart
#
# PURPOSE: Ensure Claude ALWAYS has access to relevant memory at session start.
#
# This hook:
# 1. Queries RAG for recent decisions related to current project
# 2. Queries RAG for learnings/gotchas related to current project
# 3. Injects this context so Claude has memory from previous sessions
#
# CRITICAL: Without this, Claude will forget everything learned before.

set -uo pipefail

LOG_FILE="$HOME/.claude/session-memory.log"
STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

# Configuration - matches RAG server settings
POSTGRES_HOST="${POSTGRES_HOST:-10.51.1.20}"
POSTGRES_PORT="${POSTGRES_PORT:-30432}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

# Read password from environment or global config
if [[ -z "$POSTGRES_PASSWORD" ]]; then
    POSTGRES_PASSWORD=$(jq -r '.mcpServers.rag.env.POSTGRES_PASSWORD // empty' ~/.claude.json 2>/dev/null)
fi

if [[ -z "$POSTGRES_PASSWORD" ]]; then
    echo "[$(date -Iseconds)] No PostgreSQL password, skipping memory load" >> "$LOG_FILE"
    exit 0
fi

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

echo "[$(date -Iseconds)] Loading memory for project: $PROJECT_NAME (path: $PROJECT_PATH)" >> "$LOG_FILE"

# ============================================================================
# QUERY RAG FOR RELEVANT CONTEXT
# ============================================================================

# Query recent decisions for this project (last 30 days)
DECISIONS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A << SQL 2>/dev/null
SELECT json_agg(json_build_object(
    'summary', summary,
    'rationale', rationale,
    'date', created_at::date,
    'tags', tags
))
FROM (
    SELECT summary, rationale, created_at, tags
    FROM decisions
    WHERE (project = '$PROJECT_NAME' OR project IS NULL)
      AND created_at > NOW() - INTERVAL '30 days'
    ORDER BY created_at DESC
    LIMIT 10
) sub;
SQL
)

# Query recent learnings for this project (last 30 days)
LEARNINGS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A << SQL 2>/dev/null
SELECT json_agg(json_build_object(
    'content', content,
    'category', category,
    'context', context,
    'date', created_at::date
))
FROM (
    SELECT content, category, context, created_at
    FROM learnings
    WHERE (project = '$PROJECT_NAME' OR project IS NULL)
      AND created_at > NOW() - INTERVAL '30 days'
    ORDER BY created_at DESC
    LIMIT 15
) sub;
SQL
)

# Query CRITICAL learnings (any time, category = 'gotcha' or has 'critical' tag)
CRITICAL=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A << SQL 2>/dev/null
SELECT json_agg(json_build_object(
    'content', content,
    'context', context
))
FROM (
    SELECT DISTINCT content, context
    FROM learnings
    WHERE (project = '$PROJECT_NAME' OR project IS NULL)
      AND (category = 'gotcha' OR 'critical' = ANY(tags) OR 'mandatory' = ANY(tags))
    ORDER BY content
    LIMIT 10
) sub;
SQL
)

# ============================================================================
# BUILD CONTEXT INJECTION
# ============================================================================

# Start output
echo "<session-memory>"
echo "# FIRST: Report Health Status to User"
echo ""
echo "**BEFORE ANYTHING ELSE**: Your FIRST line of output MUST be the health status."
echo "Copy this exactly (adjust checkmarks based on SESSION HEALTH CHECK banner above):"
echo ""
echo '```'
echo 'Health: RAG✓ Ollama✓ Tribunal✓ MCP✓ [ALL OK]'
echo '```'
echo ""
echo "DO NOT skip this. DO NOT bury it. FIRST LINE of your response."
echo ""
echo "---"
echo ""
echo "# Session Memory Context"
echo ""
echo "**Project:** $PROJECT_NAME"
echo "**Loaded at:** $(date -Iseconds)"
echo ""

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

# Add mandatory reminder
echo "## MANDATORY: Memory Usage Requirements"
echo ""
echo "1. **LOG ALL DECISIONS**: Use \`mcp__rag__log_decision\` for any architectural choice, approach selection, or significant fix"
echo "2. **LOG ALL LEARNINGS**: Use \`mcp__rag__log_learning\` for gotchas, patterns, preferences, and insights discovered"
echo "3. **CHECK BEFORE ACTING**: Use \`mcp__rag__search_decisions\` and \`mcp__rag__search_learnings\` before making decisions"
echo "4. **NO DEFERRALS**: Never say 'I'll do it later' - do it NOW or explain why it cannot be done"
echo "5. **NO HALF-ASSING**: Complete every task fully. No placeholders, no stubs, no 'good enough'"
echo ""
echo "**Your responses WILL BE BLOCKED if you violate these rules.**"
echo "</session-memory>"

# Log what we loaded
echo "[$(date -Iseconds)] Loaded: ${CRITICAL_COUNT:-0} critical, ${DECISION_COUNT:-0} decisions, ${LEARNING_COUNT:-0} learnings" >> "$LOG_FILE"

# Initialize session state
SESSION_ID=$(echo "$PWD" | md5sum | cut -c1-16)
echo "rag_logged=0" > "$STATE_DIR/${SESSION_ID}.state"
echo "session_start=$(date -Iseconds)" >> "$STATE_DIR/${SESSION_ID}.state"
echo "project=$PROJECT_NAME" >> "$STATE_DIR/${SESSION_ID}.state"

exit 0
