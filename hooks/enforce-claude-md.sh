#!/bin/bash
# Hook to enforce CLAUDE.md compliance before filesystem operations

cat << 'EOF'
STOP. Before proceeding with this filesystem operation:

1. Have you read the CLAUDE.md file in the current project directory?
2. Are you operating within the documented project structure (~/arbiter/)?
3. For Empire projects: NEVER search ~/Development/ - all code is under ~/arbiter/empire/

If you haven't read the project's CLAUDE.md, READ IT NOW before continuing.
EOF
