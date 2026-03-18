#!/bin/bash
# Quality Enforcer Metrics Aggregator
# Parses quality-enforcement-metrics.jsonl and provides insights

set -uo pipefail

METRICS_FILE="$HOME/.claude/quality-enforcement-metrics.jsonl"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
  summary       Show overall violation summary (default)
  categories    Show violations by category
  patterns      Show most common patterns triggering blocks
  escapes       Show most common escape hatches used
  timeline      Show violations over time (by day)
  recent        Show recent violations (last N, default 20)
  ship          Ship metrics to PostgreSQL (via rag-server)
  clear         Clear metrics file (with confirmation)

Options:
  -d, --days N    Filter to last N days (default: all)
  -n, --limit N   Limit output rows (default: 20)
  -j, --json      Output as JSON instead of formatted text
  -h, --help      Show this help

Examples:
  $0 summary -d 7        # Summary for last 7 days
  $0 categories          # All-time category breakdown
  $0 patterns -n 10      # Top 10 patterns
  $0 recent -n 50        # Last 50 violations
EOF
    exit 0
}

# Check if metrics file exists
check_metrics_file() {
    if [[ ! -f "$METRICS_FILE" ]]; then
        echo -e "${YELLOW}No metrics file found at $METRICS_FILE${NC}"
        echo "The quality enforcer will create this file when it blocks or escapes violations."
        exit 0
    fi

    if [[ ! -s "$METRICS_FILE" ]]; then
        echo -e "${YELLOW}Metrics file is empty${NC}"
        echo "No violations have been recorded yet."
        exit 0
    fi
}

# Filter by days if specified
apply_day_filter() {
    local days="$1"
    if [[ "$days" == "all" ]]; then
        cat
    else
        local cutoff
        cutoff=$(date -d "$days days ago" -Iseconds 2>/dev/null || date -v-${days}d -Iseconds)
        jq -c --arg cutoff "$cutoff" 'select(.timestamp >= $cutoff)'
    fi
}

cmd_summary() {
    local days="${1:-all}"
    local json="${2:-false}"

    check_metrics_file

    local total blocked escaped
    total=$(cat "$METRICS_FILE" | apply_day_filter "$days" | wc -l)
    blocked=$(cat "$METRICS_FILE" | apply_day_filter "$days" | jq -c 'select(.event == "blocked")' | wc -l)
    escaped=$(cat "$METRICS_FILE" | apply_day_filter "$days" | jq -c 'select(.event == "escaped")' | wc -l)

    if [[ "$json" == "true" ]]; then
        echo "{\"total_events\":$total,\"blocked\":$blocked,\"escaped\":$escaped,\"days\":\"$days\"}"
    else
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║     Quality Enforcer Metrics         ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
        [[ "$days" != "all" ]] && echo -e "${CYAN}║${NC} Period: Last $days days"
        echo -e "${CYAN}║${NC} Total Events:    ${YELLOW}$total${NC}"
        echo -e "${CYAN}║${NC} Blocked:         ${RED}$blocked${NC}"
        echo -e "${CYAN}║${NC} Escaped:         ${GREEN}$escaped${NC}"
        if [[ $total -gt 0 ]]; then
            local block_rate=$((blocked * 100 / total))
            echo -e "${CYAN}║${NC} Block Rate:      ${YELLOW}${block_rate}%${NC}"
        fi
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    fi
}

cmd_categories() {
    local days="${1:-all}"
    local limit="${2:-20}"
    local json="${3:-false}"

    check_metrics_file

    if [[ "$json" == "true" ]]; then
        cat "$METRICS_FILE" | apply_day_filter "$days" | \
            jq -c 'select(.event == "blocked")' | \
            jq -s 'group_by(.category) | map({category: .[0].category, count: length}) | sort_by(-.count)' | \
            jq ".[:$limit]"
    else
        echo -e "${CYAN}Violations by Category (blocked):${NC}"
        echo ""
        cat "$METRICS_FILE" | apply_day_filter "$days" | \
            jq -r 'select(.event == "blocked") | .category' | \
            sort | uniq -c | sort -rn | head -n "$limit" | \
            while read count category; do
                printf "  ${RED}%-25s${NC} %s\n" "$category" "$count"
            done

        echo ""
        echo -e "${CYAN}Escapes by Category:${NC}"
        echo ""
        cat "$METRICS_FILE" | apply_day_filter "$days" | \
            jq -r 'select(.event == "escaped") | .category' | \
            sort | uniq -c | sort -rn | head -n "$limit" | \
            while read count category; do
                printf "  ${GREEN}%-25s${NC} %s\n" "$category" "$count"
            done
    fi
}

cmd_patterns() {
    local days="${1:-all}"
    local limit="${2:-20}"
    local json="${3:-false}"

    check_metrics_file

    if [[ "$json" == "true" ]]; then
        cat "$METRICS_FILE" | apply_day_filter "$days" | \
            jq -c 'select(.event == "blocked")' | \
            jq -s 'group_by(.pattern) | map({pattern: .[0].pattern, category: .[0].category, count: length}) | sort_by(-.count)' | \
            jq ".[:$limit]"
    else
        echo -e "${CYAN}Most Common Blocking Patterns:${NC}"
        echo ""
        cat "$METRICS_FILE" | apply_day_filter "$days" | \
            jq -r 'select(.event == "blocked") | "\(.category)|\(.pattern)"' | \
            sort | uniq -c | sort -rn | head -n "$limit" | \
            while read count data; do
                category=$(echo "$data" | cut -d'|' -f1)
                pattern=$(echo "$data" | cut -d'|' -f2)
                printf "  ${RED}%3s${NC} %-15s %s\n" "$count" "[$category]" "$pattern"
            done
    fi
}

cmd_escapes() {
    local days="${1:-all}"
    local limit="${2:-20}"
    local json="${3:-false}"

    check_metrics_file

    if [[ "$json" == "true" ]]; then
        cat "$METRICS_FILE" | apply_day_filter "$days" | \
            jq -c 'select(.event == "escaped")' | \
            jq -s 'group_by(.escape_used) | map({escape: .[0].escape_used, category: .[0].category, count: length}) | sort_by(-.count)' | \
            jq ".[:$limit]"
    else
        echo -e "${CYAN}Most Common Escape Hatches Used:${NC}"
        echo ""
        cat "$METRICS_FILE" | apply_day_filter "$days" | \
            jq -r 'select(.event == "escaped") | "\(.category)|\(.escape_used)"' | \
            sort | uniq -c | sort -rn | head -n "$limit" | \
            while read count data; do
                category=$(echo "$data" | cut -d'|' -f1)
                escape=$(echo "$data" | cut -d'|' -f2)
                printf "  ${GREEN}%3s${NC} %-15s %s\n" "$count" "[$category]" "$escape"
            done
    fi
}

cmd_timeline() {
    local days="${1:-all}"
    local json="${2:-false}"

    check_metrics_file

    if [[ "$json" == "true" ]]; then
        cat "$METRICS_FILE" | apply_day_filter "$days" | \
            jq -r '.timestamp[:10]' | \
            sort | uniq -c | \
            jq -R 'split(" ") | {date: .[-1], count: (.[0] | tonumber)}' | \
            jq -s '.'
    else
        echo -e "${CYAN}Violations by Day:${NC}"
        echo ""
        cat "$METRICS_FILE" | apply_day_filter "$days" | \
            jq -r '.timestamp[:10]' | \
            sort | uniq -c | \
            while read count date; do
                printf "  %s: " "$date"
                # Simple bar chart
                local bars=$((count / 2))
                [[ $bars -lt 1 ]] && bars=1
                printf "${RED}"
                for ((i=0; i<bars; i++)); do printf "█"; done
                printf "${NC} %s\n" "$count"
            done
    fi
}

cmd_recent() {
    local limit="${1:-20}"
    local json="${2:-false}"

    check_metrics_file

    if [[ "$json" == "true" ]]; then
        tail -n "$limit" "$METRICS_FILE" | jq -s '.'
    else
        echo -e "${CYAN}Recent Violations (last $limit):${NC}"
        echo ""
        tail -n "$limit" "$METRICS_FILE" | \
            jq -r '"\(.timestamp[:19]) [\(.event)] \(.category): \(.pattern)"' | \
            while read line; do
                if echo "$line" | grep -q '\[blocked\]'; then
                    echo -e "  ${RED}$line${NC}"
                else
                    echo -e "  ${GREEN}$line${NC}"
                fi
            done
    fi
}

cmd_ship() {
    echo -e "${YELLOW}Shipping metrics to PostgreSQL...${NC}"

    # Check if we have the shipper script
    local shipper="$HOME/claude/personal/localhost/scripts/quality-metrics-shipper.sh"
    if [[ -x "$shipper" ]]; then
        "$shipper"
    else
        echo -e "${RED}Shipper script not found or not executable: $shipper${NC}"
        echo "Metrics shipping not configured."
        exit 1
    fi
}

cmd_clear() {
    echo -e "${YELLOW}This will clear all quality enforcement metrics.${NC}"
    read -p "Are you sure? (type 'yes' to confirm): " confirm
    if [[ "$confirm" == "yes" ]]; then
        > "$METRICS_FILE"
        echo -e "${GREEN}Metrics cleared.${NC}"
    else
        echo "Cancelled."
    fi
}

# Parse arguments
COMMAND="${1:-summary}"
shift || true

DAYS="all"
LIMIT="20"
JSON="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--days)
            DAYS="$2"
            shift 2
            ;;
        -n|--limit)
            LIMIT="$2"
            shift 2
            ;;
        -j|--json)
            JSON="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            shift
            ;;
    esac
done

case "$COMMAND" in
    summary)
        cmd_summary "$DAYS" "$JSON"
        ;;
    categories)
        cmd_categories "$DAYS" "$LIMIT" "$JSON"
        ;;
    patterns)
        cmd_patterns "$DAYS" "$LIMIT" "$JSON"
        ;;
    escapes)
        cmd_escapes "$DAYS" "$LIMIT" "$JSON"
        ;;
    timeline)
        cmd_timeline "$DAYS" "$JSON"
        ;;
    recent)
        cmd_recent "$LIMIT" "$JSON"
        ;;
    ship)
        cmd_ship
        ;;
    clear)
        cmd_clear
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        usage
        ;;
esac
