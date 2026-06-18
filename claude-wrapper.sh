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
#   --sonnet:       Sonnet 4 (claude-sonnet-4-6) for bounded tasks
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
        [anthropic]="claude-sonnet-4-6"
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
            mkdir -p "$HOME/.arbiter/logs" 2>/dev/null
            echo "{\"ts\":\"$(date -Iseconds)\",\"event\":\"sonnet_downgrade\",\"provider\":\"$PROVIDER\",\"project_path\":\"$PWD\",\"args\":\"$*\"}" >> "$HOME/.arbiter/logs/model-downgrades.jsonl" 2>/dev/null || true
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
        --detect-only)
            DETECT_ONLY=1
            shift
            ;;
        --profile)
            if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
                CLI_PROFILE="$2"
                shift 2
            else
                echo "Error: --profile requires a profile name" >&2
                exit 1
            fi
            ;;
        --profile=*)
            CLI_PROFILE="${1#*=}"
            shift
            ;;
        *)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
    esac
done

# =============================================================================
# Phase 1b: Active-profile resolution (priority: --profile > $ARBITER_PROFILE > ~/.arbiter/active-profile)
#
# Profile-supplied defaults (provider, model) apply only when the caller did
# NOT explicitly override them on the CLI. Profile is a fallback layer, not
# a forced layer.
#
# Falls back gracefully when ~/Development/arbiter/lib/ is absent (e.g. on
# a host that hasn't bootstrapped the new layout yet).
# =============================================================================

ARBITER_PROFILE_RESOLVED=""
ARBITER_PROFILE_PATH=""
if [[ -f "$HOME/Development/arbiter/lib/profile.sh" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/Development/arbiter/lib/profile.sh"
    ARBITER_PROFILE_RESOLVED=$(arbiter_resolve_profile "${CLI_PROFILE:-}" 2>/dev/null || echo "")
    if [[ -n "$ARBITER_PROFILE_RESOLVED" ]]; then
        ARBITER_PROFILE_PATH=$(arbiter_profile_path "$ARBITER_PROFILE_RESOLVED")
        if [[ ! -f "$ARBITER_PROFILE_PATH" ]]; then
            echo "Error: active profile '$ARBITER_PROFILE_RESOLVED' not found at $ARBITER_PROFILE_PATH" >&2
            echo "       See available profiles:" >&2
            ls "$HOME/.arbiter/profiles/" 2>/dev/null | sed 's/\.toml$//; s/^/         /' >&2 || echo "         (none)" >&2
            echo "       Switch with: ARBITER_PROFILE=<name> arbiter ..." >&2
            exit 1
        fi
        # Validate before consuming (fail closed on schema violation)
        if ! arbiter_validate_profile "$ARBITER_PROFILE_PATH" >/dev/null 2>&1; then
            echo "Error: profile '$ARBITER_PROFILE_RESOLVED' fails validation. Run:" >&2
            echo "       arbiter-profile validate $ARBITER_PROFILE_RESOLVED" >&2
            exit 1
        fi
        # Apply profile-supplied defaults
        if [[ "${_PROVIDER_EXPLICIT:-0}" != "1" ]]; then
            profile_provider=$(arbiter_profile_field "$ARBITER_PROFILE_PATH" default_provider 2>/dev/null)
            [[ -n "$profile_provider" ]] && PROVIDER="$profile_provider"
        fi
        if [[ -z "$SELECTED_MODEL" ]]; then
            profile_model=$(arbiter_profile_field "$ARBITER_PROFILE_PATH" default_model 2>/dev/null)
            [[ -n "$profile_model" ]] && SELECTED_MODEL="$profile_model"
        fi
        # Export for subagent inheritance + hooks self-skip
        export ARBITER_PROFILE="$ARBITER_PROFILE_RESOLVED"
        ARBITER_DISABLED_HOOKS=$(arbiter_profile_field "$ARBITER_PROFILE_PATH" disabled_hooks 2>/dev/null | tr '\n' ',')
        [[ -n "$ARBITER_DISABLED_HOOKS" ]] && export ARBITER_DISABLED_HOOKS
    fi
fi

# Legacy fallback (transition): if no profile resolved, consult projects.yaml.
# Will be removed in Phase 1d after the deprecation window.
if [[ -z "$ARBITER_PROFILE_RESOLVED" && "${_PROVIDER_EXPLICIT:-0}" != "1" ]]; then
    auto_provider=$(auto_provider_from_projects_yaml)
    if [[ -n "$auto_provider" ]]; then
        PROVIDER="$auto_provider"
        echo "[wrapper] using per-project provider from projects.yaml: $PROVIDER" >&2
    fi
fi

# =============================================================================
# CWD hint warning (design §5.4)
#
# If $PWD matches a projects.yaml entry whose `company` differs from the
# active profile's write_entity, emit a one-shot warning per (profile, cwd)
# per day. Source of truth is the profile; this is a foot-shoot guard, not
# a determination.
# =============================================================================

if [[ -n "$ARBITER_PROFILE_RESOLVED" ]] && [[ -n "$ARBITER_PROFILE_PATH" ]] && [[ -f "$HOME/.claude/projects.yaml" ]]; then
    # Iterate projects.yaml entries; pick the longest-prefix match against $PWD.
    # Python+PyYAML: Go-yq v4 chokes on `[…, .value.company // ""] | @tsv` (bad expression).
    cwd_hint_entity=$(python3 - "$HOME/.claude/projects.yaml" "$PWD" "$HOME" <<'PYEOF'
import os, sys, yaml
projects_yaml, pwd, home = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = yaml.safe_load(open(projects_yaml))
except Exception:
    sys.exit(0)
best_len = 0
best_company = ""
for name, proj in (d.get("projects") or {}).items():
    if not isinstance(proj, dict):
        continue
    p = proj.get("path") or ""
    c = proj.get("company") or ""
    if not p or not c:
        continue
    expanded = p.replace("~", home, 1) if p.startswith("~") else p
    if pwd == expanded or pwd.startswith(expanded.rstrip("/") + "/"):
        if len(expanded) > best_len:
            best_len = len(expanded)
            best_company = c
print(best_company)
PYEOF
)

    if [[ -n "$cwd_hint_entity" ]]; then
        profile_write_entity=$(arbiter_profile_field "$ARBITER_PROFILE_PATH" write_entity 2>/dev/null)
        if [[ "$cwd_hint_entity" != "$profile_write_entity" ]]; then
            CWD_WARN_DIR="$ARBITER_HOME/cache/cwd-warnings"
            mkdir -p "$CWD_WARN_DIR" 2>/dev/null
            warn_key=$(echo "${ARBITER_PROFILE_RESOLVED}:${PWD}" | sha1sum | cut -d' ' -f1)
            warn_sentinel="$CWD_WARN_DIR/$warn_key"
            today=$(date +%Y-%m-%d)
            last_warned=""
            [[ -f "$warn_sentinel" ]] && last_warned=$(date -d "@$(stat -c %Y "$warn_sentinel")" +%Y-%m-%d 2>/dev/null)
            if [[ "$last_warned" != "$today" ]]; then
                echo "" >&2
                echo "[arbiter] current dir hints entity '$cwd_hint_entity' but active profile" >&2
                echo "          '$ARBITER_PROFILE_RESOLVED' writes to '$profile_write_entity'." >&2
                echo "          Override for this command: arbiter --profile <name> ..." >&2
                touch "$warn_sentinel"
            fi
        fi
    fi
fi

# Validate provider (known providers, not dependent on model config)
VALID_PROVIDERS="anthropic copilot ollama openai"
if [[ ! " $VALID_PROVIDERS " =~ " $PROVIDER " ]]; then
    echo "Error: Unknown provider '$PROVIDER'. Valid: $VALID_PROVIDERS" >&2
    exit 1
fi

# =============================================================================
# V15-Phase-2 failover + telemetry
# =============================================================================

# Health probe for Copilot endpoint -- fall back to anthropic if it's unreachable.
# Only applies when the operator did NOT pass --provider explicitly; an explicit
# request stays explicit even if the endpoint is sick (lets the operator force
# the failure surface).
if [[ "$PROVIDER" == "copilot" && "${_PROVIDER_EXPLICIT:-0}" != "1" ]]; then
    if ! curl -fsS --max-time 4 -o /dev/null "${COPILOT_URL:-}" 2>/dev/null; then
        echo "[wrapper] copilot endpoint unreachable -- failing over to anthropic" >&2
        FAILED_PROVIDER="$PROVIDER"
        PROVIDER="anthropic"
        TELEMETRY_FAILOVER=1
    fi
fi

# Generate a session id used to correlate start + end records.
# Telemetry log location: prefer ~/.arbiter/logs/ (Phase 0+), fall back to
# legacy ~/.claude/ for callers that explicitly set LLM_USAGE_LOG.
TELEMETRY_SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s%3N)-$$}"
TELEMETRY_LOG="${LLM_USAGE_LOG:-$HOME/.arbiter/logs/llm-usage.jsonl}"
mkdir -p "$(dirname "$TELEMETRY_LOG")" 2>/dev/null || true
TELEMETRY_START_TS=$(date +%s)

# Resolve entity for the current project from projects.yaml (best-effort)
TELEMETRY_ENTITY=""
if [[ -f "$HOME/.claude/projects.yaml" ]] && command -v yq &>/dev/null; then
    TELEMETRY_ENTITY=$(yq -r --arg p "$PWD"         '.projects | to_entries[] | select($p | startswith(.value.path | sub("^~"; env(HOME)))) | .value.entity // ""'         "$HOME/.claude/projects.yaml" 2>/dev/null | head -1)
fi

# Emit session-start event
{
    printf '{"session_id":"%s","event_type":"start","provider":"%s","occurred_at":"%s","project_path":"%s","entity":"%s","metadata":{"failover":%s,"failed_provider":"%s"}}
'         "$TELEMETRY_SESSION_ID"         "$PROVIDER"         "$(date -Iseconds)"         "$PWD"         "$TELEMETRY_ENTITY"         "${TELEMETRY_FAILOVER:-false}"         "${FAILED_PROVIDER:-}"
} >> "$TELEMETRY_LOG" 2>/dev/null || true

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
# PRE-LAUNCH FEATURE DETECTION (Phase 0)
#
# Each optional capability self-checks its prerequisites. Missing prereqs
# cause silent degradation (no stderr spam) plus a structured record in
# ~/.arbiter/feature-detection.jsonl. The only hard requirement is `claude`
# itself.
#
# See: arbiter/personal/localhost/docs/architecture/arbiter-profile-system.md §5.5
# =============================================================================

# Arbiter runtime tree
ARBITER_HOME="${ARBITER_HOME:-$HOME/.arbiter}"
FEATURE_LOG="$ARBITER_HOME/feature-detection.jsonl"
mkdir -p "$ARBITER_HOME/logs" 2>/dev/null || true

# Source rag-mcp env file if present. Missing file is now OK — was a hard
# exit pre-Phase-0. POSTGRES_PASSWORD becomes a feature flag, not a gate.
if [[ -f "$HOME/.config/rag-mcp/env" ]]; then
    POSTGRES_PASSWORD=$(awk -F= '/^POSTGRES_PASSWORD=/{sub(/^POSTGRES_PASSWORD=/,"",$0); print; exit}' "$HOME/.config/rag-mcp/env")
    [[ -n "$POSTGRES_PASSWORD" ]] && export POSTGRES_PASSWORD
fi

# Defaults (set unconditionally; absence is feature-detected below)
POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"
OLLAMA_URL="${OLLAMA_URL:-http://10.0.4.10:11434}"
export POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_DB OLLAMA_URL

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Append a structured detection record to feature-detection.jsonl
record_feature() {
    local name="$1" status="$2" reason="${3:-}"
    printf '{"ts":"%s","feature":"%s","status":"%s","reason":"%s","host":"%s","pid":%d,"session":"%s"}\n' \
        "$(date -Iseconds)" "$name" "$status" "$reason" "${HOSTNAME:-unknown}" "$$" "${TELEMETRY_SESSION_ID:-}" \
        >> "$FEATURE_LOG" 2>/dev/null || true
}

# --- Active profile (resolved earlier; record here for visibility) ---
if [[ -n "$ARBITER_PROFILE_RESOLVED" ]]; then
    record_feature "profile" "ok" "$ARBITER_PROFILE_RESOLVED"
else
    record_feature "profile" "skipped" "no active profile resolved (legacy projects.yaml fallback active)"
fi

# --- Hard requirement: claude CLI ---
if ! command -v claude >/dev/null 2>&1; then
    echo "Error: claude CLI not found in PATH. Install Claude Code first." >&2
    record_feature "claude_cli" "error" "binary not in PATH"
    exit 1
fi
record_feature "claude_cli" "ok" ""

# --- Optional features ---

# RAG MCP endpoint (the public Cloudflare-tunneled endpoint)
MCP_OK=false
mcp_url=""
if [[ -f "$HOME/.claude.json" ]]; then
    mcp_url=$(python3 -c "
import json, sys
try:
    d = json.load(open('$HOME/.claude.json'))
    url = d.get('mcpServers', {}).get('rag', {}).get('url', '')
    if url.endswith('/mcp'):
        print(url[:-4] + '/health')
    elif url:
        print(url + '/health')
except Exception:
    pass
" 2>/dev/null)
fi
if [[ -n "$mcp_url" ]] && curl -sf --max-time 3 -o /dev/null "$mcp_url" 2>/dev/null; then
    MCP_OK=true
    record_feature "rag_mcp" "ok" ""
elif [[ -n "$mcp_url" ]]; then
    record_feature "rag_mcp" "skipped" "endpoint unreachable: $mcp_url"
else
    record_feature "rag_mcp" "skipped" "no rag entry in ~/.claude.json mcpServers"
fi

# Ollama (local LLM provider)
OLLAMA_OK=false
if curl -sf --max-time 2 "${OLLAMA_URL}/api/tags" >/dev/null 2>&1; then
    OLLAMA_OK=true
    record_feature "ollama" "ok" ""
else
    record_feature "ollama" "skipped" "endpoint unreachable: $OLLAMA_URL"
fi

# Camelot PG (local hooks ship telemetry here)
PG_OK=false
if [[ -n "$POSTGRES_PASSWORD" ]]; then
    if timeout 2 bash -c "echo > /dev/tcp/$POSTGRES_HOST/$POSTGRES_PORT" 2>/dev/null; then
        PG_OK=true
        record_feature "pg_telemetry" "ok" ""
    else
        record_feature "pg_telemetry" "skipped" "PG unreachable at $POSTGRES_HOST:$POSTGRES_PORT"
    fi
else
    record_feature "pg_telemetry" "skipped" "POSTGRES_PASSWORD unset"
fi

# Atlas (Ansible-based infra automation)
ATLAS_OK=false
if command -v atlas >/dev/null 2>&1; then
    ATLAS_OK=true
    record_feature "atlas" "ok" ""
else
    record_feature "atlas" "skipped" "atlas binary not in PATH"
fi

# oc-atlantis (Atlantis OKD cluster CLI; alias in operator shell — checks
# the underlying prereqs: `oc` binary + atlantis kubeconfig file)
OC_OK=false
OC_KUBECONFIG="$HOME/arbiter/aegis/atlantis/kubeconfig"
if command -v oc >/dev/null 2>&1 && [[ -f "$OC_KUBECONFIG" ]]; then
    OC_OK=true
    record_feature "oc_atlantis" "ok" ""
elif ! command -v oc >/dev/null 2>&1; then
    record_feature "oc_atlantis" "skipped" "oc binary not in PATH"
else
    record_feature "oc_atlantis" "skipped" "kubeconfig not at $OC_KUBECONFIG"
fi

# RAG sync (systemd user services watching local filesystem)
SYNC_OK=false
if systemctl --user is-active rag-event-collector >/dev/null 2>&1; then
    SYNC_OK=true
    record_feature "rag_sync" "ok" ""
else
    record_feature "rag_sync" "skipped" "rag-event-collector.service inactive or missing"
fi

# Tribunal / conscience system prompt
TRIBUNAL_OK=false
if [[ -f "$HOME/.claude/system-prompt.md" ]] && grep -qi "arbiter\|tribunal" "$HOME/.claude/system-prompt.md" 2>/dev/null; then
    TRIBUNAL_OK=true
    record_feature "tribunal" "ok" ""
else
    record_feature "tribunal" "skipped" "system-prompt.md missing or no arbiter/tribunal section"
fi

# yq (used by providers.yaml and projects.yaml parsing)
YQ_OK=false
if command -v yq >/dev/null 2>&1; then
    YQ_OK=true
    record_feature "yq" "ok" ""
else
    record_feature "yq" "skipped" "yq binary not in PATH (sed fallback active)"
fi

# --- Display ---
TOTAL=8
HEALTHY=0
$MCP_OK && ((HEALTHY++))
$OLLAMA_OK && ((HEALTHY++))
$PG_OK && ((HEALTHY++))
$ATLAS_OK && ((HEALTHY++))
$OC_OK && ((HEALTHY++))
$SYNC_OK && ((HEALTHY++))
$TRIBUNAL_OK && ((HEALTHY++))
$YQ_OK && ((HEALTHY++))

printf "${CYAN}Features:${NC} "
$MCP_OK      && printf "MCP${GREEN}✓${NC} "      || printf "MCP${YELLOW}—${NC} "
$OLLAMA_OK   && printf "Ollama${GREEN}✓${NC} "   || printf "Ollama${YELLOW}—${NC} "
$PG_OK       && printf "PG${GREEN}✓${NC} "       || printf "PG${YELLOW}—${NC} "
$ATLAS_OK    && printf "Atlas${GREEN}✓${NC} "    || printf "Atlas${YELLOW}—${NC} "
$OC_OK       && printf "OC${GREEN}✓${NC} "       || printf "OC${YELLOW}—${NC} "
$SYNC_OK     && printf "Sync${GREEN}✓${NC} "     || printf "Sync${YELLOW}—${NC} "
$TRIBUNAL_OK && printf "Tribunal${GREEN}✓${NC} " || printf "Tribunal${YELLOW}—${NC} "
$YQ_OK       && printf "yq${GREEN}✓${NC} "       || printf "yq${YELLOW}—${NC} "

if [[ $HEALTHY -eq $TOTAL ]]; then
    printf "${GREEN}[ALL ACTIVE]${NC}\n"
else
    printf "${YELLOW}[$HEALTHY/$TOTAL active]${NC}\n"
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

# Add profile-specific overlay if the active profile sets one
if [[ -n "$ARBITER_PROFILE_PATH" ]]; then
    profile_overlay=$(arbiter_profile_field "$ARBITER_PROFILE_PATH" system_prompt_overlay 2>/dev/null)
    if [[ -n "$profile_overlay" ]]; then
        # Expand ~
        profile_overlay="${profile_overlay/#\~/$HOME}"
        if [[ -f "$profile_overlay" ]]; then
            SYSTEM_PROMPT_ARGS+=(--append-system-prompt-file "$profile_overlay")
        else
            echo "[arbiter] warning: profile system_prompt_overlay points at missing file: $profile_overlay" >&2
        fi
    fi
fi

# Build model args (only if explicitly set)
MODEL_ARGS=()
if [[ -n "$SELECTED_MODEL" ]]; then
    MODEL_ARGS=(--model "$SELECTED_MODEL")
fi

# --detect-only: bail before launching claude. Used by tests and the future
# `arbiter doctor` command.
if [[ "${DETECT_ONLY:-0}" == "1" ]]; then
    echo ""
    echo "Feature detection log: $FEATURE_LOG"
    echo "Records from this launch (profile + claude_cli + $TOTAL optional):"
    # +2 for profile and claude_cli records, which are above the optional-feature block
    tail -n $((TOTAL + 2)) "$FEATURE_LOG" 2>/dev/null | sed 's/^/  /'
    exit 0
fi

claude \
    "${MODEL_ARGS[@]}" \
    "${SYSTEM_PROMPT_ARGS[@]}" \
    --dangerously-skip-permissions \
    "${PASSTHROUGH_ARGS[@]}"
exit_code=$?

# V15-Phase-2 telemetry: session-end event
{
    TELEMETRY_END_TS=$(date +%s)
    TELEMETRY_DURATION=$((TELEMETRY_END_TS - TELEMETRY_START_TS))
    EVENT_TYPE="end"
    [[ "$exit_code" -ne 0 ]] && EVENT_TYPE="error"
    printf '{"session_id":"%s","event_type":"%s","provider":"%s","occurred_at":"%s","project_path":"%s","entity":"%s","duration_seconds":%d,"exit_code":%d}\n' \
        "$TELEMETRY_SESSION_ID" \
        "$EVENT_TYPE" \
        "$PROVIDER" \
        "$(date -Iseconds)" \
        "$PWD" \
        "$TELEMETRY_ENTITY" \
        "$TELEMETRY_DURATION" \
        "$exit_code"
} >> "$TELEMETRY_LOG" 2>/dev/null || true

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
