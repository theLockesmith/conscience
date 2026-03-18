---
name: refactor
description: Safe code refactoring with dependency mapping and verification
triggers:
  - refactor
  - clean up
  - restructure
  - reorganize
  - simplify
---

# Refactoring Workflow

A structured workflow for safe refactoring with exploration and verification.

## Prerequisites

- Clear refactoring goal (what to improve)
- Access to test suite (critical for verification)

## Execution Protocol

### Step 1: Map Dependencies (Critical)

Spawn an Explore agent to understand impact:

```
Task: Map dependencies and usage
Subagent: Explore
Thoroughness: very_thorough
Prompt: |
  Map all dependencies and usages of: {target}
  Find:
  - What imports/uses this code
  - What this code depends on
  - Test coverage for this code
  - Related code that might need updates
```

**CRITICAL:** Do not proceed without understanding the full impact.

### Step 2: Plan Refactoring (Approval Required)

Design the refactoring approach:

```
Action: EnterPlanMode
Requirements:
  - Break into small, atomic steps
  - Each step should be independently verifiable
  - Identify rollback points
  - Note any API changes that affect callers
  - Wait for user approval
```

**CRITICAL:** Get approval before making changes.

### Step 3: Implement in Small Steps

Execute refactoring incrementally:

```
Guidelines:
  - One logical change per step
  - Run tests after each step
  - Commit frequently (if using git)
  - Keep backwards compatibility where possible
  - Update imports/usages as you go
```

### Step 4: Run Tests

Verify nothing broke:

```
Task: Run test suite
Subagent: tester
Prompt: |
  Run the full test suite
  Report any failures with context
  Note any tests that became flaky
```

If tests fail:
1. Identify which refactoring step caused the failure
2. Fix the issue or rollback that step
3. Re-run tests

### Step 5: Review Changes

Final quality check:

```
Task: Review refactoring
Subagent: reviewer
Prompt: |
  Review the refactored code for:
  - Is it actually simpler/cleaner?
  - Any introduced complexity?
  - Consistent naming and patterns?
  - Missing updates to docs/comments?
```

## Output

After completion, provide:

1. Summary of what was refactored
2. Files modified
3. Test results
4. Any follow-up items (docs, additional cleanup)

## Abort Conditions

Stop the refactoring if:
- Tests start failing and fix isn't obvious
- User rejects the plan
- Impact is larger than expected
- Would require breaking API changes

## Refactoring Patterns

### Extract Function/Method
1. Identify repeated or complex code
2. Create new function with clear name
3. Replace original code with call
4. Run tests

### Rename Symbol
1. Find all usages (Explore agent)
2. Update definition
3. Update all usages
4. Run tests

### Move Code
1. Map dependencies
2. Move to new location
3. Update all imports
4. Run tests

### Simplify Conditional
1. Identify complex condition
2. Extract to well-named function or use early returns
3. Verify behavior unchanged with tests

## Example Usage

User: "refactor the authentication module to use dependency injection"

1. **Explore:** Find all auth dependencies, usages, tests
2. **Plan:** "Will create AuthProvider interface, update 5 files, no breaking changes"
3. **Implement:** Create interface → Update auth module → Update consumers → Update tests
4. **Test:** Run auth-related tests, then full suite
5. **Review:** Verify cleaner, more testable structure
