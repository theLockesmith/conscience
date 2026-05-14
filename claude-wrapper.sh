#!/bin/bash
# Claude Code wrapper that includes the system prompt and default flags
# Usage: Replace 'claude' with this script, or alias claude to this
#
# Includes:
#   Pre-launch health check: Verifies RAG, MCP, Tribunal connectivity
#   --append-system-prompt-file: Integrity/conscience-driven behavioral prompt
#   --dangerously-skip-permissions: Skip permission prompts (hooks enforce safety)
#   Default model: Opus (V11 experiment concluded: Sonnet lacks self-correction)
#
# Model selection:
#   Default:        Upstream default (no override)
#   --sonnet:       Sonnet 4 (claude-sonnet-4-20250514) for bounded tasks
#   --model <name>: Any model
#
# Provider selection:
#   Default:          anthropic (Max plan, native)
#   --provider copilot:  GitHub Copilot / Azure OpenAI
#   --provider ollama:   Local Ollama instance
#   --provider openai:   OpenAI API directly
#
# All additional flags are passed through to claude

# =============================================================================
# PROVIDER & MODEL CONFIGURATION
# =============================================================================

# Load provider configuration from YAML file
load_provider_config() {
    local config_file="$HOME/.claude/providers.yaml"

    # Initialize defaults if config file doesn't exist
    if [[ ! -f "$config_file" ]]; then
        echo "Warning: providers.yaml not found, using hardcoded defaults" >&2
        return 1
    fi

    # Use yq if available (preferred), otherwise fall back to sed parsing
    if command -v yq &>/dev/null; then
        # yq-based parsing (reliable)
        local providers
        providers=$(yq -r '.providers | keys | .[]' "$config_file" 2>/dev/null)

        for provider in $providers; do
            local default_model sonnet_model url_val
            default_model=$(yq -r ".providers.${provider}.models.default // \"\"" "$config_file" 2>/dev/null)
            sonnet_model=$(yq -r ".providers.${provider}.models.sonnet // \"\"" "$config_file" 2>/dev/null)
            url_val=$(yq -r ".providers.${provider}.url // \"\"" "$config_file" 2>/dev/null)

            [[ -n "$default_model" ]] && PROVIDER_DEFAULT_MODEL[$provider]="$default_model"
            [[ -n "$sonnet_model" ]] && PROVIDER_SONNET_MODEL[$provider]="$sonnet_model"

            # Handle URL with env var expansion
            if [[ -n "$url_val" && "$url_val" != "null" ]]; then
                # Expand ${VAR} references
                if [[ "$url_val" =~ \$\{([^}]+)\} ]]; then
                    local var_name="${BASH_REMATCH[1]}"
                    url_val="${!var_name:-}"
                fi
                case "$provider" in
                    ollama) [[ -n "$url_val" ]] && OLLAMA_URL="$url_val" ;;
                    openai) [[ -n "$url_val" ]] && OPENAI_URL="$url_val" ;;
                    copilot) [[ -n "$url_val" ]] && COPILOT_URL="$url_val" ;;
                esac
            fi
        done
    else
        # Fallback: sed-based extraction (simpler but less robust)
        # Extract provider blocks and parse with sed
        while read -r provider; do
            [[ -z "$provider" ]] && continue
            local default_model sonnet_model
            default_model=$(sed -n "/^  ${provider}:/,/^  [a-z]/{ /default:/s/.*default: *\"\([^\"]*\)\".*/\1/p }" "$config_file" | head -1)
            sonnet_model=$(sed -n "/^  ${provider}:/,/^  [a-z]/{ /sonnet:/s/.*sonnet: *\"\([^\"]*\)\".*/\1/p }" "$config_file" | head -1)

            [[ -n "$default_model" ]] && PROVIDER_DEFAULT_MODEL[$provider]="$default_model"
            [[ -n "$sonnet_model" ]] && PROVIDER_SONNET_MODEL[$provider]="$sonnet_model"
        done < <(grep -E '^ {2}[a-z]+:$' "$config_file" | sed 's/^ *//; s/:$//')
    fi
}


# Detect current-project's default_provider from ~/.claude/projects.yaml
# (V15 Phase 2 — per-project Copilot routing for Empire-tenant work).
# Only consulted when the user did NOT explicitly pass --provider on the CLI.
auto_provider_from_projects_yaml() {
    local cfg="$HOME/.claude/projects.yaml"
    [[ ! -f "$cfg" ]] && return
    command -v yq >/dev/null 2>&1 || return
    local cwd="$PWD"
    # Resolve cwd against each project's path; pick the longest-prefix match.
    local best_match_len=0
    local best_provider=""
    while IFS=$'\t' read -r name path provider; do
        [[ -z "$provider" || "$provider" == "null" ]] && continue
        local expanded="${path/#\~/$HOME}"
        if [[ "$cwd" == "$expanded"* ]] && [[ ${#expanded} -gt $best_match_len ]]; then
            best_match_len=${#expanded}
            best_provider="$provider"
        fi
    done < <(yq -r '.projects | to_entries[] | [.key, .value.path, .value.default_provider // ""] | @tsv' "$cfg" 2>/dev/null)
    [[ -n "$best_provider" ]] && echo "$best_provider"
}

# Provider defaults
PROVIDER="anthropic"
OLLAMA_URL="${OLLAMA_URL:-http://10.0.4.10:11434}"
COPILOT_URL="${COPILOT_URL:-}"
OPENAI_URL="${OPENAI_URL:-https://api.openai.com/v1}"

# Model configuration arrays
declare -A PROVIDER_DEFAULT_MODEL
declare -A PROVIDER_OPUS_MODEL

# Load configuration from YAML file, with fallback to hardcoded values
if ! load_provider_config; then
    # Hardcoded fallback configuration
    # Anthropic: Use upstream default (no override)
    # Other providers: Need explicit model since they may not have defaults
    PROVIDER_DEFAULT_MODEL=(
        [anthropic]=""
        [copilot]="gpt-4o"
        [ollama]="llama3.2:70b"
        [openai]="gpt-4o"
    )
    PROVIDER_SONNET_MODEL=(
        [anthropic]="claude-sonnet-4-20250514"
        [copilot]="gpt-4o"      # Copilot doesn't have tier equivalent
        [ollama]="llama3.2:3b"  # Lighter model for bounded tasks
        [openai]="gpt-4o-mini"
    )
fi

SELECTED_MODEL=""
USE_SONNET=false

# Parse arguments for model/provider flags (consume them, pass rest to claude)
PASSTHROUGH_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sonnet)
            USE_SONNET=true
            # Log downgrade for analysis (V11 hybrid routing)
            echo "{\"ts\":\"$(date -Iseconds)\",\"event\":\"sonnet_downgrade\",\"provider\":\"$PROVIDER\",\"project_path\":\"$PWD\",\"args\":\"$*\"}" >> "$HOME/.claude/model-downgrades.jsonl"
            shift
            ;;
        --opus)
            # Opus is now default, --opus is a no-op but kept for compatibility
            shift
            ;;
        --provider)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                PROVIDER="$2"
                _PROVIDER_EXPLICIT=1
                shift 2
            else
                echo "Error: --provider requires a name (anthropic, copilot, ollama, openai)" >&2
                exit 1
            fi
            ;;
        --provider=*)
            PROVIDER="${1#*=}"
            _PROVIDER_EXPLICIT=1
            shift
            ;;
        --model)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                SELECTED_MODEL="$2"
                shift 2
            else
                echo "Error: --model requires a model name" >&2
                exit 1
            fi
            ;;
        --model=*)
            SELECTED_MODEL="${1#*=}"
            shift
            ;;
        *)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
    esac
done

# V15 Phase 2: if no explicit --provider, consult projects.yaml for current project
if [[ "${_PROVIDER_EXPLICIT:-0}" != "1" ]]; then
    auto_provider=$(auto_provider_from_projects_yaml)
    if [[ -n "$auto_provider" ]]; then
        PROVIDER="$auto_provider"
        echo "[wrapper] using per-project provider from projects.yaml: $PROVIDER" >&2
    fi
fi

# Validate provider (known providers, not dependent on model config)
VALID_PROVIDERS="anthropic copilot ollama openai"
if [[ ! " $VALID_PROVIDERS " =~ " $PROVIDER " ]]; then
    echo "Error: Unknown provider '$PROVIDER'. Valid: $VALID_PROVIDERS" >&2
    exit 1
fi

# Set model based on provider and flags
if [[ -z "$SELECTED_MODEL" ]]; then
    if $USE_SONNET; then
        SELECTED_MODEL="${PROVIDER_SONNET_MODEL[$PROVIDER]}"
    else
        SELECTED_MODEL="${PROVIDER_DEFAULT_MODEL[$PROVIDER]}"
    fi
fi

# =============================================================================
# PROVIDER ENVIRONMENT SETUP
# =============================================================================

case "$PROVIDER" in
    anthropic)
        # Native Anthropic - no env changes needed (uses Max plan)
        unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
        ;;
    copilot)
        if [[ -z "$COPILOT_API_KEY" ]]; then
            echo "Error: COPILOT_API_KEY environment variable required for --provider copilot" >&2
            exit 1
        fi
        if [[ -z "$COPILOT_URL" ]]; then
            echo "Error: COPILOT_URL environment variable required for --provider copilot" >&2
            exit 1
        fi
        export ANTHROPIC_BASE_URL="$COPILOT_URL"
        export ANTHROPIC_API_KEY="$COPILOT_API_KEY"
        ;;
    ollama)
        export ANTHROPIC_BASE_URL="$OLLAMA_URL"
        export ANTHROPIC_AUTH_TOKEN="ollama"
        export ANTHROPIC_API_KEY=""
        ;;
    openai)
        if [[ -z "$OPENAI_API_KEY" ]]; then
            echo "Error: OPENAI_API_KEY environment variable required for --provider openai" >&2
            exit 1
        fi
        export ANTHROPIC_BASE_URL="$OPENAI_URL"
        export ANTHROPIC_API_KEY="$OPENAI_API_KEY"
        ;;
esac

# =============================================================================
# PRE-LAUNCH HEALTH CHECK
# =============================================================================

# Source the rag-mcp env file (managed by atlas postgres-rotate-rag-mcp role).
# Provides POSTGRES_PASSWORD and any other rotated credentials. Missing file
# is OK if POSTGRES_PASSWORD is already in the environment.
if [[ -f "$HOME/.config/rag-mcp/env" ]]; then POSTGRES_PASSWORD=$(awk -F= '/^POSTGRES_PASSWORD=/{sub(/^POSTGRES_PASSWORD=/,"",$0); print; exit}' "$HOME/.config/rag-mcp/env"); export POSTGRES_PASSWORD; fi
if false; then
    set -a
    # shellcheck disable=SC1091
    . "$HOME/.config/rag-mcp/env"
    set +a
fi

# Configuration
POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD env var required (vault it in roles/kube/rag-mcp-server/vars/main.yml then run atlas playbook rotate-rag-mcp-postgres-password)}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"
OLLAMA_URL="${OLLAMA_URL:-http://10.0.4.10:11434}"

# Export for MCP server
export POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB

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

# Show provider and model selection
if [[ "$PROVIDER" == "anthropic" ]]; then
    PROVIDER_DISPLAY="${GREEN}Anthropic${NC}"
else
    PROVIDER_DISPLAY="${YELLOW}${PROVIDER}${NC}"
fi
printf "${CYAN}Provider:${NC} $PROVIDER_DISPLAY"

# Model display
if $USE_SONNET && [[ "$PROVIDER" == "anthropic" ]]; then
    printf " | ${CYAN}Model:${NC} ${YELLOW}Sonnet 4${NC} (bounded tasks)\n"
elif [[ -z "$SELECTED_MODEL" ]]; then
    printf " | ${CYAN}Model:${NC} ${GREEN}upstream default${NC}\n"
elif [[ "$SELECTED_MODEL" == "${PROVIDER_DEFAULT_MODEL[$PROVIDER]}" ]]; then
    printf " | ${CYAN}Model:${NC} ${GREEN}$SELECTED_MODEL${NC} (default)\n"
else
    printf " | ${CYAN}Model:${NC} ${YELLOW}$SELECTED_MODEL${NC}\n"
fi

echo ""

# =============================================================================
# LAUNCH CLAUDE
# =============================================================================

# Build system prompt file list (base + provider-specific overlay)
SYSTEM_PROMPT_ARGS=(--append-system-prompt-file ~/.claude/system-prompt.md)

# Add provider-specific overlay if it exists
PROVIDER_PROMPT="$HOME/.claude/system-prompt-${PROVIDER}.md"
if [[ -f "$PROVIDER_PROMPT" ]]; then
    SYSTEM_PROMPT_ARGS+=(--append-system-prompt-file "$PROVIDER_PROMPT")
fi

# Build model args (only if explicitly set)
MODEL_ARGS=()
if [[ -n "$SELECTED_MODEL" ]]; then
    MODEL_ARGS=(--model "$SELECTED_MODEL")
fi

claude \
    "${MODEL_ARGS[@]}" \
    "${SYSTEM_PROMPT_ARGS[@]}" \
    --dangerously-skip-permissions \
    "${PASSTHROUGH_ARGS[@]}"
exit_code=$?

# =============================================================================
# TERMINAL RESET (fixes TUI corruption with tmux aggressive-resize)
# =============================================================================

printf '\033[?1049l'  # Exit alternate screen buffer (in case it wasn't restored)
printf '\033[r'       # Reset scrolling region to full screen (DECSTBM)
printf '\033[?25h'    # Show cursor
printf '\033[0m'      # Reset attributes
printf '\033[H\033[J' # Move to home position and clear screen
stty sane 2>/dev/null # Reset terminal settings

exit $exit_code
