#!/bin/bash
# V17 Phase 7 integration tests.
#
# Sets up a clean fake HOME, copies the hooks + libs + manifest, then
# walks fixtures-hooks.json running each fixture against the named hook
# with synthetic session-state files.

set -u
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
HOOKS_FIX="${SELF_DIR}/fixtures-hooks.json"
[[ -f "$HOOKS_FIX" ]] || { echo "missing: $HOOKS_FIX"; exit 2; }

REAL_HOME="$HOME"
HOME_FAKE=/tmp/v17-hooks-test-home

setup_fake_home() {
    \rm -rf "$HOME_FAKE"
    mkdir -p "$HOME_FAKE/.claude/security" \
             "$HOME_FAKE/.claude/hooks/lib" \
             "$HOME_FAKE/.claude/session-state" \
             "$HOME_FAKE/.claude/tests/v17"
    \cp "$REAL_HOME/.claude/hooks/lib/target-extract.sh" "$HOME_FAKE/.claude/hooks/lib/"
    \cp "$REAL_HOME/.claude/hooks/lib/prod-target-match.sh" "$HOME_FAKE/.claude/hooks/lib/"
    \cp "$REAL_HOME/.claude/security/prod-targets.yml" "$HOME_FAKE/.claude/security/"
    \cp "$REAL_HOME/.claude/hooks/verify-infra-target.sh" "$HOME_FAKE/.claude/hooks/"
    \cp "$REAL_HOME/.claude/hooks/block-destructive.sh"   "$HOME_FAKE/.claude/hooks/"
    \cp "$REAL_HOME/.claude/hooks/require-rag-pretooluse.sh" "$HOME_FAKE/.claude/hooks/"
}

setup_fake_home

passed=0
failed=0
declare -a fails

# Walk fixtures via python (jq doesn't easily roundtrip arbitrary nested JSON)
python3 - "$HOOKS_FIX" "$HOME_FAKE" "$REAL_HOME" << 'PYEOF'
import json, os, subprocess, sys, shlex

fix_path, home_fake, real_home = sys.argv[1], sys.argv[2], sys.argv[3]
fixtures = json.load(open(fix_path))
state_dir = os.path.join(home_fake, ".claude", "session-state")

passed = failed = 0
fails = []

for fx in fixtures:
    name = fx["name"]
    hook = fx["hook"]
    prompt = fx.get("prompt") or ""
    rag_calls = fx.get("rag_calls") or []
    verify_actions = fx.get("verify_actions") or []
    tool_input = fx["tool_input"]
    expected = fx["expected_exit"]

    # Wipe state between fixtures so they're isolated
    for fn in ("last-prompt.txt", "rag-calls-this-turn.txt",
               "verify-actions-this-turn.jsonl", "current-turn-id.txt",
               "last-rag-search.txt"):
        try: os.remove(os.path.join(state_dir, fn))
        except FileNotFoundError: pass

    # Write prompt
    with open(os.path.join(state_dir, "last-prompt.txt"), "w") as f:
        f.write(prompt + "\n")

    # Write rag calls (kind, body)
    if rag_calls:
        with open(os.path.join(state_dir, "rag-calls-this-turn.txt"), "w") as f:
            for kind, body in rag_calls:
                f.write(f"tid-1\tsearch_docs\t{kind}\t{body}\n")
        with open(os.path.join(state_dir, "current-turn-id.txt"), "w") as f:
            f.write("tid-1\n")

    # Write verify_actions jsonl
    if verify_actions:
        with open(os.path.join(state_dir, "verify-actions-this-turn.jsonl"), "w") as f:
            for va in verify_actions:
                f.write(json.dumps(va) + "\n")

    hook_path = os.path.join(home_fake, ".claude", "hooks", hook)
    env = os.environ.copy()
    env["HOME"] = home_fake
    proc = subprocess.run(
        ["bash", hook_path],
        input=json.dumps(tool_input).encode(),
        env=env, capture_output=True
    )
    ec = proc.returncode
    if ec == expected:
        passed += 1
        print(f"  ok    [{ec}] {name}")
    else:
        failed += 1
        out = (proc.stderr or proc.stdout).decode(errors="replace")
        fails.append((name, expected, ec, out[:240]))
        print(f"  FAIL  [{ec} != {expected}] {name}")

print()
print(f"V17 hooks integration: passed={passed} failed={failed}")
for name, exp, ec, out in fails:
    print(f"  - {name}: expected {exp} got {ec}; out: {out!r}")
sys.exit(0 if failed == 0 else 1)
PYEOF
