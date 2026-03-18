---
name: security-audit
description: Comprehensive security review for vulnerabilities and exposed secrets
triggers:
  - security audit
  - check security
  - vulnerability scan
  - security review
  - find vulnerabilities
---

# Security Audit Workflow

A structured security review covering OWASP Top 10, secrets exposure, and common vulnerabilities.

## Scope Definition

Before starting, clarify:
- What code/system to audit (specific files, entire project, or recent changes)
- Depth level (quick scan vs comprehensive)
- Any known sensitive areas

## Execution Protocol

### Step 1: Secrets Scan (Always First)

Check for exposed credentials:

```
Task: Scan for secrets
Subagent: security
Prompt: |
  Scan for exposed secrets and credentials:
  - API keys, tokens, passwords
  - Private keys, certificates
  - Database connection strings
  - Environment files committed to repo
  - Hardcoded credentials in code

  Check: .env files, config files, source code
  Also check git history if accessible
```

**CRITICAL:** Report any findings immediately - these are urgent.

### Step 2: OWASP Top 10 Review

Systematic check of common vulnerabilities:

```
Task: OWASP vulnerability scan
Subagent: security
Prompt: |
  Review for OWASP Top 10 vulnerabilities:

  1. **Injection** (SQL, command, LDAP, XSS)
     - User input used in queries/commands?
     - Parameterized queries used?

  2. **Broken Authentication**
     - Session management secure?
     - Password storage (hashing, salting)?
     - MFA available?

  3. **Sensitive Data Exposure**
     - Data encrypted at rest/transit?
     - PII handling appropriate?

  4. **XML External Entities (XXE)**
     - XML parsing configured safely?

  5. **Broken Access Control**
     - Authorization checked on all endpoints?
     - IDOR vulnerabilities?

  6. **Security Misconfiguration**
     - Debug mode disabled in prod?
     - Default credentials changed?

  7. **Cross-Site Scripting (XSS)**
     - Output encoding used?
     - CSP headers set?

  8. **Insecure Deserialization**
     - Untrusted data deserialized?

  9. **Using Components with Known Vulnerabilities**
     - Dependencies up to date?
     - Known CVEs in dependencies?

  10. **Insufficient Logging & Monitoring**
      - Security events logged?
      - Alerts configured?
```

### Step 3: Infrastructure Review (If Applicable)

For infrastructure code:

```
Task: Infrastructure security review
Subagent: systems (if available) or security
Prompt: |
  Review infrastructure security:
  - Network segmentation
  - Firewall rules (overly permissive?)
  - TLS configuration
  - Container security (root user, capabilities)
  - Kubernetes RBAC
  - Secrets management (vault, sealed secrets)
```

### Step 4: Generate Report

Compile findings:

```markdown
## Security Audit Report

**Date:** {date}
**Scope:** {what was audited}
**Auditor:** Claude Code

### Critical Findings (Fix Immediately)
- {finding with severity and remediation}

### High Findings (Fix Soon)
- {finding}

### Medium Findings (Plan to Fix)
- {finding}

### Low/Informational
- {finding}

### Recommendations
1. {prioritized recommendation}

### What Was Checked
- [ ] Secrets scan
- [ ] OWASP Top 10
- [ ] Infrastructure (if applicable)
- [ ] Dependencies

### Out of Scope
- {anything not checked}
```

## Severity Definitions

| Severity | Criteria | Response Time |
|----------|----------|---------------|
| **Critical** | Actively exploitable, data exposure | Immediate |
| **High** | Exploitable with effort | Within days |
| **Medium** | Requires specific conditions | Within weeks |
| **Low** | Minor impact, hardening | When convenient |

## Common Patterns to Flag

### Definitely Bad
- `password = "..."` hardcoded
- `SELECT * FROM users WHERE id = ` + userInput
- `eval()` or `exec()` with user input
- `chmod 777` or world-readable secrets
- Disabled TLS verification

### Suspicious (Investigate)
- Base64-encoded strings (might be secrets)
- Environment variable usage without validation
- Dynamic SQL construction
- User input in file paths
- Disabled CSRF protection

## Example Usage

User: "security audit on the authentication module"

1. **Secrets:** Check for hardcoded credentials, API keys
2. **OWASP:** Focus on auth-related items (broken auth, access control)
3. **Report:** Findings with severity and remediation steps
