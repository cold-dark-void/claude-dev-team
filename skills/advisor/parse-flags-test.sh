#!/usr/bin/env bash
#
# advisor/parse-flags-test.sh — SPEC-039 M9/M10/M11/M12 + AC25 bite-tests.
#
# Machine-check: bash skills/advisor/parse-flags-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
PF="$SCRIPT_DIR/parse-flags.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/advisor-parse-flags-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

run() { # run <env-assignment ignored> — args after
  RC=0
  OUT=$(env "$@" bash "$PF" ${RUN_ARGS:-} 2>"$TMP/err.txt") || RC=$?
  ERR=$(cat "$TMP/err.txt")
}

check() { # check <id> <want_rc> <want_json> <want_err_substr>
  local id=$1 want_rc=$2 want_json=$3 want_err=${4:-}
  local ok=1
  [ "$RC" -eq "$want_rc" ] || ok=0
  [ "$OUT" = "$want_json" ] || ok=0
  if [ -n "$want_err" ]; then
    printf '%s' "$ERR" | grep -F -q -- "$want_err" || ok=0
  fi
  if [ "$ok" -eq 1 ]; then pass "$id"; else
    fail "$id rc=$RC out='$OUT' (want '$want_json') err='$ERR'"
  fi
}

# ---- M9: flag / env / none -------------------------------------------------
RUN_ARGS="--with-advisor" run
check "M9-flag-on" 0 '{"enabled":true,"source":"flag"}' ""

RUN_ARGS="" run
check "M9-default-off" 0 '{"enabled":false,"source":"none"}' ""

RUN_ARGS="" ADVISOR=1 bash "$PF" >/dev/null 2>&1
OUT=$(ADVISOR=1 bash "$PF"); RC=$?
check "M9-env-1" 0 '{"enabled":true,"source":"env"}' ""

OUT=$(ADVISOR=true bash "$PF"); RC=$?
check "M9-env-true" 0 '{"enabled":true,"source":"env"}' ""

OUT=$(ADVISOR=0 bash "$PF"); RC=$?
check "M9-env-0-off" 0 '{"enabled":false,"source":"none"}' ""

OUT=$(ADVISOR=junk bash "$PF"); RC=$?
check "M9-env-junk-off" 0 '{"enabled":false,"source":"none"}' ""

# Flag wins over env (M9).
OUT=$(ADVISOR=0 bash "$PF" --with-advisor); RC=$?
check "M9-flag-wins" 0 '{"enabled":true,"source":"flag"}' ""

# Duplicate --with-advisor -> 64 (M9).
OUT=$(bash "$PF" --with-advisor --with-advisor 2>"$TMP/err.txt"); RC=$?
ERR=$(cat "$TMP/err.txt")
check "M9-duplicate-64" 64 "" "duplicate --with-advisor"

# --advisor (omp host flag) neither enables nor exits 64 (M9).
OUT=$(bash "$PF" --advisor); RC=$?
check "M9-omp-advisor-ignored" 0 '{"enabled":false,"source":"none"}' ""

OUT=$(bash "$PF" --advisor --with-advisor); RC=$?
check "M9-omp-advisor-plus-flag" 0 '{"enabled":true,"source":"flag"}' ""

# Other tokens pass through without error.
OUT=$(bash "$PF" --autopilot some-positional); RC=$?
check "M9-passthrough" 0 '{"enabled":false,"source":"none"}' ""

# ---- autopilot parse-flags stays six-key (M9 MUST NOT add a 7th key) -------
AP="$ROOT/skills/autopilot/parse-flags.sh"
[ -f "$AP" ] && pass "ap-parser-exists" || fail "ap-parser-exists missing"
KEYS=$(bash "$AP" --autopilot 2>/dev/null | jq -r 'keys | length')
if [ "$KEYS" = "6" ]; then pass "ap-parser-six-key"; else fail "ap-parser-six-key: $KEYS keys"; fi
# --with-advisor must pass through the autopilot parser unchanged (exit 0).
if bash "$AP" --with-advisor >/dev/null 2>&1; then pass "ap-parser-with-advisor-passthrough"; else fail "ap-parser-with-advisor-passthrough exited non-zero"; fi
KEYS2=$(bash "$AP" --with-advisor 2>/dev/null | jq -r 'keys | length')
if [ "$KEYS2" = "6" ]; then pass "ap-parser-still-six-key-with-flag"; else fail "ap-parser-still-six-key-with-flag: $KEYS2"; fi

# ---- M10 surfaces: orchestrate + review-and-commit call the sibling parser --
RESOLVE="$ROOT/skills/orchestrate/steps/00-resolve.md"
RAC="$ROOT/skills/review-and-commit/SKILL.md"
grep -qF 'skills/advisor/parse-flags.sh' "$RESOLVE" \
  && pass "orchestrate-wires-sibling-parser" \
  || fail "orchestrate-wires-sibling-parser: 00-resolve.md lacks the sibling parser call"
grep -qF -- '--with-advisor' "$RESOLVE" \
  && pass "orchestrate-arg-doc" \
  || fail "orchestrate-arg-doc: 00-resolve.md lacks --with-advisor"
grep -qF 'skills/advisor/parse-flags.sh' "$RAC" \
  && pass "rac-wires-sibling-parser" \
  || fail "rac-wires-sibling-parser: review-and-commit lacks the sibling parser call"
grep -qF -- '--with-advisor' "$RAC" \
  && pass "rac-arg-doc" \
  || fail "rac-arg-doc: review-and-commit lacks --with-advisor"

# No new commands/*.md for the advisor (M10 / MUST NOT).
if ls "$ROOT"/commands/advisor*.md >/dev/null 2>&1; then
  fail "no-advisor-command-surface: commands/advisor*.md exists"
else
  pass "no-advisor-command-surface"
fi

# Byte-identical off (M11) + first-card enablement (M12) prose present.
grep -qF 'Byte-identical off' "$RESOLVE" && pass "orchestrate-m11-doc" || fail "orchestrate-m11-doc missing"
grep -qF 'M12' "$RESOLVE" && pass "orchestrate-m12-doc" || fail "orchestrate-m12-doc missing"
grep -qF 'Byte-identical off' "$RAC" && pass "rac-m11-doc" || fail "rac-m11-doc missing"

# ---- M10 epic persistence: set-with-advisor + child env inheritance ---------
EPIC_LIB="$ROOT/skills/epic/epic-lib.sh"
grep -qF 'cmd_set_with_advisor' "$EPIC_LIB" \
  && pass "epic-lib-set-with-advisor" \
  || fail "epic-lib-set-with-advisor missing"
grep -qF 'set-with-advisor' "$EPIC_LIB" \
  && pass "epic-lib-dispatch" \
  || fail "epic-lib-dispatch missing"
MODE_B="$ROOT/skills/epic/mode-b-execute.md"
grep -qF 'ADVISOR=1' "$MODE_B" \
  && pass "mode-b-advisor-env" \
  || fail "mode-b-advisor-env missing"
for STEP in 02-scope 06-design 08-execute; do
  if grep -qF 'set-with-advisor' "$ROOT/skills/orchestrate/steps/$STEP.md"; then
    pass "reroute-$STEP-persists-advisor"
  else
    fail "reroute-$STEP-persists-advisor missing"
  fi
done

# epic-lib set-with-advisor behavior against a scratch epic root.
SCRATCH="$TMP/epicroot"
mkdir -p "$SCRATCH/.claude/epics/CDT-999"
cat > "$SCRATCH/.claude/epics/CDT-999/state.json" <<'EOF'
{"epic_id":"CDT-999","title":"t","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","children":[]}
EOF
OUT=$(EPIC_ROOT="$SCRATCH" bash "$EPIC_LIB" set-with-advisor CDT-999 true 2>"$TMP/err.txt"); RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r .with_advisor)" = "true" ] \
  && [ "$(jq -r .with_advisor "$SCRATCH/.claude/epics/CDT-999/state.json")" = "true" ]; then
  pass "epic-lib-set-with-advisor-writes"
else
  fail "epic-lib-set-with-advisor-writes rc=$RC out='$OUT' err=$(cat "$TMP/err.txt")"
fi
OUT=$(EPIC_ROOT="$SCRATCH" bash "$EPIC_LIB" set-with-advisor CDT-999 bogus 2>"$TMP/err.txt"); RC=$?
if [ "$RC" -eq 64 ]; then pass "epic-lib-set-with-advisor-bad-value-64"; else fail "epic-lib-set-with-advisor-bad-value-64 rc=$RC"; fi

# ---- AC25: omp --advisor collision documented ------------------------------
if grep -qF -- '--advisor' "$ROOT/docs/runbooks/omp.md" && grep -qF 'SPEC-039' "$ROOT/docs/runbooks/omp.md"; then
  pass "omp-collision-documented"
else
  fail "omp-collision-documented: docs/runbooks/omp.md lacks the --advisor note"
fi

# ---- AC3/M10 run-level: standalone /epic persists nothing; B.4 fence reads show --
# Standalone /epic (no reroute flag): real epic-lib runs against an untouched
# scratch epic must leave with_advisor absent (AC3 last clause).
SCRATCH2="$TMP/epicroot-standalone"
mkdir -p "$SCRATCH2/.claude/epics/CDT-998"
cat > "$SCRATCH2/.claude/epics/CDT-998/state.json" <<'EOF'
{"epic_id":"CDT-998","title":"s","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","children":[]}
EOF
OUT=$(EPIC_ROOT="$SCRATCH2" bash "$EPIC_LIB" show CDT-998 2>"$TMP/err.txt"); RC=$?
if [ "$RC" -eq 0 ] && ! jq -e 'has("with_advisor")' "$SCRATCH2/.claude/epics/CDT-998/state.json" >/dev/null 2>&1; then
  pass "standalone-epic-show-no-persist"
else
  fail "standalone-epic-show-no-persist rc=$RC (state: $(cat "$SCRATCH2/.claude/epics/CDT-998/state.json" 2>/dev/null))"
fi
mkdir -p "$SCRATCH2/.claude/epics/CDT-998"
jq '.children += [{"id":"CDT-998-A","title":"c","status":"pending","wave":1}]' \
  "$SCRATCH2/.claude/epics/CDT-998/state.json" > "$TMP/st998.tmp" \
  && mv "$TMP/st998.tmp" "$SCRATCH2/.claude/epics/CDT-998/state.json"
OUT=$(EPIC_ROOT="$SCRATCH2" bash "$EPIC_LIB" set-status CDT-998 CDT-998-A in_progress 2>"$TMP/err.txt"); RC=$?
if [ "$RC" -eq 0 ] && [ "$(jq -r '.children[0].status' "$SCRATCH2/.claude/epics/CDT-998/state.json")" = "in_progress" ] \
  && ! jq -e 'has("with_advisor")' "$SCRATCH2/.claude/epics/CDT-998/state.json" >/dev/null 2>&1; then
  pass "standalone-epic-setstatus-no-persist"
else
  fail "standalone-epic-setstatus-no-persist rc=$RC err=$(cat "$TMP/err.txt")"
fi

# B.4 fence-condition runs: the exact two commands mode-b-execute.md B.4 runs,
# against a with_advisor=true epic (must read true) and one without (false).
WA=$(EPIC_ROOT="$SCRATCH" bash "$EPIC_LIB" show CDT-999 | jq -r '.with_advisor // false')
if [ "$WA" = "true" ]; then pass "m10-fence-show-reads-with-advisor"; else fail "m10-fence-show-reads-with-advisor: got '$WA'"; fi
WA2=$(EPIC_ROOT="$SCRATCH2" bash "$EPIC_LIB" show CDT-998 | jq -r '.with_advisor // false')
if [ "$WA2" = "false" ]; then pass "m10-fence-show-default-false"; else fail "m10-fence-show-default-false: got '$WA2'"; fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
