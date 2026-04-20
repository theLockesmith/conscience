#!/bin/bash
# RAG Context Reminder - Reminds to check RAG before answering
# Hook: UserPromptSubmit
#
# PURPOSE: When user asks about something we might have encountered before,
# remind Claude to check RAG first.
#
# Triggers on:
# - Questions about past work ("did we", "have we", "last time", "before")
# - Fix/debug requests (may have encountered similar before)
# - Configuration questions (may have documented settings)
# - Architecture/design questions (may have made related decisions)

set -uo pipefail

# Read hook input
INPUT=$(cat)
USER_PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // .prompt // .message // empty' 2>/dev/null)

# Skip if no prompt
if [[ -z "$USER_PROMPT" || "$USER_PROMPT" == "null" ]]; then
    exit 0
fi

# Convert to lowercase for matching
PROMPT_LOWER=$(echo "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')

# ============================================================================
# PATTERN DETECTION
# ============================================================================

# ============================================================================
# CRITICAL LEARNINGS - ALWAYS INJECT
# Query RAG for critical gotchas and inject them every time
# ============================================================================

# Check for critical learnings in RAG (category=gotcha or has 'critical'/'hooks' tags)
POSTGRES_PASSWORD=$(jq -r '.mcpServers.rag.env.POSTGRES_PASSWORD // empty' ~/.claude.json 2>/dev/null)
if [[ -n "$POSTGRES_PASSWORD" ]]; then
    CRITICAL=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}" -p "${POSTGRES_PORT:-5432}" \
        -U "${POSTGRES_USER:-rag}" -d "${POSTGRES_DB:-ragdb}" -t -A 2>/dev/null << 'SQL'
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
fi

OUTPUT=""

# Pattern 1: Questions about past work
if echo "$PROMPT_LOWER" | grep -qE 'did we|have we|last time|before|previous|remember|forgot|earlier|already'; then
    OUTPUT+="<rag-reminder>\n"
    OUTPUT+="**CHECK RAG MEMORY FIRST**: This question references past work. Use:\n"
    OUTPUT+="- \`mcp__rag__search_decisions\` for past architectural choices\n"
    OUTPUT+="- \`mcp__rag__search_learnings\` for past discoveries and gotchas\n"
    OUTPUT+="- \`mcp__rag__get_session_context\` for recent project history\n"
    OUTPUT+="</rag-reminder>\n"
fi

# Pattern 2: Fix/debug requests (check for similar past issues)
if echo "$PROMPT_LOWER" | grep -qE 'fix|debug|broken|not working|error|issue|problem|wrong|fail'; then
    if [[ -z "$OUTPUT" ]]; then
        OUTPUT+="<rag-reminder>\n"
        OUTPUT+="**CHECK RAG FOR SIMILAR ISSUES**: Before debugging, search for similar past problems:\n"
        OUTPUT+="- \`mcp__rag__search_learnings\` with category='gotcha'\n"
        OUTPUT+="- \`mcp__rag__search_docs\` for relevant documentation\n"
        OUTPUT+="</rag-reminder>\n"
    fi
fi

# Pattern 3: Configuration questions
if echo "$PROMPT_LOWER" | grep -qE 'config|setting|where is|how do i|setup|configure'; then
    if [[ -z "$OUTPUT" ]]; then
        OUTPUT+="<rag-reminder>\n"
        OUTPUT+="**CHECK RAG FOR CONFIGURATION**: Search for documented settings:\n"
        OUTPUT+="- \`mcp__rag__search_docs\` for configuration documentation\n"
        OUTPUT+="- \`mcp__rag__search_instructions\` for project rules\n"
        OUTPUT+="</rag-reminder>\n"
    fi
fi

# Pattern 4: Architecture/design questions
if echo "$PROMPT_LOWER" | grep -qE 'architect|design|approach|should we|how should|best way|pattern'; then
    if [[ -z "$OUTPUT" ]]; then
        OUTPUT+="<rag-reminder>\n"
        OUTPUT+="**CHECK RAG FOR PAST DECISIONS**: Search for related architectural choices:\n"
        OUTPUT+="- \`mcp__rag__search_decisions\` for past approach selections\n"
        OUTPUT+="- \`mcp__rag__search_learnings\` with category='architecture'\n"
        OUTPUT+="</rag-reminder>\n"
    fi
fi

# Output reminder if any patterns matched
if [[ -n "$OUTPUT" ]]; then
    echo -e "$OUTPUT"
fi

exit 0
