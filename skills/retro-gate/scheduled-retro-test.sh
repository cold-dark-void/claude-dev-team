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
TOKEN=$(bash "$LOCK_SH" acquire "$MROOT")
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$TOKEN" ]; then
  ok "sim acquire"
else
  bad "sim acquire rc=$rc"
fi
REPORT=$(bash "$WRITER" --mroot "$MROOT" --mode all-auto \
  --scanned 5 --skipped 1 --gated 0 --deep 0 \
  --note "smooth / empty candidates" 2>/dev/null)
rc=$?
bash "$LOCK_SH" release "$MROOT" "$TOKEN"
[ "$rc" -eq 0 ] && [ -f "$REPORT" ] && ok "report written: $REPORT" || bad "report write"
case "$REPORT" in /*) ok "absolute report path" ;; *) bad "relative path $REPORT" ;; esac

# 2. Lock held → second acquire skips (rc 2). A non-owner release does not clear it.
TOKEN=$(bash "$LOCK_SH" acquire "$MROOT")
bash "$LOCK_SH" acquire "$MROOT" >/dev/null 2>/dev/null
rc=$?
[ "$rc" -eq 2 ] && ok "lock blocks concurrent" || bad "lock concurrent rc=$rc"
bash "$LOCK_SH" release "$MROOT" "not-the-owner"
bash "$LOCK_SH" acquire "$MROOT" >/dev/null 2>/dev/null
rc=$?
[ "$rc" -eq 2 ] && ok "non-owner release leaves the lock held" || bad "non-owner release rc=$rc"
bash "$LOCK_SH" release "$MROOT" "$TOKEN"

# 3. Empty candidates → short report still written
R=$(bash "$WRITER" --mroot "$MROOT" --mode all-auto \
  --scanned 0 --skipped 0 --gated 0 --deep 0 \
  --note "No sessions to retro." 2>/dev/null)
grep -q 'No sessions to retro' "$R" && ok "empty-set report" || bad "empty-set report"

# 4. Filter 2 still present in commands/retro.md (command-name XML tag)
filter2_present() {  # filter2_present <file>
  grep -qF '<command-name>/[a-z:-]*retro</command-name>' "$1"
}
if filter2_present "$ROOT/commands/retro.md"; then
  ok "Filter 2 present in commands/retro.md"
else
  bad "Filter 2 missing from commands/retro.md"
fi

# 4b. Bite: with the Filter 2 line deleted, filter2_present must report missing
RETRO_COPY="$TMP/retro-no-filter2.md"
grep -vF '<command-name>/[a-z:-]*retro</command-name>' "$ROOT/commands/retro.md" > "$RETRO_COPY"
if filter2_present "$RETRO_COPY"; then
  bad "Filter 2 bite: line still present after deletion"
else
  ok "Filter 2 bite: deletion detected as missing"
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

# 10. Cross-fence (CDT-324): Step 1b holds the lock. Each later exit fence
# writes a report and releases with the owner token. A second acquire is
# refused while the first run is still inside the procedure.
unset GIT_DIR GIT_WORK_TREE
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
REPO="$TMP/repo"
mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" init -q .
RETRO_MD="$ROOT/commands/retro.md"
F_1B=$(fence_nth "$RETRO_MD" '### Step 1b: Scheduled path lock' 1) || F_1B=""
F_2D=$(fence_nth "$RETRO_MD" '### Step 2d: Empty-set guard' 1) || F_2D=""
F_3C=$(fence_nth "$RETRO_MD" '### Step 3c: Early exit if nothing flagged' 1) || F_3C=""
F_6A=$(fence_nth "$RETRO_MD" '### Step 6a: Short-circuit on empty input' 1) || F_6A=""
F_6I=$(fence_nth "$RETRO_MD" '### Step 6i: Scheduled report' 1) || F_6I=""
[ -n "$F_1B" ] && [ -n "$F_2D" ] && [ -n "$F_3C" ] && [ -n "$F_6A" ] && [ -n "$F_6I" ] \
  && ok "exit fences extract" || bad "exit fences extract"

run_fence() {
  fence_exec "$1" "$REPO" "$2" CLAUDE_PLUGIN_ROOT="$ROOT" PDH="$ROOT" "${@:3}"
}

hold_then() { # hold_then <name> <fence> [env...]
  local name="$1" fence="$2"
  shift 2
  rm -rf "$REPO/.claude"
  run_fence "$TMP/hold-$name" "$F_1B" MODE=all AUTO=1
  if [ -f "$REPO/.claude/retro/scheduled.lock" ]; then
    ok "$name: Step 1b leaves the lock held"
  else
    bad "$name: Step 1b did not hold the lock"
    return 0
  fi
  bash "$LOCK_SH" acquire "$REPO" >/dev/null 2>"$TMP/hold-$name.err"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "$name: a second run is refused while the lock is held"
  else
    bad "$name: second acquire rc=$rc"
  fi
  tok=$(sed -n 's/^SCHEDULED_LOCK_TOKEN=//p' "$TMP/hold-$name.out" | head -1)
  run_fence "$TMP/exit-$name" "$fence" MODE=all AUTO=1 SCHEDULED_LOCK_TOKEN="$tok" "$@"
  if grep -q '^Report: ' "$TMP/exit-$name.out"; then
    ok "$name: exit fence writes a report"
  else
    bad "$name: exit fence wrote no report"
  fi
  if [ ! -f "$REPO/.claude/retro/scheduled.lock" ]; then
    ok "$name: exit fence releases the lock"
  else
    bad "$name: exit fence left the lock"
  fi
}

hold_then empty "$F_2D" SESSIONS=
hold_then smooth "$F_3C" FLAGGED_SESSIONS=
hold_then nofindings "$F_6A" CLASSIFIED_PROPOSALS= OBSERVATIONS= TRIAL_DECISIONS=
# One kept NEW row and one parked NEW row. The report applied count is 1.
KEPT=$(printf 'ic5\tNEW\tx\tkeep this rule')
PARKED=$(printf 'pm\tNEW\tx\tparked suggestion')
ACTIONABLE=$(printf '%s\n%s\n' "$KEPT" "$PARKED")
hold_then final "$F_6I" \
  ACTIONABLE_PROPOSALS="$ACTIONABLE" \
  MANUAL_FOLLOWUP="parked suggestion" \
  SUGGESTED=2
REPORT_FINAL=$(sed -n 's/^Report: //p' "$TMP/exit-final.out" | head -1)
if [ -n "$REPORT_FINAL" ] && [ -f "$REPORT_FINAL" ]; then
  applied_body=$(awk '/^## Applied$/{p=1; next} /^## Manual follow-up$/{p=0} p' "$REPORT_FINAL")
  printf '%s\n' "$applied_body" | grep -q 'keep this rule' \
    && ok "final report lists the kept row" || bad "final report missing kept row"
  printf '%s\n' "$applied_body" | grep -q 'parked suggestion' \
    && bad "final report applied section includes a parked row" \
    || ok "final report applied section excludes the parked row"
  grep -q 'Applied: 1' "$REPORT_FINAL" \
    && ok "final report applied count is 1" || bad "final report applied count"
  grep -q 'parked suggestion' "$REPORT_FINAL" \
    && ok "parked row is still in the report follow-up" \
    || bad "parked row missing from the report"
else
  bad "final report path missing"
fi

# 11. An older run's token must not release a lock a later run published,
# and must not delete that run's owner file.
INVOKER="$HERE/invoke-scheduled-report.sh"
ORACE="$TMP/owner-race"
mkdir -p "$ORACE"
TB=$(bash "$LOCK_SH" acquire "$ORACE")
printf '%s\n' "$TB" > "$ORACE/.claude/retro/scheduled.owner"
bash "$INVOKER" --mode all --auto 1 --mroot "$ORACE" --token "old-token" \
  --note "stale run" --summary "stale" >/dev/null
if [ -f "$ORACE/.claude/retro/scheduled.lock" ]; then
  ok "old token does not release the new lock"
else
  bad "old token released the new lock"
fi
cur=$(cat "$ORACE/.claude/retro/scheduled.owner" 2>/dev/null || true)
[ "$cur" = "$TB" ] && ok "old token leaves the new owner file" || bad "owner file changed: ${cur:-empty}"
bash "$INVOKER" --mode all --auto 1 --mroot "$ORACE" --token "$TB" \
  --note "owner" --summary "owner" >/dev/null
if [ ! -f "$ORACE/.claude/retro/scheduled.lock" ]; then
  ok "matching token releases the lock"
else
  bad "matching token left the lock"
fi
if [ ! -f "$ORACE/.claude/retro/scheduled.owner" ]; then
  ok "matching token removes its owner file"
else
  bad "matching token left the owner file"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
