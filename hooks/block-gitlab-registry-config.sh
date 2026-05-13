#!/bin/bash
# Block attempts to configure container registries in GitLab CI files
#
# GitLab CI handles registry auth AUTOMATICALLY via CI_REGISTRY_* variables.
# Claude repeatedly tries to configure REGISTRY_USER, REGISTRY_PASSWORD,
# docker login, config.json, harbor, oci.coldforge.xyz - all unnecessary.
#
# This hook blocks Edit/Write to .gitlab-ci.yml and Dockerfile when the
# content contains registry configuration patterns.
#
# Location: ~/.claude/hooks/block-gitlab-registry-config.sh
# Created: 2026-04-27

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Edit and Write tools
[[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]] && exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ -z "$FILE_PATH" ]] && exit 0

# Only check CI-related files
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
    .gitlab-ci.yml|.gitlab-ci.yaml|Dockerfile|config.json)
        ;;
    *)
        # Also check if it's in .gitlab-ci/ directory
        if [[ "$FILE_PATH" != *".gitlab-ci/"* ]]; then
            exit 0
        fi
        ;;
esac

# Get the content being written/edited
if [[ "$TOOL_NAME" == "Write" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
elif [[ "$TOOL_NAME" == "Edit" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
fi

[[ -z "$CONTENT" ]] && exit 0

# Check for registry configuration patterns
REGISTRY_PATTERNS=(
    "REGISTRY_USER"
    "REGISTRY_PASSWORD"
    "docker login"
    "docker/login"
    "/kaniko/.docker/config.json"
    "oci.coldforge.xyz"
    "harbor"
    "AEGIS_REGISTRY"
    "CI_REGISTRY_USER"
    "CI_REGISTRY_PASSWORD"
)

for pattern in "${REGISTRY_PATTERNS[@]}"; do
    if echo "$CONTENT" | grep -qiF "$pattern"; then
        echo "BLOCKED: Attempted to configure container registry credentials in CI file." >&2
        echo "" >&2
        echo "Pattern detected: '$pattern'" >&2
        echo "File: $FILE_PATH" >&2
        echo "" >&2
        echo "GitLab CI handles registry auth AUTOMATICALLY. Do NOT configure:" >&2
        echo "  - REGISTRY_USER / REGISTRY_PASSWORD" >&2
        echo "  - docker login commands" >&2
        echo "  - /kaniko/.docker/config.json writes" >&2
        echo "  - Harbor or oci.coldforge.xyz references" >&2
        echo "" >&2
        echo "Standard GitLab CI uses CI_REGISTRY_* variables which are auto-populated." >&2
        echo "For Kaniko, use: --destination=\$CI_REGISTRY_IMAGE:\$CI_COMMIT_SHORT_SHA" >&2
        exit 2
    fi
done

exit 0
