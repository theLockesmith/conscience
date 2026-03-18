#!/bin/bash
# Sync enforcement blocks to RAG as learnings
# Closes the learning loop: blocks become persistent memory
#
# Reads quality-enforcement-metrics.jsonl, aggregates by category,
# and logs new blocks to RAG using rag-cli.py

set -uo pipefail

METRICS_FILE="$HOME/.claude/quality-enforcement-metrics.jsonl"
STATE_FILE="$HOME/.claude/metrics-state/blocks-synced.state"
RAG_CLI="$HOME/claude/personal/localhost/mcp/rag-server/rag-cli.py"
RAG_DIR="$HOME/claude/personal/localhost/mcp/rag-server"

# Database credentials (same as MCP server)
export POSTGRES_PASSWORD='PgH60TFewzAdbjRAomu1mtB3lmMWUoRKurm26pjS'
export POSTGRES_USER='rag'

mkdir -p "$(dirname "$STATE_FILE")"

# Get last synced line number
LAST_SYNCED=0
if [[ -f "$STATE_FILE" ]]; then
    LAST_SYNCED=$(cat "$STATE_FILE")
fi

# Count total lines
TOTAL_LINES=$(wc -l < "$METRICS_FILE" 2>/dev/null || echo 0)

if [[ "$TOTAL_LINES" -le "$LAST_SYNCED" ]]; then
    echo "No new blocks to sync (total: $TOTAL_LINES, synced: $LAST_SYNCED)"
    exit 0
fi

echo "Processing lines $((LAST_SYNCED + 1)) to $TOTAL_LINES..."

# Get new blocks only and aggregate by category
declare -A CATEGORY_COUNTS
declare -A CATEGORY_PATTERNS

while IFS= read -r line; do
    event=$(echo "$line" | jq -r '.event // empty')
    [[ "$event" != "blocked" ]] && continue

    category=$(echo "$line" | jq -r '.category // empty')
    pattern=$(echo "$line" | jq -r '.pattern // empty')

    if [[ -n "$category" && "$category" != "null" ]]; then
        CATEGORY_COUNTS[$category]=$((${CATEGORY_COUNTS[$category]:-0} + 1))
        # Keep track of patterns (last few)
        existing="${CATEGORY_PATTERNS[$category]:-}"
        if [[ -z "$existing" ]]; then
            CATEGORY_PATTERNS[$category]="$pattern"
        elif [[ ${#existing} -lt 150 ]]; then
            CATEGORY_PATTERNS[$category]="$existing, $pattern"
        fi
    fi
done < <(tail -n +"$((LAST_SYNCED + 1))" "$METRICS_FILE")

# Log each category with significant blocks to RAG
logged=0
for category in "${!CATEGORY_COUNTS[@]}"; do
    count=${CATEGORY_COUNTS[$category]}
    patterns=${CATEGORY_PATTERNS[$category]}

    # Only log if 2+ occurrences (reduces noise)
    if [[ $count -ge 2 ]]; then
        content="Quality enforcer blocked $count responses for '$category'. Trigger patterns: $patterns"
        context="Auto-synced from quality-enforcement-metrics.jsonl"
        tag_safe=$(echo "$category" | tr '[:upper:]' '[:lower:]' | tr ' /' '-')

        cd "$RAG_DIR" && uv run "$RAG_CLI" log-learning \
            --content "$content" \
            --category gotcha \
            --context "$context" \
            --project localhost \
            --tags "quality-enforcer,auto-logged,$tag_safe"

        echo "Logged: $category ($count blocks)"
        ((++logged))
    fi
done

# Update state
echo "$TOTAL_LINES" > "$STATE_FILE"
echo "Sync complete. Logged $logged categories from lines $((LAST_SYNCED + 1)) to $TOTAL_LINES"
