#!/bin/bash
# V14 Multi-Session Coordination - Session Registration Hook
#
# Registers this session in the coord_sessions table for discovery by other sessions.
# Now includes entity/project detection for V14 orchestration.
#
# Called on SessionStart (new session or after compaction).
#
# Input: JSON with session context
# Output: Status message injected into context

set -e

# Read JSON input from stdin (Claude Code passes session context this way)
INPUT_JSON=$(cat)

# Extract session ID from JSON input, fall back to environment variables
SESSION_ID=$(echo "$INPUT_JSON" | jq -r '.session_id // empty')
if [[ -z "$SESSION_ID" ]]; then
    # Fallback to environment variables for compatibility
    SESSION_ID="${LLM_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
fi

# Database connection
POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD env var required}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"

export PGPASSWORD="$POSTGRES_PASSWORD"

# Get project path and working directory
PROJECT_PATH=$(pwd)
WORKING_DIR=$(pwd)

# Detect model tier from environment or default
if [[ -n "$CLAUDE_MODEL" ]]; then
    case "$CLAUDE_MODEL" in
        *opus*) MODEL_TIER="reasoning" ;;
        *sonnet*) MODEL_TIER="balanced" ;;
        *haiku*) MODEL_TIER="fast" ;;
        *) MODEL_TIER="balanced" ;;
    esac
else
    MODEL_TIER="balanced"
fi

# Detect provider
PROVIDER="${LLM_PROVIDER:-anthropic}"

# Skip if no session ID
if [[ -z "$SESSION_ID" || "$SESSION_ID" == "null" ]]; then
    echo '{"hook_result": "continue"}'
    exit 0
fi

# V14: Detect entity and project from path
ENTITY_PROJECT=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "
SELECT entity || ':' || COALESCE(project, '')
FROM detect_entity_project('$PROJECT_PATH')
LIMIT 1;
" 2>/dev/null || echo ":")

ENTITY=$(echo "$ENTITY_PROJECT" | cut -d: -f1)
PROJECT_NAME=$(echo "$ENTITY_PROJECT" | cut -d: -f2)

# Register or update session in database
# Uses ON CONFLICT to handle re-registration after compaction
psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q -c "
INSERT INTO coord_sessions (
    session_id, project_path, working_directory, model_tier, provider,
    role, status, last_heartbeat, started_at, entity, project
) VALUES (
    '$SESSION_ID',
    '$PROJECT_PATH',
    '$WORKING_DIR',
    '$MODEL_TIER',
    '$PROVIDER',
    'independent',
    'active',
    NOW(),
    NOW(),
    NULLIF('$ENTITY', ''),
    NULLIF('$PROJECT_NAME', '')
) ON CONFLICT (session_id) DO UPDATE SET
    last_heartbeat = NOW(),
    status = 'active',
    working_directory = '$WORKING_DIR',
    entity = NULLIF('$ENTITY', ''),
    project = NULLIF('$PROJECT_NAME', '')
;" 2>/dev/null || true

# Check for other active sessions on this project
OTHER_SESSIONS=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "
SELECT COUNT(*) FROM coord_sessions
WHERE project_path = '$PROJECT_PATH'
AND session_id != '$SESSION_ID'
AND status IN ('active', 'idle', 'busy')
AND last_heartbeat > NOW() - INTERVAL '5 minutes'
;" 2>/dev/null || echo "0")

# V14: Check for sessions on related projects (same entity, different project)
RELATED_SESSIONS=""
if [[ -n "$ENTITY" && -n "$PROJECT_NAME" ]]; then
    RELATED_SESSIONS=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "
    SELECT STRING_AGG(s.project || ' (' || s.status || ')', ', ')
    FROM coord_sessions s
    WHERE s.entity = '$ENTITY'
    AND s.project != '$PROJECT_NAME'
    AND s.session_id != '$SESSION_ID'
    AND s.status IN ('active', 'idle', 'busy')
    AND s.last_heartbeat > NOW() - INTERVAL '5 minutes';
    " 2>/dev/null || echo "")
fi

# Output status
echo '{"hook_result": "continue"}'

if [[ "$OTHER_SESSIONS" -gt 0 || -n "$RELATED_SESSIONS" ]]; then
    echo ""
    echo "<coordination-status>"
    echo "Multi-session coordination active."

    if [[ -n "$ENTITY" ]]; then
        echo "Entity: $ENTITY | Project: ${PROJECT_NAME:-N/A}"
    fi

    if [[ "$OTHER_SESSIONS" -gt 0 ]]; then
        echo "Other sessions on this project: $OTHER_SESSIONS"
    fi

    if [[ -n "$RELATED_SESSIONS" ]]; then
        echo "Related sessions in $ENTITY: $RELATED_SESSIONS"
    fi

    echo "Use coord_list_sessions to see details, coord_check_related to see dependencies."
    echo "</coordination-status>"
fi
