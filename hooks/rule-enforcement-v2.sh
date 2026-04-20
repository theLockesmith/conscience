#!/bin/bash
# Rule Enforcement v2 - LLM-powered validation with semantic rule search
# Hook: Stop
#
# Architecture:
# 1. Receive response from Claude Code
# 2. Query pgvector for relevant rules from CLAUDE.md files
# 3. Send response + rules to Ollama for validation
# 4. Return BLOCK or PASS
#
# Output format for blocking:
# {"decision": "block", "reason": "explanation"}

set -uo pipefail

# Configuration
POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw.db.aegis-hq.xyz}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-ragdb}"
POSTGRES_USER="${POSTGRES_USER:-rag}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
OLLAMA_HOST="${OLLAMA_HOST:-10.0.4.10:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:7b}"

LOG_FILE="$HOME/.claude/rule-violations.log"

# Read password from MCP config if not set
if [[ -z "$POSTGRES_PASSWORD" ]]; then
    MCP_CONFIG="$HOME/claude/personal/localhost/.mcp.json"
    if [[ -f "$MCP_CONFIG" ]]; then
        POSTGRES_PASSWORD=$(jq -r '.mcpServers.rag.env.POSTGRES_PASSWORD // empty' "$MCP_CONFIG" 2>/dev/null)
    fi
fi

# Read hook input
HOOK_INPUT=$(cat)

# Extract response text
RESPONSE=$(echo "$HOOK_INPUT" | jq -r '.response // .content // .text // .' 2>/dev/null)

# If we couldn't extract response or it's too short, let it through
if [[ -z "$RESPONSE" ]] || [[ "$RESPONSE" == "null" ]] || [[ ${#RESPONSE} -lt 20 ]]; then
    exit 0
fi

# Function to query pgvector for relevant rules
query_rules() {
    local search_text="$1"

    # Generate embedding for search text using Ollama
    local embedding_response
    embedding_response=$(curl -s "http://${OLLAMA_HOST}/api/embeddings" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg model "mxbai-embed-large" --arg prompt "Represent this sentence for searching relevant passages: $search_text" \
            '{model: $model, prompt: $prompt}')" 2>/dev/null)

    local embedding
    embedding=$(echo "$embedding_response" | jq -r '.embedding | @json' 2>/dev/null)

    if [[ -z "$embedding" ]] || [[ "$embedding" == "null" ]]; then
        echo "[]"
        return
    fi

    # Query PostgreSQL for rules from CLAUDE.md files
    # Using hybrid search: vector similarity + text search for "rule" or "never" or "always"
    local query="
        WITH vector_search AS (
            SELECT file_path, chunk_text,
                   1 - (embedding <=> '${embedding}'::vector) as similarity
            FROM documents
            WHERE file_path LIKE '%CLAUDE.md'
              AND (chunk_text ILIKE '%rule%'
                   OR chunk_text ILIKE '%never%'
                   OR chunk_text ILIKE '%always%'
                   OR chunk_text ILIKE '%critical%'
                   OR chunk_text ILIKE '%must%')
            ORDER BY embedding <=> '${embedding}'::vector
            LIMIT 10
        )
        SELECT json_agg(json_build_object(
            'file', file_path,
            'rule', chunk_text,
            'relevance', similarity
        ))
        FROM vector_search
        WHERE similarity > 0.3;
    "

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "$query" 2>/dev/null || echo "[]"
}

# Function to validate response against rules using Ollama
validate_with_llm() {
    local response="$1"
    local rules="$2"

    # Truncate response if too long (keep first 2000 chars)
    if [[ ${#response} -gt 2000 ]]; then
        response="${response:0:2000}..."
    fi

    local prompt="You are a strict rule compliance validator. Your job is to check if an AI assistant's response violates any rules.

RULES TO CHECK AGAINST:
$rules

RESPONSE TO VALIDATE:
$response

VALIDATION INSTRUCTIONS:
1. Check if the response takes ACTION without being asked (remediation without permission)
2. Check if the response makes ASSUMPTIONS instead of asking
3. Check if the response delivers incomplete or 'good enough' solutions
4. Check if the response violates any NEVER/ALWAYS rules from above
5. Check if the response announces doing something dangerous (restarting docker, force deleting, decrypting vaults)

OUTPUT FORMAT:
- If the response CLEARLY violates a rule, output: BLOCK: <specific rule violated> - <brief explanation>
- If the response is compliant, output: PASS

Be strict but fair. Only BLOCK clear violations, not edge cases.
Your response must start with either 'BLOCK:' or 'PASS'."

    local llm_response
    llm_response=$(curl -s "http://${OLLAMA_HOST}/api/generate" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$OLLAMA_MODEL" \
            --arg prompt "$prompt" \
            '{model: $model, prompt: $prompt, stream: false, options: {temperature: 0.1, num_predict: 200}}')" \
        2>/dev/null | jq -r '.response // "PASS"' 2>/dev/null)

    echo "$llm_response"
}

# Extract key phrases from response for rule search
# Focus on action words and topics
extract_search_terms() {
    local text="$1"
    # Get first 500 chars, extract key action phrases
    echo "${text:0:500}" | tr '[:upper:]' '[:lower:]' | \
        grep -oE '(restart|delete|remove|force|decrypt|trigger|assume|assume|fix|change|modify|update|create|deploy)' | \
        head -5 | tr '\n' ' '
}

# Main logic
main() {
    # Extract search terms from response
    local search_terms
    search_terms=$(extract_search_terms "$RESPONSE")

    # If no action words found, probably safe - quick pass
    if [[ -z "$search_terms" ]]; then
        exit 0
    fi

    # Query for relevant rules
    local rules
    rules=$(query_rules "$search_terms $RESPONSE")

    # If no rules found, pass through
    if [[ -z "$rules" ]] || [[ "$rules" == "null" ]] || [[ "$rules" == "[]" ]]; then
        exit 0
    fi

    # Format rules for LLM
    local formatted_rules
    formatted_rules=$(echo "$rules" | jq -r '.[] | "[\(.file)]: \(.rule)"' 2>/dev/null | head -20)

    if [[ -z "$formatted_rules" ]]; then
        exit 0
    fi

    # Validate with LLM
    local validation
    validation=$(validate_with_llm "$RESPONSE" "$formatted_rules")

    # Check result
    if [[ "$validation" == BLOCK:* ]]; then
        local reason="${validation#BLOCK: }"

        # Log violation
        echo "$(date -Iseconds) BLOCKED: $reason" >> "$LOG_FILE"
        echo "Response excerpt: ${RESPONSE:0:200}..." >> "$LOG_FILE"
        echo "---" >> "$LOG_FILE"

        # Output block decision
        echo "{\"decision\": \"block\", \"reason\": \"$reason\"}"
        exit 0
    fi

    # Pass through
    exit 0
}

main
