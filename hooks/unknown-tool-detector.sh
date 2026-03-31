#!/bin/bash
# Unknown Sensitive Tool Detector (with Heuristic Detection)
# Location: ~/.claude/hooks/unknown-tool-detector.sh
# Hook type: PreToolUse (for Bash tool)
#
# PURPOSE: Detects sensitive tools via two methods:
#   1. Explicit patterns (known wallet/cloud CLIs)
#   2. Heuristic detection (analyzes --help output for dangerous keywords)
#
# This catches NEW tools automatically without maintaining a complete list.

set -uo pipefail

CONFIG_FILE="$HOME/.claude/security/config.yml"
TOOLS_FILE="$HOME/.claude/security/tools.yml"
CACHE_DIR="$HOME/.claude/security/tool-cache"
CACHE_TTL=86400  # 24 hours

# Ensure cache directory exists
mkdir -p "$CACHE_DIR" 2>/dev/null

# Read input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only apply to Bash tool
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

# Extract command
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

# Get just the first word (the CLI tool being invoked)
FIRST_WORD=$(echo "$COMMAND" | awk '{print $1}' | sed 's|.*/||')  # strip path

# Skip common safe tools (performance optimization)
SAFE_TOOLS="ls|cd|pwd|cat|grep|find|head|tail|wc|sort|uniq|diff|echo|printf|test|true|false|sleep|date|whoami|hostname|uname|env|which|type|file|stat|touch|mkdir|rmdir|cp|mv|rm|ln|chmod|chown|tar|gzip|gunzip|zip|unzip|curl|wget|ssh|scp|rsync|git|docker|podman|kubectl|oc|helm|make|npm|yarn|pnpm|node|python|python3|pip|go|cargo|rustc|java|javac|mvn|gradle|systemctl|journalctl|ps|top|htop|kill|pkill|pgrep|df|du|free|lsblk|lsof|netstat|ss|ip|ping|dig|nslookup|jq|yq|sed|awk|xargs|tee|less|more|vim|nvim|nano|code"

if echo "$FIRST_WORD" | grep -qE "^($SAFE_TOOLS)$"; then
    exit 0
fi

# Check if tool is already configured in tools.yml
is_configured() {
    local tool="$1"
    [[ -f "$TOOLS_FILE" ]] && grep -qE "^[[:space:]]*${tool}:" "$TOOLS_FILE" 2>/dev/null
}

# Block with wallet warning
block_wallet() {
    local tool="$1"
    cat >&2 << EOF
BLOCKED: Tool detected as wallet/financial CLI via heuristic analysis.

Tool: $tool
Command: ${COMMAND:0:100}

The --help output contains keywords indicating this tool can:
- Send funds or transactions
- Manage private keys or wallets
- Sign messages or transactions

Before using this tool, add explicit allow/block rules to: $TOOLS_FILE

Example:
  $tool:
    allow:
      - "status"
      - "balance"
      - "list"
    block:
      - "send"
      - "transfer"
      - "sign"

Once configured, re-run the command.
EOF
    exit 2
}

# ============================================================================
# EXPLICIT PATTERN MATCHING (fast path for known tools)
# ============================================================================

# Known wallet CLIs - ALWAYS block unless configured
KNOWN_WALLET_PATTERN="lncli|bitcoin-cli|lightning-cli|cast|eth|solana|cardano-cli|monero-wallet-cli|electrum|trezorctl|ledger|ckb-cli|near|sui|aptos|flow"
if echo "$FIRST_WORD" | grep -qE "^($KNOWN_WALLET_PATTERN)$"; then
    if ! is_configured "$FIRST_WORD"; then
        block_wallet "$FIRST_WORD"
    fi
    # Configured, let it through (subcommand checking happens in enforce hook)
    exit 0
fi

# Known cloud CLIs - warn but allow
KNOWN_CLOUD_PATTERN="^(aws|gcloud|az|doctl|linode-cli|vultr-cli|hcloud|flyctl|railway|vercel|netlify)$"
if echo "$FIRST_WORD" | grep -qE "$KNOWN_CLOUD_PATTERN"; then
    if ! is_configured "$FIRST_WORD"; then
        echo "[WARN] Cloud CLI '$FIRST_WORD' not configured in tools.yml. Consider adding rules." >&2
        echo "[$(date -Iseconds)] UNCONFIGURED_CLOUD: $FIRST_WORD - $COMMAND" >> "$HOME/.claude/security/audit.log"
    fi
    exit 0
fi

# ============================================================================
# HEURISTIC DETECTION (for unknown tools)
# ============================================================================

# Check cache first
CACHE_FILE="$CACHE_DIR/${FIRST_WORD}.cache"
if [[ -f "$CACHE_FILE" ]]; then
    # Check if cache is fresh
    CACHE_AGE=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)))
    if [[ $CACHE_AGE -lt $CACHE_TTL ]]; then
        CACHED_RESULT=$(cat "$CACHE_FILE")
        case "$CACHED_RESULT" in
            "wallet")
                if ! is_configured "$FIRST_WORD"; then
                    block_wallet "$FIRST_WORD"
                fi
                ;;
            "cloud")
                if ! is_configured "$FIRST_WORD"; then
                    echo "[WARN] Tool '$FIRST_WORD' detected as cloud/infra CLI. Consider adding rules to tools.yml." >&2
                fi
                ;;
            # "safe" or other values pass through
        esac
        exit 0
    fi
fi

# Tool not in cache or cache expired - analyze it
# Only analyze if the tool exists
if ! command -v "$FIRST_WORD" &>/dev/null; then
    exit 0  # Tool doesn't exist, let bash handle the error
fi

# Get help output with timeout (some tools hang)
HELP_OUTPUT=$(timeout 2s "$FIRST_WORD" --help 2>&1 || timeout 2s "$FIRST_WORD" -h 2>&1 || timeout 2s "$FIRST_WORD" help 2>&1 || echo "")

# Wallet/financial keywords (high risk - block)
WALLET_KEYWORDS="wallet|send[[:space:]]+(funds|payment|transaction|coins|tokens)|transfer[[:space:]]+(funds|tokens)|private[[:space:]]?key|seed[[:space:]]?phrase|mnemonic|sign[[:space:]]+(transaction|message|tx)|broadcast[[:space:]]+(transaction|tx)|sweep|withdraw|deposit|stake|unstake|delegate|undelegate|claim[[:space:]]+(rewards|tokens)"

# Cloud/infra keywords (medium risk - warn)
CLOUD_KEYWORDS="(create|delete|terminate)[[:space:]]+(instance|server|vm|droplet|node)|deploy[[:space:]]+(app|service|function)|scale[[:space:]]+(up|down|out)|provision|deprovision"

# Analyze help output
DETECTED_TYPE="safe"

if echo "$HELP_OUTPUT" | grep -qiE "$WALLET_KEYWORDS"; then
    DETECTED_TYPE="wallet"
elif echo "$HELP_OUTPUT" | grep -qiE "$CLOUD_KEYWORDS"; then
    DETECTED_TYPE="cloud"
fi

# Cache the result
echo "$DETECTED_TYPE" > "$CACHE_FILE"

# Log detection
if [[ "$DETECTED_TYPE" != "safe" ]]; then
    echo "[$(date -Iseconds)] HEURISTIC_DETECT: $FIRST_WORD as $DETECTED_TYPE" >> "$HOME/.claude/security/audit.log"
fi

# Act on detection
case "$DETECTED_TYPE" in
    "wallet")
        if ! is_configured "$FIRST_WORD"; then
            block_wallet "$FIRST_WORD"
        fi
        ;;
    "cloud")
        if ! is_configured "$FIRST_WORD"; then
            echo "[WARN] Tool '$FIRST_WORD' detected as cloud/infra CLI via heuristic. Consider adding rules to tools.yml." >&2
        fi
        ;;
esac

exit 0
