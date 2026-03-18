# Project Conventions

> This file captures project-specific conventions, patterns, and decisions that AI assistants should follow.
> Update this file as you establish patterns during development.

## Code Style

### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Files | | `user_service.py` |
| Classes | | `UserService` |
| Functions | | `get_user_by_id` |
| Variables | | `user_count` |
| Constants | | `MAX_RETRIES` |

### Import Organization

```
# Standard format:
# 1. Standard library
# 2. Third-party
# 3. Local
```

## Architecture Patterns

### File Structure

```
src/
├── components/    #
├── services/      #
├── utils/         #
└── types/         #
```

### Common Patterns

| Pattern | When to Use | Example Location |
|---------|-------------|------------------|
| | | |

## Error Handling

```
# Standard error handling pattern:
```

## Testing

### Test Organization

- Unit tests:
- Integration tests:
- Test naming:

### Mocking Conventions

```
# Standard mock pattern:
```

## API Design

### Request/Response Format

```json
{
  "status": "",
  "data": {},
  "error": null
}
```

### Endpoint Naming

| Action | Verb | Pattern |
|--------|------|---------|
| List | GET | `/resources` |
| Get | GET | `/resources/:id` |
| Create | POST | `/resources` |
| Update | PUT | `/resources/:id` |
| Delete | DELETE | `/resources/:id` |

## Database

### Schema Conventions

- Primary keys:
- Foreign keys:
- Timestamps:
- Soft deletes:

### Migration Naming

```
YYYYMMDD_HHMMSS_description.sql
```

## Git Workflow

### Branch Naming

| Type | Pattern | Example |
|------|---------|---------|
| Feature | `feature/` | `feature/user-auth` |
| Bugfix | `fix/` | `fix/login-redirect` |
| Hotfix | `hotfix/` | `hotfix/critical-crash` |

### Commit Message Format

```
type(scope): description

Types: feat, fix, docs, style, refactor, test, chore
```

## Dependencies

### Approved Libraries

| Purpose | Library | Notes |
|---------|---------|-------|
| | | |

### Avoiding

| Library | Reason |
|---------|--------|
| | |

## Security

### Authentication

- Method:
- Token storage:
- Session handling:

### Input Validation

```
# Standard validation pattern:
```

## Logging

### Log Levels

| Level | Use For |
|-------|---------|
| DEBUG | |
| INFO | |
| WARN | |
| ERROR | |

### Log Format

```
{timestamp} [{level}] {component}: {message}
```

## Performance

### Caching Strategy

- Cache location:
- TTL:
- Invalidation:

### Query Optimization

- Index usage:
- N+1 prevention:

---

## Decisions Log

> Record significant architectural decisions here for context.

### [Date] Decision Title

**Context:** Why this decision was needed

**Decision:** What was decided

**Consequences:** Trade-offs and implications

---

*Last updated: YYYY-MM-DD*
