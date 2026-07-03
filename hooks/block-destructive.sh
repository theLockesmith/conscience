#!/bin/bash
# Block Destructive — RETIRED 2026-07-03
# Hook: PreToolUse
#
# This hook's ~500-line regex catalog has been fully absorbed into the
# arbiter-client kit's server-classified path:
#
#   1. Server-side yaml at coldforge-rag-mcp-server/config/
#      destructive_triggers.yaml — 64 triggers covering every pattern
#      this script previously enforced (kubectl/oc/helm/terraform/DB/
#      git/systemctl/rm-rf/pipelined-delete/system-lifecycle/scripted
#      -c payloads/piped-remote-exec/untrusted-pipe/variable-
#      indirection/sensitive-path-writes/ceph/openstack/ansible-vault/
#      LVM/parted/shred/etc.).
#
#      The yaml is ArgoCD-managed via
#      cluster-config/argocd/apps/rag-mcp-destructive-triggers.yaml —
#      PR-review workflow, single source of truth.
#
#   2. Client-side kit hook at ~/.arbiter/hooks/block_destructive.py
#      (arbiter-client 0.4.16+) — calls mcp__rag__verify_action on
#      every Bash tool call. Server classifies against the yaml,
#      returns approve/warn/block verdict. Kit blocks accordingly.
#
#   3. Client-side safety floor in the kit hook — evaluates a
#      hardcoded minimum-set locally when MCP is unreachable. Covers
#      the truly-catastrophic patterns (rm -rf /, curl|bash,
#      ansible-vault decrypt, etc.) so RAG outages don't fully
#      fail-open on the load-bearing dangers.
#
# Rationale for retirement (operator direction 2026-07-03): dual
# source of truth (this script + the server yaml) meant every gate
# refinement had to happen in two places, and diverging patterns
# caused false positives that blocked legitimate work. Consolidating
# to the server yaml + kit hook eliminates the class.
#
# Historical: full pre-retirement content of this hook is preserved
# in the git history of this repo (gitlab-coldforge:lockesmith/
# conscience) at parent commit acfb956. If a specific pattern needs
# to come back for bash-only reasons that the yaml can't express,
# add it here as a targeted exception rather than reviving the full
# catalog.

exit 0
