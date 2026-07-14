#!/usr/bin/env bash
# scheduled-retro-test.sh — integration fixtures for CDV-190 scheduled retro
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
WRITER="$HERE/write-scheduled-report.sh"
LOCK_SH="$HERE/scheduled-lock.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MROOT="$TMP/proj"
mkdir -p "$MROOT"

# 1. Simulate --all --auto path: lock + writer → report exists, path on stdout
if bash "$LOCK_SH" acquire "$MROOT"; then
  ok "sim acquire"
else
  bad "sim acquire"
fi
REPORT=$(bash "$WRITER" --mroot "$MROOT" --mode all-auto \
  --scanned 5 --skipped 1 --gated 0 --deep 0 \
  --note "smooth / empty candidates" 2>/dev/null)
rc=$?
bash "$LOCK_SH" release "$MROOT"
[ "$rc" -eq 0 ] && [ -f "$REPORT" ] && ok "report written: $REPORT" || bad "report write"
case "$REPORT" in /*) ok "absolute report path" ;; *) bad "relative path $REPORT" ;; esac

# 2. Lock held → second acquire skips (rc 2)
bash "$LOCK_SH" acquire "$MROOT"
bash "$LOCK_SH" acquire "$MROOT" 2>/dev/null
rc=$?
[ "$rc" -eq 2 ] && ok "lock blocks concurrent" || bad "lock concurrent rc=$rc"
bash "$LOCK_SH" release "$MROOT"

# 3. Empty candidates → short report still written
R=$(bash "$WRITER" --mroot "$MROOT" --mode all-auto \
  --scanned 0 --skipped 0 --gated 0 --deep 0 \
  --note "No sessions to retro." 2>/dev/null)
grep -q 'No sessions to retro' "$R" && ok "empty-set report" || bad "empty-set report"

# 4. Filter 2 still present in commands/retro.md (command-name XML tag)
if grep -qE "command-name.*/[a-z:-]*retro" "$ROOT/commands/retro.md"; then
  ok "Filter 2 present in commands/retro.md"
else
  bad "Filter 2 missing from commands/retro.md"
fi

# 5. Filter 1 still delegated to freshness.sh
if grep -q 'freshness.sh' "$ROOT/commands/retro.md" \
  && grep -qE 'FRESH_RC|AGE.*60|in-progress' "$ROOT/commands/retro.md"; then
  ok "Filter 1 freshness present"
else
  bad "Filter 1 freshness missing"
fi

# 6. Scheduled wire present in commands/retro.md
if grep -q 'write-scheduled-report' "$ROOT/commands/retro.md" \
  && grep -q 'scheduled-lock' "$ROOT/commands/retro.md"; then
  ok "commands/retro.md wires report+lock"
else
  bad "commands/retro.md missing scheduled wire"
fi

# 7. SPEC-012 S1–S9
if grep -q 'Scheduled autonomous retro' "$ROOT/specs/core/SPEC-012-session-retrospective.md" \
  && grep -qE '\| S[1-9] \|' "$ROOT/specs/core/SPEC-012-session-retrospective.md"; then
  ok "SPEC-012 S1–S9 present"
else
  bad "SPEC-012 scheduled section incomplete"
fi

# 8. Runbook present
if [ -f "$ROOT/docs/runbooks/scheduled-retro.md" ] \
  && grep -q 'CronCreate' "$ROOT/docs/runbooks/scheduled-retro.md" \
  && grep -q 'AGENT_WEBHOOK_URL' "$ROOT/docs/runbooks/scheduled-retro.md"; then
  ok "runbook present"
else
  bad "runbook missing/incomplete"
fi

# 9. No transcript bodies contract: report sections only
if ! grep -qiE 'tool_useResult|parentUuid' "$R"; then
  ok "S9 no transcript bodies"
else
  bad "S9 transcript leak"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
