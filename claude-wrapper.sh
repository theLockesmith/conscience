#!/bin/bash
# Claude Code wrapper that includes the system prompt and default flags
# Usage: Replace 'claude' with this script, or alias claude to this
#
# Includes:
#   Pre-launch health check: Verifies RAG, MCP, Tribunal connectivity
#   --append-system-prompt-file: Integrity/conscience-driven behavioral prompt
#   --dangerously-skip-permissions: Skip permission prompts (hooks enforce safety)
#
# All additional flags are passed through to claude

# =============================================================================
# PRE-LAUNCH HEALTH CHECK
# =============================================================================

# Configuration
POSTGRES_HOST="${POSTGRES_HOST:-10.51.1.20}"
POSTGRES_PORT="${POSTGRES_PORT:-30432}"
OLLAMA_URL="${OLLAMA_URL:-http://10.0.4.10:11434}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Quick connectivity tests (with short timeouts)
check_postgres() {
    timeout 2 bash -c "echo >/dev/tcp/$POSTGRES_HOST/$POSTGRES_PORT" 2>/dev/null
}

check_ollama() {
    curl -s --max-time 2 "${OLLAMA_URL}/api/tags" &>/dev/null
}

check_tribunal() {
    [[ -f "$HOME/.claude/system-prompt.md" ]] && grep -qi "arbiter\|tribunal" "$HOME/.claude/system-prompt.md" 2>/dev/null
}

check_mcp() {
    [[ -f "$HOME/claude/personal/localhost/mcp/rag-server/supervisor.py" ]]
}

# Run checks
RAG_OK=false; check_postgres && RAG_OK=true
OLLAMA_OK=false; check_ollama && OLLAMA_OK=true
TRIBUNAL_OK=false; check_tribunal && TRIBUNAL_OK=true
MCP_OK=false; check_mcp && MCP_OK=true

# Count
TOTAL=4
HEALTHY=0
$RAG_OK && ((HEALTHY++))
$OLLAMA_OK && ((HEALTHY++))
$TRIBUNAL_OK && ((HEALTHY++))
$MCP_OK && ((HEALTHY++))

# Display status line
icon_ok="${GREEN}✓${NC}"
icon_fail="${RED}✗${NC}"

printf "${CYAN}Health:${NC} "
$RAG_OK && printf "RAG${icon_ok} " || printf "RAG${icon_fail} "
$OLLAMA_OK && printf "Ollama${icon_ok} " || printf "Ollama${icon_fail} "
$TRIBUNAL_OK && printf "Tribunal${icon_ok} " || printf "Tribunal${icon_fail} "
$MCP_OK && printf "MCP${icon_ok} " || printf "MCP${icon_fail} "

if [[ $HEALTHY -eq $TOTAL ]]; then
    printf "${GREEN}[ALL OK]${NC}\n"
else
    printf "${YELLOW}[$HEALTHY/$TOTAL]${NC}\n"
    # Show warnings for failures
    $RAG_OK || printf "  ${RED}⚠${NC} RAG database unreachable ($POSTGRES_HOST:$POSTGRES_PORT)\n"
    $OLLAMA_OK || printf "  ${RED}⚠${NC} Ollama unreachable ($OLLAMA_URL)\n"
    $TRIBUNAL_OK || printf "  ${RED}⚠${NC} Tribunal identity not configured\n"
    $MCP_OK || printf "  ${RED}⚠${NC} MCP server not configured\n"
fi

echo ""

# =============================================================================
# LAUNCH CLAUDE
# =============================================================================

exec claude \
    --append-system-prompt-file ~/.claude/system-prompt.md \
    --dangerously-skip-permissions \
    "$@"
