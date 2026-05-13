#!/bin/bash
# RAG Context Loader - Automatically loads relevant RAG context on every message
# Hook: UserPromptSubmit
#
# PURPOSE: Force RAG lookup on every message. No more "reminders" - actually DO the search
# and inject relevant learnings/decisions into context.
#
# Queries:
# 1. Critical learnings (gotchas) - always injected
# 2. Recent learnings for current project (last 30 days)
# 3. Recent decisions for current project (last 30 days)

set -uo pipefail

# Read hook input
INPUT=$(cat)
USER_PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // .prompt // .message // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# Skip if no prompt
if [[ -z "$USER_PROMPT" || "$USER_PROMPT" == "null" ]]; then
    exit 0
fi

# Determine project from working directory
PROJECT=""
if [[ -n "$CWD" ]]; then
    # Extract project name from path patterns like /home/*/arbiter/*/project or /home/*/Development/*/project
    if [[ "$CWD" =~ arbiter/([^/]+)/([^/]+) ]]; then
        PROJECT="${BASH_REMATCH[2]}"
    elif [[ "$CWD" =~ Development/([^/]+)/([^/]+) ]]; then
        PROJECT="${BASH_REMATCH[2]}"
    elif [[ "$CWD" =~ arbiter/([^/]+)$ ]]; then
        PROJECT="${BASH_REMATCH[1]}"
    fi
fi

# Get DB credentials
POSTGRES_PASSWORD=$(jq -r '.mcpServers.rag.env.POSTGRES_PASSWORD // empty' ~/.claude.json 2>/dev/null)
if [[ -z "$POSTGRES_PASSWORD" ]]; then
    exit 0
fi

POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"

# ============================================================================
# 1. CRITICAL LEARNINGS - Always inject gotchas
# ============================================================================
CRITICAL=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A 2>/dev/null << 'SQL'
SELECT string_agg(content, E'\n- ')
FROM (
    SELECT DISTINCT ON (content) content, created_at
    FROM learnings
    WHERE category = 'gotcha'
       OR 'critical' = ANY(tags)
       OR 'hooks' = ANY(tags)
    ORDER BY content, created_at DESC
    LIMIT 10
) sub;
SQL
)

if [[ -n "$CRITICAL" && "$CRITICAL" != "" ]]; then
    echo "<critical-learnings>"
    echo "**APPLY THESE RULES TO YOUR RESPONSE:**"
    echo "- $CRITICAL"
    echo "</critical-learnings>"
fi

# ============================================================================
# 2. RECENT LEARNINGS - Last 30 days for current project (or global if no project)
# ============================================================================
if [[ -n "$PROJECT" ]]; then
    LEARNINGS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A 2>/dev/null << SQL
SELECT string_agg(formatted, E'\n')
FROM (
    SELECT '- [' || UPPER(category) || '] ' || content ||
           CASE WHEN context IS NOT NULL AND context != '' THEN E'\n  _Context: ' || context || '_' ELSE '' END as formatted
    FROM learnings
    WHERE (project = '$PROJECT' OR project IS NULL)
      AND created_at > NOW() - INTERVAL '30 days'
      AND category != 'gotcha'  -- Already included in critical
    ORDER BY created_at DESC
    LIMIT 5
) sub;
SQL
    )
else
    # No project context - get recent global learnings
    LEARNINGS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A 2>/dev/null << 'SQL'
SELECT string_agg(formatted, E'\n')
FROM (
    SELECT '- [' || UPPER(category) || '] ' || content ||
           CASE WHEN context IS NOT NULL AND context != '' THEN E'\n  _Context: ' || context || '_' ELSE '' END as formatted
    FROM learnings
    WHERE project IS NULL
      AND created_at > NOW() - INTERVAL '30 days'
      AND category != 'gotcha'
    ORDER BY created_at DESC
    LIMIT 5
) sub;
SQL
    )
fi

if [[ -n "$LEARNINGS" && "$LEARNINGS" != "" ]]; then
    echo "<recent-learnings project=\"${PROJECT:-global}\">"
    echo "**Recent learnings (auto-loaded from RAG):**"
    echo "$LEARNINGS"
    echo "</recent-learnings>"
fi

# ============================================================================
# 3. RECENT DECISIONS - Last 30 days for current project
# ============================================================================
if [[ -n "$PROJECT" ]]; then
    DECISIONS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A 2>/dev/null << SQL
SELECT string_agg(formatted, E'\n')
FROM (
    SELECT '- **' || summary || '** (' || TO_CHAR(created_at, 'YYYY-MM-DD') || ')' ||
           E'\n  _Rationale: ' || LEFT(rationale, 200) || CASE WHEN LENGTH(rationale) > 200 THEN '...' ELSE '' END || '_' as formatted
    FROM decisions
    WHERE (project = '$PROJECT' OR project IS NULL)
      AND created_at > NOW() - INTERVAL '30 days'
    ORDER BY created_at DESC
    LIMIT 3
) sub;
SQL
    )

    if [[ -n "$DECISIONS" && "$DECISIONS" != "" ]]; then
        echo "<recent-decisions project=\"$PROJECT\">"
        echo "**Recent decisions (auto-loaded from RAG):**"
        echo "$DECISIONS"
        echo "</recent-decisions>"
    fi
fi

# ============================================================================
# 4. PATTERN-BASED REMINDERS - Keep for specific triggers
# ============================================================================
PROMPT_LOWER=$(echo "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')
OUTPUT=""

# Only add reminder if asking about past work specifically
if echo "$PROMPT_LOWER" | grep -qE 'did we|have we|last time|before|previous|remember|forgot|earlier|already'; then
    OUTPUT+="<rag-reminder>\n"
    OUTPUT+="**CHECK RAG MEMORY FIRST**: This question references past work. Use:\n"
    OUTPUT+="- \`mcp__rag__search_decisions\` for past architectural choices\n"
    OUTPUT+="- \`mcp__rag__search_learnings\` for past discoveries and gotchas\n"
    OUTPUT+="- \`mcp__rag__get_session_context\` for recent project history\n"
    OUTPUT+="</rag-reminder>\n"
fi

# Debug/fix requests - suggest checking for similar issues
if echo "$PROMPT_LOWER" | grep -qE 'fix|debug|broken|not working|error|issue|problem|wrong|fail'; then
    if [[ -z "$OUTPUT" ]]; then
        OUTPUT+="<rag-reminder>\n"
        OUTPUT+="**CHECK RAG FOR SIMILAR ISSUES**: Before debugging, search for similar past problems:\n"
        OUTPUT+="- \`mcp__rag__search_learnings\` with category='gotcha'\n"
        OUTPUT+="- \`mcp__rag__search_docs\` for relevant documentation\n"
        OUTPUT+="</rag-reminder>\n"
    fi
fi

if [[ -n "$OUTPUT" ]]; then
    echo -e "$OUTPUT"
fi

exit 0
