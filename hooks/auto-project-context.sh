#!/bin/bash
# Auto-inject project context when user mentions a project name
# Triggers on: UserPromptSubmit (before Claude processes the message)
# Location: ~/.claude/hooks/auto-project-context.sh

set -uo pipefail

# Read the user's prompt from stdin
USER_PROMPT=$(cat)

# Project registry - maps names/aliases to CLAUDE.md paths
declare -A PROJECTS=(
    # Empire
    ["autism"]="$HOME/claude/empire/autism/CLAUDE.md"
    ["openshift"]="$HOME/claude/empire/autism/CLAUDE.md"
    ["salesforce"]="$HOME/claude/empire/salesforce/CLAUDE.md"
    ["sfdc"]="$HOME/claude/empire/salesforce/CLAUDE.md"
    ["snowflake"]="$HOME/claude/empire/snowflake/CLAUDE.md"
    ["elation"]="$HOME/claude/empire/elation/CLAUDE.md"
    ["llm"]="$HOME/claude/empire/llm/CLAUDE.md"
    ["emp-llm"]="$HOME/claude/empire/llm/CLAUDE.md"
    ["openwebui"]="$HOME/claude/empire/llm/CLAUDE.md"
    ["jira"]="$HOME/claude/empire/jira/CLAUDE.md"
    ["scraping"]="$HOME/claude/empire/scraping/CLAUDE.md"

    # Coldforge
    ["atlantis"]="$HOME/claude/coldforge/atlantis/CLAUDE.md"
    ["atlas"]="$HOME/Atlas/CLAUDE.md"
    ["ceph"]="$HOME/claude/coldforge/ceph/CLAUDE.md"
    ["servarr"]="$HOME/claude/coldforge/servarr/CLAUDE.md"
    ["plex"]="$HOME/claude/coldforge/servarr/CLAUDE.md"
    ["jellyfin"]="$HOME/claude/coldforge/servarr/CLAUDE.md"
    ["cloistr"]="$HOME/claude/coldforge/cloistr/CLAUDE.md"
    ["cloistr-drive"]="$HOME/claude/coldforge/cloistr/CLAUDE.md"
    ["amp"]="$HOME/claude/coldforge/amp/CLAUDE.md"
    ["active-directory"]="$HOME/claude/coldforge/active-directory/CLAUDE.md"
    ["openstack"]="$HOME/claude/coldforge/openstack/CLAUDE.md"
    ["clawstr"]="$HOME/claude/coldforge/clawstr/CLAUDE.md"
    ["unifi"]="$HOME/claude/coldforge/unifi/CLAUDE.md"
    ["bitcoin"]="$HOME/claude/coldforge/bitcoin/CLAUDE.md"

    # Personal
    ["localhost"]="$HOME/claude/personal/localhost/CLAUDE.md"
    ["battlestation"]="$HOME/claude/personal/localhost/CLAUDE.md"
    ["deathstar"]="$HOME/claude/personal/localhost/CLAUDE.md"
)

# Company mapping - maps projects to their company (empire, coldforge, personal)
declare -A PROJECT_COMPANY=(
    # Empire Access (employer)
    ["autism"]="empire"
    ["openshift"]="empire"
    ["salesforce"]="empire"
    ["sfdc"]="empire"
    ["snowflake"]="empire"
    ["elation"]="empire"
    ["llm"]="empire"
    ["emp-llm"]="empire"
    ["openwebui"]="empire"
    ["jira"]="empire"
    ["scraping"]="empire"

    # Coldforge (personal LLC)
    ["atlantis"]="coldforge"
    ["atlas"]="coldforge"
    ["ceph"]="coldforge"
    ["servarr"]="coldforge"
    ["plex"]="coldforge"
    ["jellyfin"]="coldforge"
    ["cloistr"]="coldforge"
    ["cloistr-drive"]="coldforge"
    ["amp"]="coldforge"
    ["active-directory"]="coldforge"
    ["openstack"]="coldforge"
    ["clawstr"]="coldforge"
    ["unifi"]="coldforge"
    ["bitcoin"]="coldforge"

    # Personal
    ["localhost"]="personal"
    ["battlestation"]="personal"
    ["deathstar"]="personal"
)

# Patterns that indicate user wants to work on a project
WORK_PATTERNS=(
    "work on"
    "switch to"
    "let's.*check"
    "look at"
    "update.*the"
    "fix.*in"
    "implement.*for"
    "the.*project"
    "the.*roadmap"
    "the.*config"
)

# Check if prompt contains work-related patterns
CONTAINS_WORK_PATTERN=false
PROMPT_LOWER=$(echo "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')

for pattern in "${WORK_PATTERNS[@]}"; do
    if echo "$PROMPT_LOWER" | grep -qE "$pattern"; then
        CONTAINS_WORK_PATTERN=true
        break
    fi
done

# Find mentioned projects
MENTIONED_PROJECTS=()
for project in "${!PROJECTS[@]}"; do
    # Case-insensitive word boundary match
    if echo "$PROMPT_LOWER" | grep -qwi "$project"; then
        # Check if CLAUDE.md exists
        if [[ -f "${PROJECTS[$project]}" ]]; then
            MENTIONED_PROJECTS+=("$project")
        fi
    fi
done

# If projects mentioned and contains work pattern, inject context
if [[ ${#MENTIONED_PROJECTS[@]} -gt 0 ]] && [[ "$CONTAINS_WORK_PATTERN" == "true" ]]; then
    echo "<user-prompt-submit-hook>"
    echo "PROJECT CONTEXT AUTO-LOADED:"
    echo ""

    # Determine company context from mentioned projects
    # If multiple companies detected, warn about it
    declare -A COMPANIES_FOUND
    for project in "${MENTIONED_PROJECTS[@]}"; do
        company="${PROJECT_COMPANY[$project]:-}"
        if [[ -n "$company" ]]; then
            COMPANIES_FOUND[$company]=1
        fi
    done

    COMPANY_LIST=("${!COMPANIES_FOUND[@]}")
    if [[ ${#COMPANY_LIST[@]} -eq 1 ]]; then
        ACTIVE_COMPANY="${COMPANY_LIST[0]}"
        echo "**COMPANY CONTEXT: ${ACTIVE_COMPANY^^}**"
        echo ""
        echo "When using RAG search tools (search_docs, search_decisions, search_learnings),"
        echo "use company=\"$ACTIVE_COMPANY\" to filter results to this company's context only."
        echo ""
    elif [[ ${#COMPANY_LIST[@]} -gt 1 ]]; then
        echo "**WARNING: Multiple companies detected in prompt!**"
        echo "Companies: ${COMPANY_LIST[*]}"
        echo ""
        echo "Be careful not to mix contexts. Use company= filter explicitly in RAG searches."
        echo ""
    fi

    # Dedupe by path (multiple aliases may point to same file)
    declare -A SEEN_PATHS
    for project in "${MENTIONED_PROJECTS[@]}"; do
        CLAUDE_PATH="${PROJECTS[$project]}"
        if [[ -z "${SEEN_PATHS[$CLAUDE_PATH]:-}" ]]; then
            SEEN_PATHS[$CLAUDE_PATH]=1
            company="${PROJECT_COMPANY[$project]:-unknown}"
            echo "### Context for: $project (company: $company)"
            echo "Path: $CLAUDE_PATH"
            echo ""
            # Read first 200 lines to capture critical rules
            head -200 "$CLAUDE_PATH" 2>/dev/null || echo "(Could not read file)"
            echo ""
            echo "---"
            echo ""
        fi
    done

    echo "The above context was auto-loaded because you mentioned project(s): ${MENTIONED_PROJECTS[*]}"
    echo "Use the \`get_project_context\` MCP tool for full context if needed."
    echo "</user-prompt-submit-hook>"
fi

# Always exit 0 - we're only adding context, not blocking
exit 0
