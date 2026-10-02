#!/usr/bin/env bash
# test-plan-home.sh — resume-state finds a plan under absolute $MROOT/.claude/plans.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESUME="$HERE/resume-state.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

if grep -qF 'PLAN_HOME="$MROOT/.claude/plans"' "$RESUME" \
  && grep -qF '"$PLAN_HOME"/*.md' "$RESUME"; then ok
else bad "resume-state.sh does not glob \$MROOT/.claude/plans"; fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/plan-home.XXXXXX")
cleanup() { git -C "$TMP" worktree remove -f "$WT" >/dev/null 2>&1 || true; rm -rf "$TMP" "$WT"; }
WT="${TMP}-wt"
trap cleanup EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q "$TMP"
git -C "$TMP" config user.email t@t.invalid
git -C "$TMP" config user.name t
git -C "$TMP" commit -q --allow-empty -m root
mkdir -p "$TMP/.claude/plans"
cat > "$TMP/.claude/plans/2026-10-01-CDT-PH-plan.md" << 'EOF'
## Tracking
- ticket_id: CDT-PH
- autopilot_on: true
- autopilot_bump: patch
EOF
if git -C "$TMP" worktree add -q -b plan-home "$WT"; then
  OUT=$(cd "$WT" && bash "$RESUME" CDT-PH 2>/dev/null)
  RC=$?
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | jq -e \
    --arg root "$TMP/.claude/plans" \
    '.found == true and .autopilot_on == true and .autopilot_bump == "patch" and (.plan | startswith($root))' \
    >/dev/null; then ok
  else bad "resume from worktree did not find MROOT plan rc=$RC out=$OUT"; fi
else
  bad "git worktree add failed"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
