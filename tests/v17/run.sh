#!/bin/bash
# V17 Phase 1 -- runner for fixture-based target-extract tests.
#
# Fixtures live in fixtures.json with base64-encoded command strings
# so the test data file itself does not trip block-destructive when
# being read/edited. This runner decodes the fixtures at execution time
# and exercises extract_targets() against each.
#
# Exit non-zero on any failed assertion.

set -u

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB="${SELF_DIR}/../../hooks/lib/target-extract.sh"
FIX="${SELF_DIR}/fixtures.json"

[[ ! -f "$LIB" ]] && { echo "missing: $LIB"; exit 2; }
[[ ! -f "$FIX" ]] && { echo "missing: $FIX"; exit 2; }

# shellcheck disable=SC1090
source "$LIB"

LIB_PATH="$LIB" FIX_PATH="$FIX" python3 <<'PYEOF'
import base64, json, os, subprocess, sys

with open(os.environ["FIX_PATH"]) as f:
    cases = json.load(f)

passed = failed = 0
fails = []
for case in cases:
    name = case["name"]
    cmd = base64.b64decode(case["cmd_b64"]).decode()
    expected = sorted(set(case["expected"]))
    proc = subprocess.run(
        ["bash", "-c", 'source "$1"; extract_targets "$2"', "_",
         os.environ["LIB_PATH"], cmd],
        capture_output=True, text=True,
    )
    got = sorted(set(line for line in proc.stdout.splitlines() if line))
    if got == expected:
        passed += 1
        print(f"  ok   {name}")
    else:
        failed += 1
        fails.append({
            "name": name,
            "cmd_summary": cmd[:60] + ("..." if len(cmd) > 60 else ""),
            "expected": expected,
            "got": got,
        })
        print(f"  FAIL {name}")

print()
print("=" * 51)
print(f"passed: {passed}   failed: {failed}")
if failed:
    print("---")
    for f in fails:
        print(f"FAIL  {f['name']}")
        print(f"  expected: {f['expected']}")
        print(f"  got:      {f['got']}")
        print()
    sys.exit(1)
PYEOF
