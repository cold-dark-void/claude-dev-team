#!/usr/bin/env bash
# test-orch-allowlist.sh — CDT-51 TL P0: greenfield template allow ⊇ matrix set
# Machine-check: bash skills/init-orchestration/test-orch-allowlist.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL="$SCRIPT_DIR/SKILL.md"
PROJECT_INIT="$SCRIPT_DIR/../../agents/project-init.md"

# Matrix probe allow set (docs/runbooks/permission-posture-matrix.md Cell C)
MATRIX_ALLOW=(
  'Bash(*)'
  'Read'
  'Write'
  'Edit'
  'Glob'
  'Grep'
  'Agent'
  'Task'
)

PASS=0
FAIL=0

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing $path"
  fi
}

echo "=== test-orch-allowlist (CDT-51 TL P0 matrix allow) ==="

assert_file "SKILL.md exists" "$SKILL"
assert_file "project-init.md exists" "$PROJECT_INIT"

# ---------- Extract greenfield permissions.allow block from SKILL.md ----------
# Pull the first fenced ```json ... ``` that contains "defaultMode": "dontAsk"
# and collect quoted allow entries between "allow": [ and the closing ].
echo "-- greenfield template ⊇ matrix set"

TEMPLATE_ALLOW=$(python3 - "$SKILL" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# Find json fence containing dontAsk defaultMode (greenfield orch template)
blocks = re.findall(r"```json\n(.*?)```", text, flags=re.S)
chosen = None
for b in blocks:
    if '"defaultMode": "dontAsk"' in b and '"allow"' in b:
        chosen = b
        break
if not chosen:
    print("NO_TEMPLATE", file=sys.stderr)
    sys.exit(2)
# Collect string entries under allow array
m = re.search(r'"allow"\s*:\s*\[(.*?)\]', chosen, flags=re.S)
if not m:
    print("NO_ALLOW", file=sys.stderr)
    sys.exit(2)
entries = re.findall(r'"([^"]+)"', m.group(1))
for e in entries:
    print(e)
PY
)
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$TEMPLATE_ALLOW" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL extract greenfield allow from SKILL.md"
else
  PASS=$((PASS + 1)); echo "  ok  extracted greenfield allow"
fi

for entry in "${MATRIX_ALLOW[@]}"; do
  if printf '%s\n' "$TEMPLATE_ALLOW" | grep -qxF -- "$entry"; then
    PASS=$((PASS + 1)); echo "  ok  template has [$entry]"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL template missing [$entry]"
  fi
done

# ---------- Brownfield merge protocol must require full matrix set ----------
echo "-- brownfield merge protocol"
for needle in \
  'Read' \
  'Write' \
  'Edit' \
  'Glob' \
  'Grep' \
  'Agent' \
  'Task' \
  'matrix set'
do
  if grep -qF -- "$needle" "$SKILL"; then
    PASS=$((PASS + 1)); echo "  ok  skill merge/docs mention [$needle]"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL skill missing merge mention [$needle]"
  fi
done

# Explicit: brownfield line must not be Bash(*)-only
if grep -qE 'permissions\.allow.*contains.*"Bash\(\*\)"' "$SKILL" \
  && ! grep -qF 'every entry from the greenfield template allow list' "$SKILL"; then
  FAIL=$((FAIL + 1)); echo "  FAIL brownfield still Bash(*)-only"
else
  PASS=$((PASS + 1)); echo "  ok  brownfield requires full greenfield allow set"
fi

# ---------- P1: project-init must not claim to BE the orchestration posture ----------
echo "-- project-init Step 1b (P1)"
# Old mislabel: "This is the orchestration posture" — negation "NOT the orchestration posture" is OK
if grep -qE 'This is the orchestration posture' "$PROJECT_INIT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL project-init still claims to be orchestration posture"
else
  PASS=$((PASS + 1)); echo "  ok  project-init does not claim to be orchestration posture"
fi
if grep -qF 'team-bootstrap' "$PROJECT_INIT"; then
  PASS=$((PASS + 1)); echo "  ok  project-init labels team-bootstrap"
else
  FAIL=$((FAIL + 1)); echo "  FAIL project-init missing team-bootstrap label"
fi
if grep -qF 'never clobber' "$PROJECT_INIT" || grep -qF 'leave it' "$PROJECT_INIT"; then
  PASS=$((PASS + 1)); echo "  ok  project-init preserves existing defaultMode"
else
  FAIL=$((FAIL + 1)); echo "  FAIL project-init missing defaultMode preserve rule"
fi
if grep -qF 'orchestration markers' "$PROJECT_INIT"; then
  PASS=$((PASS + 1)); echo "  ok  project-init has orch-marker guard"
else
  FAIL=$((FAIL + 1)); echo "  FAIL project-init missing orch-marker guard"
fi

echo "=== results: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
