#!/bin/bash
# Hook that fires on SessionStart after compaction
# Ensures the re-read instruction appears in the fresh context
#
# OPTIMIZED: Only re-reads global CLAUDE.md. Project context auto-injected on-demand.

cat << 'EOF'
<post-compaction-hook>
CONTEXT COMPACTED - RE-READ GLOBAL RULES:

Your context was compacted. Important rules may have been lost.

BEFORE RESPONDING:

1. RE-READ ~/claude/CLAUDE.md (global safety rules)
   - Use the Read tool - REQUIRED
   - This has the critical rules (never restart docker, etc.)

2. DO NOT re-read project CLAUDE.md files
   - Project context will auto-inject when user mentions projects
   - Saves tokens

3. REPORT HEALTH STATUS from the SESSION HEALTH CHECK banner above
   - User needs to SEE the system status in YOUR response
   - Include: RAG, Ollama, Tribunal, MCP status
   - Example: "Health: RAG✓ Ollama✓ Tribunal✓ MCP✓ - all systems operational"

4. Brief acknowledgment format:
   ```
   Post-compaction: Global rules reloaded.
   Health: [status from banner]
   Ready to continue.
   ```

5. Check user's last message and continue

Project context auto-injects via <user-prompt-submit-hook> when needed.
</post-compaction-hook>
EOF
