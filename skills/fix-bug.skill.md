---
name: fix-bug
description: Investigate and fix bugs with proper root cause analysis and verification
triggers:
  - fix bug
  - debug this
  - not working
  - broken
  - investigate bug
---

# Bug Fix Workflow

A structured workflow for investigating and fixing bugs with verification.

## Prerequisites

- Bug description or error message
- Steps to reproduce (if available)
- Access to relevant code and logs

## Execution Protocol

### Step 1: Investigate (Critical First Step)

Spawn a debugger agent to find root cause:

```
Task: Investigate root cause
Subagent: debugger
Prompt: |
  Investigate the root cause of: {bug_description}

  Steps:
  1. Understand the expected vs actual behavior
  2. Trace the code path involved
  3. Identify potential causes
  4. Find the specific location of the bug

  Output:
  - Root cause identified
  - Location (file:line)
  - Why it happens
  - Impact scope
```

**CRITICAL:** Do not propose fixes until root cause is understood.

### Step 2: Propose Fix (Approval Required)

Based on investigation, propose a fix:

```
Action: Propose fix
Requirements:
  - Explain the root cause clearly
  - Describe the proposed fix
  - Identify any side effects
  - Note if this is a symptom vs root cause fix
  - Wait for user approval
```

**CRITICAL:** Do not implement without explicit user approval.

### Step 3: Implement Fix (Sequential)

Implement the approved fix:

```
Action: Write code
Guidelines:
  - Make minimal changes to fix the issue
  - Do not refactor unrelated code
  - Add comments if the fix is non-obvious
  - Consider edge cases
```

### Step 4: Verify (Run Tests)

Run relevant tests to verify the fix:

```
Task: Verify fix
Subagent: tester
Prompt: |
  Run tests related to: {affected_area}

  Verify:
  - The bug is fixed
  - No regressions introduced
  - Edge cases handled
```

If tests don't exist for this area, consider adding them.

### Step 5: Review (Post-Fix)

Review the fix for quality:

```
Task: Review fix
Subagent: reviewer
Prompt: |
  Review this bug fix for:
  - Does it address the root cause?
  - Any potential for regressions?
  - Is there a better approach?
  - Missing test coverage?
```

## Output

After completion, provide:

1. Root cause summary
2. Fix description
3. Files modified
4. Test results
5. Any follow-up recommendations

## Abort Conditions

Stop the workflow if:
- Root cause cannot be determined (need more info)
- User rejects proposed fix
- Fix introduces regressions
- Fix is too risky without more analysis

## Common Patterns

### When You Can't Reproduce

1. Add logging to narrow down the issue
2. Ask user for more context
3. Look for similar issues in the codebase
4. Check error handling paths

### When Multiple Causes Possible

1. List all possibilities with likelihood
2. Propose diagnostic steps to narrow down
3. Wait for user guidance

### When Fix Requires Refactoring

1. Propose minimal fix first
2. Note technical debt for later
3. Don't expand scope without approval

## Example Usage

User: "fix bug: users can submit the form twice causing duplicate entries"

1. **Investigate:** Trace form submission, check for debouncing, review backend handling
2. **Propose:** "Root cause: No idempotency check. Fix: Add request deduplication using request ID"
3. **Implement:** Add idempotency key to form, check on backend
4. **Verify:** Test double-click, test rapid submissions
5. **Review:** Check for race conditions, verify cleanup of old keys
