#!/bin/bash
# Hook that fires on SessionStart after compaction
# Ensures the re-read instruction appears in the fresh context
#
# OPTIMIZED: Only re-reads global CLAUDE.md. Project context auto-injected on-demand.

cat << 'EOF'
<post-compaction-hook>
CONTEXT COMPACTED - MANDATORY RAG RELOAD:

Your context was compacted. Session-specific decisions and learnings were LOST.

BEFORE RESPONDING - EXECUTE THESE STEPS IN ORDER:

1. CALL RAG TOOLS IMMEDIATELY (determine project from working directory):
   - mcp__rag__get_session_context project="<project>"
   - mcp__rag__search_learnings project="<project>" num_results=10
   - mcp__rag__search_decisions project="<project>" num_results=10

   These contain CRITICAL context about what was done in this session.
   Skipping these calls WILL cause you to give wrong answers.

2. RE-READ ~/arbiter/CLAUDE.md (global safety rules)
   - Use the Read tool - REQUIRED
   - This has the critical rules (never restart docker, etc.)

3. DO NOT re-read project CLAUDE.md files
   - Project context will auto-inject when user mentions projects
   - Saves tokens

4. REPORT HEALTH STATUS from the SESSION HEALTH CHECK banner above
   - User needs to SEE the system status in YOUR response
   - Include: RAG, Ollama, Tribunal, MCP status
   - Example: "Health: RAG✓ Ollama✓ Tribunal✓ MCP✓ - all systems operational"

5. Brief acknowledgment format:
   ```
   Post-compaction: RAG context and global rules reloaded.
   Health: [status from banner]
   Ready to continue.
   ```

6. Check user's last message and continue

FAILURE TO CALL RAG TOOLS = OPERATING ON INCOMPLETE INFORMATION = WRONG ANSWERS
</post-compaction-hook>
EOF
