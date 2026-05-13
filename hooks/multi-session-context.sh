#!/bin/bash
# V13 Multi-Session Coordination - Context Injection Hook
#
# Injects coordination status into user prompts so Claude is aware of:
# - Other active sessions on the same project
# - Pending/claimed tasks
# - Unread messages
# - Current role (lead/worker/independent)
#
# This hook runs on UserPromptSubmit.

set -e

# Read JSON input from stdin
INPUT_JSON=$(cat)

# Get session ID from environment or input
SESSION_ID=$(echo "$INPUT_JSON" | jq -r '.session_id // empty')
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="${LLM_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
fi

# Database connection
POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-***REDACTED-cred-rotated-2026-05-13***}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"

export PGPASSWORD="$POSTGRES_PASSWORD"

PROJECT_PATH=$(pwd)

# Skip if session not registered
if [[ "$SESSION_ID" == "unknown" ]]; then
    exit 0
fi

# Query coordination status (single query for efficiency)
STATUS=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -F'|' -c "
WITH my_session AS (
    SELECT role, status FROM coord_sessions WHERE session_id = '$SESSION_ID' LIMIT 1
),
other_sessions AS (
    SELECT COUNT(*) as cnt FROM coord_sessions
    WHERE project_path = '$PROJECT_PATH'
      AND session_id != '$SESSION_ID'
      AND status IN ('active', 'idle', 'busy')
      AND last_heartbeat > NOW() - INTERVAL '5 minutes'
),
pending_tasks AS (
    SELECT COUNT(*) as cnt FROM coord_tasks
    WHERE project_path = '$PROJECT_PATH' AND status = 'pending'
),
my_tasks AS (
    SELECT COUNT(*) as cnt FROM coord_tasks
    WHERE claimed_by = '$SESSION_ID' AND status IN ('claimed', 'in_progress')
),
unread_msgs AS (
    SELECT COUNT(*) as cnt FROM coord_messages
    WHERE (to_session = '$SESSION_ID' OR to_session IS NULL)
      AND project_path = '$PROJECT_PATH'
      AND read_at IS NULL
      AND from_session != '$SESSION_ID'
),
lead_session AS (
    SELECT session_id FROM coord_sessions
    WHERE project_path = '$PROJECT_PATH' AND role = 'lead'
      AND status IN ('active', 'idle', 'busy')
      AND last_heartbeat > NOW() - INTERVAL '5 minutes'
    LIMIT 1
)
SELECT
    COALESCE((SELECT role FROM my_session), 'unregistered'),
    COALESCE((SELECT cnt FROM other_sessions), 0),
    COALESCE((SELECT cnt FROM pending_tasks), 0),
    COALESCE((SELECT cnt FROM my_tasks), 0),
    COALESCE((SELECT cnt FROM unread_msgs), 0),
    COALESCE((SELECT session_id FROM lead_session), '')
" 2>/dev/null || echo "error|0|0|0|0|")

# Parse results
IFS='|' read -r ROLE OTHER_SESSIONS PENDING_TASKS MY_TASKS UNREAD_MSGS LEAD_ID <<< "$STATUS"

# Only inject context if there's something notable
if [[ "$OTHER_SESSIONS" -gt 0 || "$PENDING_TASKS" -gt 0 || "$UNREAD_MSGS" -gt 0 || "$ROLE" == "lead" ]]; then
    echo "<multi-session-status>"

    # Role
    if [[ "$ROLE" == "lead" ]]; then
        echo "Role: LEAD (you orchestrate workers)"
    elif [[ -n "$LEAD_ID" && "$LEAD_ID" != "$SESSION_ID" ]]; then
        echo "Role: worker (lead: ${LEAD_ID:0:8}...)"
    else
        echo "Role: $ROLE"
    fi

    # Other sessions
    if [[ "$OTHER_SESSIONS" -gt 0 ]]; then
        echo "Active sessions: $((OTHER_SESSIONS + 1)) (including you)"
    fi

    # Tasks
    if [[ "$PENDING_TASKS" -gt 0 ]]; then
        echo "Pending tasks: $PENDING_TASKS (use coord_claim_task)"
    fi
    if [[ "$MY_TASKS" -gt 0 ]]; then
        echo "Your claimed tasks: $MY_TASKS"
    fi

    # Messages
    if [[ "$UNREAD_MSGS" -gt 0 ]]; then
        echo "Unread messages: $UNREAD_MSGS (use coord_get_messages)"
    fi

    echo "</multi-session-status>"
fi

# Always continue
echo '{"hook_result": "continue"}'
