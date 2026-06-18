# Bug: built-in `claude-code-guide` subagent uses a deprecated/non-existent model id

**Claude Code version:** 2.1.181 (exec path
`/home/forgemaster/.local/share/claude/versions/2.1.181`,
`AI_AGENT=claude-code_2-1-181_agent`)

## Summary

Spawning the built-in `claude-code-guide` subagent via the Task tool
errors out immediately with:

```
There's an issue with the selected model (claude-sonnet-4-20250514).
It may not exist or you may not have access to it.
Run /model to pick a different model.
```

No subagent tokens are consumed and `tool_uses: 0`. The agent never
runs.

## Steps to reproduce

1. Open any Claude Code session (no special config).
2. Spawn the `claude-code-guide` subagent via the Task tool with any
   prompt, e.g. `subagent_type: "claude-code-guide"`,
   `description: "test"`,
   `prompt: "what is the official docs URL for hooks?"`.

Expected: the subagent runs and returns an answer.
Observed: the error above, no run.

## Root cause (inferred)

The agent definition baked into the Claude Code binary references
`claude-sonnet-4-20250514`. That model id was the May 2025 Sonnet 4
generation and is no longer accessible to most accounts — current
Sonnet is `claude-sonnet-4-6` per
https://docs.anthropic.com/en/docs/about-claude/models.

User-side agent definitions (under `~/.claude/agents/*.md`) are
sweepable by the operator and can be re-pointed at the current id;
the `claude-code-guide` agent is not in that directory, nor in
`~/.claude/plugins/marketplaces/*`, nor in the
`installed_plugins.json`. It only exists inside the Claude Code
binary's bundled-agents set, which the operator cannot patch.

## Workaround

None I'm aware of for the built-in. User-defined agents can avoid the
issue by either (a) using current concrete model ids like
`claude-sonnet-4-6` / `claude-haiku-4-5-20251001` /
`claude-opus-4-8`, or (b) setting the `CLAUDE_CODE_SUBAGENT_MODEL`
env var to a current id (it overrides per-agent definitions). Neither
works for the bundled `claude-code-guide` because the env var override
also still resolves to the stale id, suggesting the bundled agent
hardcodes its model in the definition rather than honoring the env
fallback.

## Suggested fix

Update the bundled `claude-code-guide` agent definition to use the
current Sonnet model id (or the `sonnet` alias if the alias resolver
is fixed to point at current generation).

## Why this matters

`claude-code-guide` is, per its description, the canonical way to ask
Claude Code about its own surfaces (hooks, MCP servers, slash
commands, IDE integration, the Claude API). Having it broken means
either ad-hoc WebFetch against `docs.anthropic.com` / `code.claude.com`
or guessing — both worse than the agent being routed to.

## Related observations (not a bug per se, just context)

The model-alias resolver itself appears to also be stale: setting
`model: sonnet` or `model: haiku` in a user agent file resolves to
`claude-sonnet-4-20250514` rather than the current Sonnet/Haiku.
Switching user agents to the concrete current ids
(`claude-sonnet-4-6`, etc.) worked around it locally — but the
abstract aliases really ought to track whatever the current
generation is.
