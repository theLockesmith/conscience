#!/bin/bash
# Multi-Session Coordination — Context Injection Hook
# V13 + V17 Phase 11c
#
# Injects coordination status (other sessions on this project, pending tasks,
# unread messages + previews) into UserPromptSubmit. The client speaks ONLY
# MCP-over-HTTPS with a per-surface PAT — no psql / .pgpass / POSTGRES_PASSWORD.
# Surface resolved from cwd via sr_resolve; unprovisioned surface = silent no-op.

set -uo pipefail

INPUT_JSON=$(cat || true)

. "$HOME/.claude/hooks/lib/surface-resolve.sh" 2>/dev/null || { echo '{"hook_result":"continue"}'; exit 0; }

PROJECT_PATH="$PWD"
RESOLVED=$(sr_resolve "$PROJECT_PATH" 2>/dev/null) || RESOLVED=""
IFS='|' read -r SURFACE COMPANY MCP_SERVER MCP_URL TOKEN_FILE <<< "$RESOLVED"

[[ -n "${MCP_URL:-}" && -n "${TOKEN_FILE:-}" ]] || { echo '{"hook_result":"continue"}'; exit 0; }

MC="$HOME/.claude/hooks/lib/mcp-call.sh"

# Build all four MCP-call argsets up front, then fire the four reads in
# parallel with a tight per-call deadline. Wall time was previously 4 ×
# (network + MCP work), routinely hitting the 10s hook cap; this drops it
# to max(individual) ≈ 2s. Each call writes to its own temp file so we
# avoid bash subshell variable scoping. A timeout on any one call ->
# silent empty output for that section (same behavior as the old `|| true`).
SESS_ARGS=$(jq -nc --arg pp "$PROJECT_PATH" '{project_path:$pp, status:"active"}' 2>/dev/null) || exit 0
TASK_ARGS='{"status":"pending","limit":50}'
MSG_ARGS='{"unread_only":true,"limit":20}'
NOTES_ARGS=$(jq -nc --arg pp "$PROJECT_PATH" '{project_path:$pp, limit:5}' 2>/dev/null) || NOTES_ARGS='{"limit":5}'

MSC_TMP=$(mktemp -d -t msc.XXXXXX) || exit 0
trap 'rm -rf "$MSC_TMP"; echo "{\"hook_result\":\"continue\"}"' EXIT

( timeout 2 "$MC" "$MCP_URL" "$TOKEN_FILE" coord_list_sessions "$SESS_ARGS"  > "$MSC_TMP/sess"  2>/dev/null ) &
( timeout 2 "$MC" "$MCP_URL" "$TOKEN_FILE" coord_list_tasks    "$TASK_ARGS"  > "$MSC_TMP/task"  2>/dev/null ) &
( timeout 2 "$MC" "$MCP_URL" "$TOKEN_FILE" coord_get_messages  "$MSG_ARGS"   > "$MSC_TMP/msg"   2>/dev/null ) &
( timeout 2 "$MC" "$MCP_URL" "$TOKEN_FILE" coord_notes_for_me  "$NOTES_ARGS" > "$MSC_TMP/notes" 2>/dev/null ) &
wait

SESS_OUT=$(cat "$MSC_TMP/sess"  2>/dev/null) || SESS_OUT=""
TASK_OUT=$(cat "$MSC_TMP/task"  2>/dev/null) || TASK_OUT=""
MSG_OUT=$(cat  "$MSC_TMP/msg"   2>/dev/null) || MSG_OUT=""
NOTES_OUT=$(cat "$MSC_TMP/notes" 2>/dev/null) || NOTES_OUT=""

# (1) Active sessions on this project: count - 1 = peers.
SESS_N=$(grep -oE 'Found [0-9]+' <<<"$SESS_OUT" | head -1 | grep -oE '[0-9]+' || true)
[[ -n "$SESS_N" ]] || SESS_N=0
PEERS=$(( SESS_N > 0 ? SESS_N - 1 : 0 ))

# (2) Pending tasks.
PEND_N=$(grep -oE 'Found [0-9]+' <<<"$TASK_OUT" | head -1 | grep -oE '[0-9]+' || true)
[[ -n "$PEND_N" ]] || PEND_N=0

# (3) Unread messages for this session.
UNREAD_N=$(grep -oE 'Messages \([0-9]+\)' <<<"$MSG_OUT" | head -1 | grep -oE '[0-9]+' || true)
[[ -n "$UNREAD_N" ]] || UNREAD_N=0

# (4) Phase 12: passive notes whose target_context matches this session's
# working context. Topics + file_paths are not passed from the hook today
# (no clean way to enumerate them); operators can still drop notes with
# project_path-only matchers and they will surface here.
NOTES_N=$(grep -oE 'Passive notes \([0-9]+\)' <<<"$NOTES_OUT" | head -1 | grep -oE '[0-9]+' || true)
[[ -n "$NOTES_N" ]] || NOTES_N=0

if [[ "$PEERS" -gt 0 || "$PEND_N" -gt 0 || "$UNREAD_N" -gt 0 || "$NOTES_N" -gt 0 ]]; then
    echo "<multi-session-status>"
    echo "Surface: $SURFACE"
    [[ "$PEERS"   -gt 0 ]] && echo "Other sessions on this project: $PEERS"
    [[ "$PEND_N"  -gt 0 ]] && echo "Pending tasks: $PEND_N (use coord_claim_task)"
    [[ "$UNREAD_N" -gt 0 ]] && echo "Unread messages: $UNREAD_N (use coord_get_messages)"

    # Phase 11c: surface unread message previews so the assistant sees what
    # came in without having to explicitly call coord_get_messages. Walk the
    # markdown coord_get_messages emits and extract subject + sender prefix
    # + first body line (~110 chars) for up to 5 messages.
    if [[ "$UNREAD_N" -gt 0 && -n "$MSG_OUT" ]]; then
        echo "Unread previews:"
        echo "$MSG_OUT" | awk '
            BEGIN { state = 0; n = 0; subj = ""; sender_short = "" }
            /^### \[/ {
                if (match($0, /\*\*(.+)\*\*[[:space:]]+from[[:space:]]+`([^`]+)`/, m)) {
                    subj = m[1]
                    sender_short = substr(m[2], 1, 8)
                } else {
                    subj = "(no-subject)"
                    sender_short = "????????"
                }
                state = 1
                next
            }
            state == 1 && /^ID: `/ { state = 2; next }
            state == 2 && length($0) > 0 && $0 !~ /^[[:space:]]*$/ {
                preview = substr($0, 1, 110)
                printf "  - [%s] %s\n    %s\n", sender_short, subj, preview
                n += 1
                if (n >= 5) exit
                state = 0
            }
        '
    fi

    # Phase 12: surface passive notes by walking coord_notes_for_me output.
    # Each match block in the markdown:
    #   ### `<note_id>` [mode] **subject**
    #   by `<sender>` at <timestamp>
    #   (blank line)
    #   <body, multi-line>
    #   (blank line)
    #   _dismiss: coord_note_dismiss(note_id="<id>")_
    if [[ "$NOTES_N" -gt 0 && -n "$NOTES_OUT" ]]; then
        echo "Passive notes for this context: $NOTES_N (use coord_note_dismiss when done)"
        echo "$NOTES_OUT" | awk '
            BEGIN { state = 0; n = 0; subj = ""; mode = ""; nid_short = "" }
            /^### `/ {
                # parse: ### `<note_id>` [<mode>] **<subject>**
                if (match($0, /`([^`]+)`[[:space:]]+\[([a-z]+)\][[:space:]]+\*\*(.+)\*\*/, m)) {
                    nid_short = substr(m[1], 1, 8)
                    mode = m[2]
                    subj = m[3]
                } else {
                    nid_short = "????????"
                    mode = "?"
                    subj = "(no-subject)"
                }
                state = 1
                next
            }
            state == 1 && /^by `/ { state = 2; next }   # skip the "by ... at ..." line
            state == 2 {
                if (length($0) == 0 || $0 ~ /^[[:space:]]*$/) next  # skip blank
                if ($0 ~ /^_dismiss:/) { state = 0; next }          # end-of-block marker
                preview = substr($0, 1, 110)
                printf "  - [%s][%s] %s\n    %s\n", nid_short, mode, subj, preview
                n += 1
                if (n >= 5) exit
                state = 0
            }
        '
    fi
    echo "</multi-session-status>"
fi
