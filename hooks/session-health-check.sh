#!/bin/bash
# Session Health Check - Verifies RAG (via MCP), MCP, Ollama, Tribunal
# Location: ~/.claude/hooks/session-health-check.sh
# Hook: SessionStart
#
# Outputs a status banner showing connection health.
#
# HISTORICAL NOTE (2026-07-06): pre-V16, this checked Postgres TCP
# directly at postgres-rw.db.aegis-hq.xyz:5432 — but post-V16 the
# workstation NEVER connects to Postgres directly (per surfaces.yaml:
# "The client speaks only MCP-over-HTTPS"). The old direct-PG probe
# was a false negative that fired whenever the aegis-hq edge was
# flaky, even though MCP-mediated RAG kept working.
#
# Post-2026-07-06:
#   - "RAG (via MCP)" probes the rag-mcp HTTP /health endpoint —
#     which is the path all RAG traffic actually takes
#   - "MCP Server" checks .claude.json wiring (stdio or http shape)
#   - Postgres endpoint variables retained ONLY for legacy overrides;
#     no longer used by the health check itself

set -uo pipefail

# Parse arguments
PANE_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pane-only) PANE_ONLY=true; shift ;;
        *) shift ;;
    esac
done

# Configuration
OLLAMA_URL="${OLLAMA_URL:-http://10.0.4.10:11434}"
SYSTEM_PROMPT_FILE="$HOME/.claude/system-prompt.md"
CLAUDE_JSON="$HOME/.claude.json"

# Status tracking
RAG_STATUS="UNKNOWN"
OLLAMA_STATUS="UNKNOWN"
TRIBUNAL_STATUS="UNKNOWN"
MCP_STATUS="UNKNOWN"

# Colors for terminal (will show in logs)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test RAG via MCP — probes the rag-mcp /health HTTP endpoint. This is
# the actual data-plane path (workstation → MCP over HTTPS → server-
# side DB). Returns CONNECTED on HTTP 200, DISCONNECTED otherwise.
#
# Skips silently when the mcp URL isn't extractable (stdio proxy or
# missing rag entry) — MCP_STATUS handles wiring detection instead.
test_rag_via_mcp() {
    local mcp_url=""
    if [[ -f "$CLAUDE_JSON" ]]; then
        mcp_url=$(python3 -c "
import json, sys
try:
    d = json.load(open('$CLAUDE_JSON'))
    url = d.get('mcpServers', {}).get('rag', {}).get('url', '')
    if url.endswith('/mcp'):
        print(url[:-4] + '/health')
    elif url:
        print(url + '/health')
except Exception:
    pass
" 2>/dev/null)
    fi

    # No URL — could be the stdio proxy shape (mcpServers.rag.command)
    # or no rag entry at all. Either way, the direct HTTP health probe
    # doesn't apply; degrade to UNKNOWN and let MCP_STATUS carry the
    # signal. Not a false negative.
    if [[ -z "$mcp_url" ]]; then
        RAG_STATUS="N/A"
        return 0
    fi

    if curl -sf --max-time 3 -o /dev/null "$mcp_url" 2>/dev/null; then
        RAG_STATUS="CONNECTED"
        return 0
    fi

    RAG_STATUS="DISCONNECTED"
    return 1
}

# Test Ollama (embeddings)
test_ollama() {
    if curl -s --max-time 3 "${OLLAMA_URL}/api/tags" &>/dev/null; then
        OLLAMA_STATUS="CONNECTED"
        return 0
    fi
    OLLAMA_STATUS="DISCONNECTED"
    return 1
}

# Test Tribunal identity (system prompt)
test_tribunal() {
    if [[ -f "$SYSTEM_PROMPT_FILE" ]]; then
        if grep -qi "arbiter\|tribunal" "$SYSTEM_PROMPT_FILE" 2>/dev/null; then
            TRIBUNAL_STATUS="ACTIVE"
            return 0
        fi
    fi

    # Check if wrapper script is being used
    if [[ -f "$HOME/.claude/claude-wrapper.sh" ]] && grep -q "system-prompt" "$HOME/.claude/claude-wrapper.sh" 2>/dev/null; then
        TRIBUNAL_STATUS="CONFIGURED"
        return 0
    fi

    TRIBUNAL_STATUS="NOT CONFIGURED"
    return 1
}

# Test MCP wiring — inspect ~/.claude.json for a well-formed rag
# entry. Two shapes are valid:
#   HTTP:  { url, headers.Authorization }
#   stdio: { command, args } — arbiter mcp-proxy or similar
#
# Post-V13 the MCP server runs in the atlantis cluster; there's no
# local supervisor.py to look for. The old pgrep + local-supervisor
# check was inherited from pre-V13 and produced NOT CONFIGURED even
# though MCP was perfectly fine.
test_mcp() {
    if [[ ! -f "$CLAUDE_JSON" ]]; then
        MCP_STATUS="NOT CONFIGURED"
        return 1
    fi

    local shape
    shape=$(python3 -c "
import json, sys
try:
    d = json.load(open('$CLAUDE_JSON'))
    entry = d.get('mcpServers', {}).get('rag', {})
    if not entry:
        print('MISSING')
    elif 'url' in entry and entry['url']:
        print('HTTP')
    elif 'command' in entry and entry['command']:
        print('STDIO')
    else:
        print('MALFORMED')
except Exception:
    print('MISSING')
" 2>/dev/null)

    case "$shape" in
        HTTP)  MCP_STATUS="CONFIGURED"; return 0 ;;
        STDIO) MCP_STATUS="CONFIGURED"; return 0 ;;
        MALFORMED)
            MCP_STATUS="MALFORMED"
            return 1
            ;;
        *)
            MCP_STATUS="NOT CONFIGURED"
            return 1
            ;;
    esac
}

# Run all checks
test_rag_via_mcp
test_ollama
test_tribunal
test_mcp

# Count healthy vs unhealthy
# Note: Using ((++VAR)) or adding || true because ((VAR++)) returns 1 when VAR is 0
HEALTHY=0
UNHEALTHY=0

# "N/A" (stdio proxy — no HTTP health endpoint to probe) is not a
# failure; MCP_STATUS carries the wiring signal in that case.
if [[ "$RAG_STATUS" =~ ^(CONNECTED|N/A)$ ]]; then ((++HEALTHY)); else ((++UNHEALTHY)); fi
if [[ "$OLLAMA_STATUS" == "CONNECTED" ]]; then ((++HEALTHY)); else ((++UNHEALTHY)); fi
if [[ "$TRIBUNAL_STATUS" =~ ^(ACTIVE|CONFIGURED)$ ]]; then ((++HEALTHY)); else ((++UNHEALTHY)); fi
if [[ "$MCP_STATUS" =~ ^(CONFIGURED|RUNNING|VERIFIED)$ ]]; then ((++HEALTHY)); else ((++UNHEALTHY)); fi

# Generate status banner
generate_banner() {
    local overall_status
    if [[ $UNHEALTHY -eq 0 ]]; then
        overall_status="ALL SYSTEMS OPERATIONAL"
    elif [[ $HEALTHY -eq 0 ]]; then
        overall_status="ALL SYSTEMS DOWN"
    else
        overall_status="PARTIAL OUTAGE ($UNHEALTHY/4 systems down)"
    fi

    cat << EOF
<system-reminder>
╔══════════════════════════════════════════════════════════════╗
║                    SESSION HEALTH CHECK                       ║
╠══════════════════════════════════════════════════════════════╣
║  RAG (via MCP):   $(printf "%-12s" "$RAG_STATUS") $(status_icon "$RAG_STATUS")                          ║
║  Ollama:          $(printf "%-12s" "$OLLAMA_STATUS") $(status_icon "$OLLAMA_STATUS")                          ║
║  Tribunal:        $(printf "%-12s" "$TRIBUNAL_STATUS") $(status_icon "$TRIBUNAL_STATUS")                          ║
║  MCP Server:      $(printf "%-12s" "$MCP_STATUS") $(status_icon "$MCP_STATUS")                          ║
╠══════════════════════════════════════════════════════════════╣
║  Status: $overall_status
╚══════════════════════════════════════════════════════════════╝
EOF

    # Add warnings for any disconnected systems
    if [[ "$RAG_STATUS" == "DISCONNECTED" ]]; then
        echo "WARNING: RAG /health endpoint unreachable"
        echo "  - Memory tools (log_decision, log_learning) may FAIL"
        echo "  - Check: curl -sf https://rag-mcp.aegis-hq.xyz/health"
        echo "  - If /health is 200 but the banner still shows DISCONNECTED,"
        echo "    the check ran during a transient — retry a new session"
    fi

    if [[ "$OLLAMA_STATUS" == "DISCONNECTED" ]]; then
        echo "WARNING: Ollama unreachable at $OLLAMA_URL"
        echo "  - Semantic search will be degraded"
        echo "  - Check: curl $OLLAMA_URL/api/tags"
    fi

    if [[ "$TRIBUNAL_STATUS" == "NOT CONFIGURED" ]]; then
        echo "WARNING: Tribunal identity not active"
        echo "  - System prompt may not include Arbiter persona"
        echo "  - Check: ~/.claude/system-prompt.md exists"
    fi

    if [[ "$MCP_STATUS" == "NOT CONFIGURED" ]] || [[ "$MCP_STATUS" == "MALFORMED" ]]; then
        echo "WARNING: MCP rag entry missing or malformed in ~/.claude.json"
        echo "  - RAG tools will not be available"
        echo "  - Check: arbiter doctor  (or re-run arbiter install)"
    fi

    echo "</system-reminder>"
}

status_icon() {
    local status="$1"
    case "$status" in
        CONNECTED|ACTIVE|RUNNING|VERIFIED)
            echo "[OK]"
            ;;
        CONFIGURED)
            echo "[~]"
            ;;
        *)
            echo "[X]"
            ;;
    esac
}

# Output the banner (goes to Claude's context via stdout)
# Skip if --pane-only mode (background refresh)
if [[ "$PANE_ONLY" != "true" ]]; then
    generate_banner
fi

# Output user-visible status line directly to terminal
# Using /dev/tty bypasses any stdout/stderr redirection
output_user_status() {
    # Only output if we have a controlling terminal
    [[ -t 0 ]] || [[ -e /dev/tty ]] || return 0

    local icon_ok="${GREEN}✓${NC}"
    local icon_warn="${YELLOW}~${NC}"
    local icon_fail="${RED}✗${NC}"
    local output=""

    output+="Session: "

    # RAG
    if [[ "$RAG_STATUS" == "CONNECTED" ]]; then
        output+="RAG${icon_ok} "
    else
        output+="RAG${icon_fail} "
    fi

    # Ollama
    if [[ "$OLLAMA_STATUS" == "CONNECTED" ]]; then
        output+="Ollama${icon_ok} "
    else
        output+="Ollama${icon_fail} "
    fi

    # Tribunal
    if [[ "$TRIBUNAL_STATUS" =~ ^(ACTIVE|CONFIGURED)$ ]]; then
        output+="Tribunal${icon_ok} "
    else
        output+="Tribunal${icon_fail} "
    fi

    # MCP - show verification status
    case "$MCP_STATUS" in
        VERIFIED)
            output+="MCP${icon_ok}"
            [[ -n "$MCP_DOC_COUNT" ]] && output+="(${MCP_DOC_COUNT} docs)"
            ;;
        RUNNING|CONFIGURED)
            output+="MCP${icon_warn}"
            ;;
        *)
            output+="MCP${icon_fail}"
            ;;
    esac

    # Overall status
    if [[ $UNHEALTHY -eq 0 ]]; then
        output+=" ${GREEN}[READY]${NC}"
    else
        output+=" ${YELLOW}[$HEALTHY/4]${NC}"
    fi

    # Write directly to terminal, bypassing any redirection
    printf "%b\n" "$output" > /dev/tty 2>/dev/null || printf "%b\n" "$output" >&2
}

# Skip terminal output if --pane-only mode
if [[ "$PANE_ONLY" != "true" ]]; then
    output_user_status
fi

# Write to tmux pane-specific status file for status bar display
write_pane_status() {
    local pane_dir="$HOME/.claude/pane-status"
    mkdir -p "$pane_dir"

    # Use TMUX_PANE if available, fallback to session ID
    local pane_id="${TMUX_PANE:-unknown}"
    # Remove % prefix from pane ID for cleaner filename
    pane_id="${pane_id#%}"

    local status_file="$pane_dir/${pane_id}.status"
    local status_line=""

    # Tmux color codes
    local green="#[fg=green]"
    local red="#[fg=red]"
    local blue="#[fg=blue]"
    local reset="#[default]"

    # Build status line: [ RAG✓ LLM✓ TRI✓ MCP✓ ] [OK]
    # Blue brackets, green/red statuses
    status_line+="${blue}[ ${reset}"

    # RAG
    if [[ "$RAG_STATUS" == "CONNECTED" ]]; then
        status_line+="${green}RAG✓${reset} "
    else
        status_line+="${red}RAG✗${reset} "
    fi

    # LLM (Ollama)
    if [[ "$OLLAMA_STATUS" == "CONNECTED" ]]; then
        status_line+="${green}LLM✓${reset} "
    else
        status_line+="${red}LLM✗${reset} "
    fi

    # TRI (Tribunal)
    if [[ "$TRIBUNAL_STATUS" =~ ^(ACTIVE|CONFIGURED)$ ]]; then
        status_line+="${green}TRI✓${reset} "
    else
        status_line+="${red}TRI✗${reset} "
    fi

    # MCP
    if [[ "$MCP_STATUS" =~ ^(CONFIGURED|RUNNING|VERIFIED)$ ]]; then
        status_line+="${green}MCP✓${reset}"
    else
        status_line+="${red}MCP✗${reset}"
    fi

    status_line+="${blue}]─[${reset}"

    # Overall status (green OK / red count, blue brackets)
    if [[ $UNHEALTHY -eq 0 ]]; then
        status_line+="${green}OK${reset}"
    else
        status_line+="${red}$HEALTHY/4${reset}"
    fi

    status_line+="${blue}]${reset}"

    # Write status (single line, no timestamp needed - file mtime is enough)
    echo "$status_line" > "$status_file"
}

write_pane_status

# Log to file for debugging
echo "[$(date -Iseconds)] Health check: RAG=$RAG_STATUS OLLAMA=$OLLAMA_STATUS TRIBUNAL=$TRIBUNAL_STATUS MCP=$MCP_STATUS PANE=${TMUX_PANE:-unknown}" >> "$HOME/.claude/session-health.log"

exit 0
