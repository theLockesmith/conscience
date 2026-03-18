---
name: implement-feature
description: Full feature implementation with exploration, planning, review, and testing
triggers:
  - implement feature
  - add feature
  - build new
  - create feature
---

# Feature Implementation Workflow

A structured workflow for implementing new features with quality gates.

## Prerequisites

- Clear feature description from user
- Access to the target codebase

## Execution Protocol

### Step 1: Explore (Parallel OK)

Spawn an Explore agent to find existing patterns:

```
Task: Explore codebase for feature context
Subagent: Explore
Thoroughness: medium
Prompt: |
  Find architecture and patterns relevant to: {feature}
  Look for:
  - Similar implementations in codebase
  - File locations for modifications
  - Existing utilities/helpers to reuse
  - Test patterns used in this area
```

Wait for results before proceeding.

### Step 2: Plan (Sequential, Approval Required)

Enter plan mode and design the implementation:

```
Action: EnterPlanMode
Requirements:
  - Break into atomic tasks
  - Identify files to modify/create
  - Define acceptance criteria
  - Note any architectural decisions
  - Wait for user approval before proceeding
```

**CRITICAL:** Do not proceed without explicit user approval of the plan.

### Step 3: Implement (Sequential)

Execute the approved plan task by task:

```
Action: Write code
Guidelines:
  - Follow existing patterns found in Step 1
  - Keep changes minimal and focused
  - Write code that matches codebase style
  - Use TodoWrite to track progress
```

### Step 4: Review (After Implementation)

Spawn a reviewer to check the implementation:

```
Task: Review implementation
Subagent: reviewer
Prompt: |
  Review the implementation for:
  - Code quality and readability
  - Adherence to existing patterns
  - Potential bugs or edge cases
  - Missing error handling
```

Address any issues found before proceeding.

### Step 5: Test (If Applicable)

Check if tests are needed:

```
Condition: If the codebase has tests and feature is testable

Task: Generate tests
Subagent: test-writer
Prompt: |
  Generate tests for the new feature:
  - Unit tests for new functions
  - Integration tests if touching multiple components
  - Follow existing test patterns
```

Run tests to verify:

```
Task: Run tests
Subagent: tester
Prompt: Run the test suite and report results
```

## Output

After completion, provide:

1. Summary of what was implemented
2. Files modified/created
3. Any known limitations or follow-up items
4. Test status (if applicable)

## Abort Conditions

Stop the workflow if:
- User rejects the plan
- Critical issues found during review
- Tests fail and cannot be fixed
- Architectural concerns raised

## Example Usage

User: "implement feature for user profile picture upload"

1. **Explore:** Find existing file upload patterns, image handling, user profile code
2. **Plan:** Propose API endpoint, storage approach, frontend component
3. **Implement:** Write the upload endpoint, storage logic, UI component
4. **Review:** Check for security (file validation), error handling
5. **Test:** Add tests for upload endpoint, file validation
