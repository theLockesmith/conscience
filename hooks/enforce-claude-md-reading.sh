#!/bin/bash
# Hook to enforce CLAUDE.md compliance at session start
# Triggers on: SessionStart (new conversations only, not compaction - that has its own hook)
#
# OPTIMIZED: Only reads global CLAUDE.md for safety rules.
# Project-specific context is injected on-demand by auto-project-context.sh hook
# when user mentions a project. This saves 10-15k tokens per session.

cat << 'EOF'
<session-start-hook>
STARTUP - READ GLOBAL RULES ONLY:

You are starting a new session. Before responding:

1. READ the global CLAUDE.md at ~/arbiter/CLAUDE.md
   - This contains critical safety rules (never restart docker, never force delete, etc.)
   - Use the Read tool - this is REQUIRED

2. DO NOT read project-specific CLAUDE.md files yet
   - Project context will be AUTO-INJECTED when the user mentions a project
   - The UserPromptSubmit hook handles this automatically
   - This saves tokens by loading context on-demand

3. Brief acknowledgment (no verbose checklist needed):
   ```
   Ready. Global rules loaded.
   ```

4. Then respond to the user's message

NOTE: When you see <user-prompt-submit-hook> tags later in the conversation, that's
project context being auto-injected. Use it naturally without commenting on it.
</session-start-hook>
EOF
