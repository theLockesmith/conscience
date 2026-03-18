---
name: smart-council
description: Cost-effective multi-expert code review using tiered escalation
triggers:
  - council review
  - expert review
  - thorough review
---

# Smart Council Review

A cost-effective multi-expert review that uses tiered escalation instead of parallel execution.

## How It Works

1. **Quick scan** (Haiku) - Generalist catches obvious issues
2. **Route to relevant experts** (Sonnet) - 2-3 experts based on change type
3. **Summarize findings** - Each expert produces 50-100 token summary
4. **Synthesize** - Merge into prioritized action items

## Execution Protocol

### Step 1: Analyze Change Type

Examine the diff/files to categorize:

| Pattern | Category | Experts to Invoke |
|---------|----------|-------------------|
| `auth`, `login`, `password`, `token`, `session` | Auth | security, architecture |
| `*.tsx`, `*.jsx`, `component`, `ui/` | Frontend | frontend-quality, ux |
| `*.sql`, `schema`, `migration`, `model` | Database | db-quality, backend, security |
| `api/`, `endpoint`, `route`, `handler` | API | backend, security, testing |
| `perf`, `cache`, `optimize`, `index` | Performance | performance, architecture |
| `test`, `spec`, `*.test.*` | Testing | testing |

### Step 2: Quick Scan (Always First)

Spawn a Haiku subagent for initial triage:

```
Task: Quick scan for obvious issues
Model: haiku
Prompt: |
  Review this diff for obvious issues only. Be brief.
  Categories: security red flags, obvious bugs, missing error handling.
  Output: One line per issue found, or "CLEAN" if none.
  Max 5 lines.
```

If CLEAN and low-risk change → Stop here (huge savings)

### Step 3: Expert Review (2-3 Relevant Experts)

For each relevant expert, spawn sequentially (not parallel):

```
Task: {expert} review
Model: sonnet
Prompt: |
  You are a {expert_persona}.

  Previous findings: {previous_summaries}

  Review this code for {expert_focus}.

  Output format (max 100 tokens):
  - CRITICAL: {issue} (if any)
  - HIGH: {issue} (if any)
  - MEDIUM: {issue} (if any)
  - Or: "No issues in my domain"
```

### Step 4: Synthesize

Merge all expert summaries into final report:

```markdown
## Council Review Summary

**Experts consulted:** security, backend (2 of 10 - auth change detected)

### Critical (0)
None

### High (1)
- [Security] Rate limiting missing on /api/login endpoint

### Medium (2)
- [Backend] Consider adding request validation middleware
- [Security] Log failed auth attempts for monitoring

### Action Items
1. Add rate limiting before merge
2. Consider validation middleware (non-blocking)
```

## Expert Personas (Reference)

Only loaded when that expert is invoked:

### security
Focus: OWASP Top 10, auth flaws, injection, secrets exposure
Persona: "Security engineer who has seen production breaches"

### backend
Focus: API design, error handling, data validation, architecture
Persona: "Senior backend developer, 10 years experience"

### frontend-quality
Focus: Component patterns, state management, accessibility
Persona: "React/frontend specialist"

### db-quality
Focus: Schema design, query efficiency, migrations, indexes
Persona: "Database administrator and performance expert"

### testing
Focus: Test coverage, edge cases, mocking, test quality
Persona: "TDD practitioner, Kent Beck disciple"

### performance
Focus: Complexity, caching, N+1 queries, memory usage
Persona: "Performance engineer who profiles everything"

### architecture
Focus: SOLID, patterns, coupling, maintainability
Persona: "Software architect, Martin Fowler reader"

### ux
Focus: User flows, error states, loading states, edge cases
Persona: "UX designer who thinks about unhappy paths"

## Cost Comparison

| Approach | Experts | Model | Est. Cost |
|----------|---------|-------|-----------|
| Full parallel council | 10 | Opus | $$$$$$ |
| Full parallel council | 10 | Sonnet | $$$$ |
| Smart council (typical) | 2-3 | Sonnet | $ |
| Smart council (clean) | 1 | Haiku | ¢ |

**Typical savings: 70-90%** vs full council
