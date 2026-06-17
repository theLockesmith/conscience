# Adding a Prod Target Safely

The V17 manifest at `~/.claude/security/prod-targets.yml` is the single
source of truth for "this counts as production-shared." Every PreToolUse
gate reads it through `~/.claude/hooks/lib/prod-target-match.sh`.

If your service is on this list, touching it from a Claude session
requires explicit verify-action confirmation. If it isn't, the hooks
fall through to softer enforcement.

## Schema

Top-level keys:

| Key | Type | What goes here |
|---|---|---|
| `prod_helm_releases` | list | `{release, namespace, cluster}` — Helm releases that own prod state |
| `prod_k8s_namespaces` | map | per-cluster list of namespaces (supports `*` glob, e.g. `openshift-*`) |
| `prod_k8s_contexts` | list | cluster contexts (`atlantis`, `pantheon`) |
| `prod_systemd_units` | list | systemd unit names (fully qualified, e.g. `rag-event-collector.service`) |
| `prod_docker_compose` | map | `local_dev_only: [paths]`; anything NOT here is prod |
| `prod_ssh_hosts` | list | SSH targets (host alias, FQDN, `user@host`); `*` glob ok |
| `prod_atlas_roles` | map | `prod: [...]` + `dev_only: [...]`. dev_only short-circuits to "not prod" even if prod glob would match |
| `prod_atlas_plays` | list | playbook paths or basenames |
| `prod_ansible_plays` | map | `prod_path_globs: [...]` for raw ansible-playbook invocations |
| `prod_file_paths` | list | file paths/globs. Trailing `*` for prefix glob. Supports `~` for `$HOME`. |
| `yank_verbs` | map | per-tool list of verbs that count as "yanking" a target |

## Adding a new helm release

```yaml
prod_helm_releases:
  - { release: my-new-thing, namespace: my-ns, cluster: atlantis }
```

If `my-ns` is also new, add it to `prod_k8s_namespaces.atlantis` too.
The hooks match on the release name AND the namespace independently —
both should be on the list for full coverage.

## Adding a new prod namespace

```yaml
prod_k8s_namespaces:
  atlantis:
    - my-new-ns
```

Wildcards (`my-*`) are matched as prefix globs by
`prod-target-match.sh`'s `pt_glob_match`.

The atlantis list is enumerated explicitly; pantheon uses `"*"` (every
namespace is prod). If you add a new cluster, decide which approach to
use up front — explicit-list-of-prod is safer when the cluster has both
prod and test namespaces; everything-is-prod is safer when the cluster
is single-tenant prod.

## Adding a new systemd unit

```yaml
prod_systemd_units:
  - my-shared-thing.service
```

Use the fully qualified unit name including `.service` / `.timer` /
`.socket`. The matcher does literal-equal comparison.

## Adding a new SSH host

```yaml
prod_ssh_hosts:
  - my-host
  - my-host.fqdn.example
  - "*-fleet.example"   # any FQDN ending in -fleet.example
```

`user@host` works too if you want to scope a host to a specific user
alias — `target-extract.sh` will see whatever the user types literally.

## Adding a new atlas role

```yaml
prod_atlas_roles:
  prod:
    - my-new-role
    - kube/*           # any kube/<sub-role>
  dev_only:
    - my-test-thing
```

If a role appears under both lists, `dev_only` wins (short-circuit to
NOT prod). This lets you scope a single role tree (`kube/*` is prod)
with a carved-out exception (`kube/sandbox` is dev_only).

## Adding a new file path

```yaml
prod_file_paths:
  - /etc/my-thing/*       # any file under /etc/my-thing
  - ~/.config/my-tool/*   # any file under ~/.config/my-tool (~ expands to $HOME)
  - /var/lib/my-state     # exact match
```

Globs match prefix. The matcher expands `~` to `$HOME` before
comparing.

The `prod_file_paths` list gates verbs like `rm`, `mv`, `chmod`,
`chown`, `sed -i`, `tee`, `touch` etc. (see `yank_verbs.file`). Touching
the file for read (`cat`, `head`, `tail`) does NOT emit a `file_path:`
target.

## Adding a verb to yank_verbs

If a new tool gets added to the operator's environment and it has
verbs that materially change shared state, extend `yank_verbs`:

```yaml
yank_verbs:
  my_tool:
    - apply
    - replace
    - rollback
```

`target-extract.sh` will also need a new handler emitting the
appropriate `TYPE:VALUE` lines. See `~/.claude/hooks/lib/target-extract.sh`
for the existing handlers as templates.

## Testing your change

```bash
bash ~/.claude/tests/v17/run.sh          # target-extract fixture tests
bash ~/.claude/tests/v17/run-hooks.sh    # end-to-end PreToolUse tests
```

If you added a new prod target or yank verb, add at least one positive
(BLOCK) and one negative (ALLOW) case to either `fixtures.json` or
`fixtures-hooks.json` covering the new shape.

## Rollback

The manifest is plain YAML, version-controlled in the conscience repo.
If a change goes wrong, `git revert` it. The hooks fail-closed if the
manifest fails to load — they emit a system-reminder warning and let
the command run with legacy gating, which means a bad commit causes
softer enforcement, not a fully open door.

## What NOT to put here

- Temporary infrastructure (e.g., a test cluster). Use the verify-action
  path on demand instead — putting it in the manifest means every future
  session has to read it.
- Personal files (e.g., `~/Documents/personal-notes`). The manifest is
  about operator-shared infrastructure, not personal data.
- Files that are routinely edited by the operator. The friction of
  needing a verify-action for every `vim ~/.bashrc` would be net negative.

## See also

- `hook-architecture.md` — how the hooks consume this manifest.
- `verify-action-guide.md` — how the assistant proves intent against it.
