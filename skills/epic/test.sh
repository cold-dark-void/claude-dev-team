#!/usr/bin/env bash
# Bite-tests for epic-lib.sh (SPEC-025). Run: bash skills/epic/test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/epic-lib.sh"
DAG="$HERE/../orchestrate/dag-lib.sh"
PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

run_lib() {
  local want="$1"; shift
  set +e
  OUT=$(EPIC_ROOT="${EPIC_ROOT:-}" bash "$LIB" "$@" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq "$want" ]; then pass
  else fail "exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 400; echo
  fi
}

# ---- T0: usage --------------------------------------------------------------
run_lib 64
echo "$OUT" | grep -q Usage && pass || fail "usage text missing"

# ---- isolated root ----------------------------------------------------------
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/epic-test.XXXXXX")
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT
export EPIC_ROOT="$TMPROOT"

run_in() {
  local want="$1"; shift
  set +e
  OUT=$(EPIC_ROOT="$TMPROOT" bash "$LIB" "$@" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq "$want" ]; then pass
  else fail "exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 500; echo
  fi
}

# ---- exists / init ----------------------------------------------------------
run_in 1 exists CDV-30
run_in 64 init
run_in 64 init CDV-30 --title "t"
run_in 0 init CDV-30 --title "umbrella X" --mode kickoff
STATE="$TMPROOT/.claude/epics/CDV-30/state.json"
[ -f "$STATE" ] && pass || fail "state.json missing after init"
python3 -c "import json; d=json.load(open('$STATE')); assert d['epic_id']=='CDV-30'; assert d['execution_mode']=='kickoff'; assert d['children']==[]" \
  && pass || fail "state schema after init"
run_in 0 exists CDV-30
run_in 2 init CDV-30 --title "dup" --mode orchestrate   # refuse if exists

# ---- add-child validation ---------------------------------------------------
run_in 64 add-child CDV-30 --id BAD --slug s --title t --estimate M --agent ic4 --depends-on '[]'
run_in 64 add-child CDV-30 --id CDV-30-C1 --slug s --title t --estimate X --agent ic4 --depends-on '[]'
run_in 64 add-child CDV-30 --id CDV-30-C1 --slug s --title t --estimate M --agent ic9 --depends-on '[]'
run_in 64 add-child CDV-30 --id CDV-30-C1 --slug s --title t --estimate M --agent ic4 --depends-on 'not-json'
run_in 0 add-child CDV-30 --id CDV-30-C1 --slug base --title "Base" --estimate S --agent ic4 \
  --depends-on '[]' --problem "p1" --ac '["a1"]'
run_in 0 add-child CDV-30 --id CDV-30-C2 --slug dep --title "Dep" --estimate M --agent ic5 \
  --depends-on '["CDV-30-C1"]' --problem "p2" --ac '["a2"]'
run_in 2 add-child CDV-30 --id CDV-30-C1 --slug x --title x --estimate S --agent ic4 --depends-on '[]'

N=$(EPIC_ROOT="$TMPROOT" bash "$LIB" show CDV-30 | jq '.counts.total')
[ "$N" = "2" ] && pass || fail "child count want 2 got $N"

# ---- ready-set / waves (before complete) ------------------------------------
READY=$(EPIC_ROOT="$TMPROOT" bash "$LIB" ready-set CDV-30)
[ "$READY" = "CDV-30-C1" ] && pass || fail "ready want C1 got [$READY]"

WAVES=$(EPIC_ROOT="$TMPROOT" bash "$LIB" waves CDV-30)
echo "$WAVES" | grep -q 'Wave 1: CDV-30-C1' && pass || fail "waves wave1: $WAVES"
echo "$WAVES" | grep -q 'Wave 2: CDV-30-C2' && pass || fail "waves wave2: $WAVES"

# ---- set-status / complete unlocks C2 ---------------------------------------
run_in 0 set-status CDV-30 CDV-30-C1 in_progress
READY=$(EPIC_ROOT="$TMPROOT" bash "$LIB" ready-set CDV-30)
[ -z "$READY" ] && pass || fail "no ready while C1 in_progress, got [$READY]"

run_in 0 set-status CDV-30 CDV-30-C1 completed
READY=$(EPIC_ROOT="$TMPROOT" bash "$LIB" ready-set CDV-30)
[ "$READY" = "CDV-30-C2" ] && pass || fail "ready after C1 done want C2 got [$READY]"

# blocked is not completed
run_in 0 set-status CDV-30 CDV-30-C2 blocked
READY=$(EPIC_ROOT="$TMPROOT" bash "$LIB" ready-set CDV-30)
[ -z "$READY" ] && pass || fail "blocked child not ready, got [$READY]"
run_in 0 set-status CDV-30 CDV-30-C2 pending
READY=$(EPIC_ROOT="$TMPROOT" bash "$LIB" ready-set CDV-30)
[ "$READY" = "CDV-30-C2" ] && pass || fail "unblocked ready want C2 got [$READY]"

# ---- mark-done by id and linear_id ------------------------------------------
run_in 0 add-child CDV-30 --id CDV-30-C3 --slug leaf --title "Leaf" --estimate L --agent ic4 \
  --depends-on '["CDV-30-C2"]' --linear-id "LIN-99"
run_in 0 mark-done CDV-30-C2
STAT=$(EPIC_ROOT="$TMPROOT" bash "$LIB" show CDV-30 | jq -r '.children[] | select(.id=="CDV-30-C2") | .status')
[ "$STAT" = "completed" ] && pass || fail "mark-done by id want completed got $STAT"

run_in 0 mark-done LIN-99
STAT=$(EPIC_ROOT="$TMPROOT" bash "$LIB" show CDV-30 | jq -r '.children[] | select(.id=="CDV-30-C3") | .status')
[ "$STAT" = "completed" ] && pass || fail "mark-done by linear_id want completed got $STAT"

# unknown ticket soft-ok
run_in 0 mark-done NO-SUCH-TICKET

# ---- atomic write: no partial JSON ------------------------------------------
# corrupt attempt via direct invalid is rejected by write_state path — probe via
# ensuring state remains valid after many transitions
for i in 1 2 3 4 5; do
  EPIC_ROOT="$TMPROOT" bash "$LIB" set-status CDV-30 CDV-30-C1 completed >/dev/null
done
python3 -c "import json; json.load(open('$STATE'))" && pass || fail "state invalid after transitions"
# no leftover tmp
LEFTOVER=$(find "$TMPROOT/.claude/epics/CDV-30" -name 'state.json.tmp.*' 2>/dev/null | wc -l)
[ "$LEFTOVER" -eq 0 ] && pass || fail "tmp files left behind: $LEFTOVER"

# ---- rollup: only active epics ----------------------------------------------
run_in 0 init CDV-DONE --title "done epic" --mode orchestrate
run_in 0 add-child CDV-DONE --id CDV-DONE-C1 --slug only --title "Only" --estimate S --agent ic4 --depends-on '[]'
run_in 0 set-status CDV-DONE CDV-DONE-C1 completed

run_in 0 init CDV-ACTIVE --title "active epic" --mode kickoff
run_in 0 add-child CDV-ACTIVE --id CDV-ACTIVE-C1 --slug a --title "A" --estimate S --agent ic4 --depends-on '[]'

ROLL=$(EPIC_ROOT="$TMPROOT" bash "$LIB" rollup)
echo "$ROLL" | jq -e 'select(.epic_id=="CDV-ACTIVE")' >/dev/null && pass || fail "rollup missing CDV-ACTIVE"
echo "$ROLL" | jq -e 'select(.epic_id=="CDV-DONE")' >/dev/null && fail "rollup included fully-done epic" || pass
# CDV-30 still has pending? C1 completed, C2 completed, C3 completed → all done
# make one pending on CDV-30 for rollup
run_in 0 set-status CDV-30 CDV-30-C3 pending
ROLL=$(EPIC_ROOT="$TMPROOT" bash "$LIB" rollup)
echo "$ROLL" | jq -e 'select(.epic_id=="CDV-30")' >/dev/null && pass || fail "rollup missing CDV-30 with pending"

# ---- cycle gate via dag-lib (no reimpl in epic-lib) --------------------------
# assert epic-lib has no COLOR/DFS cycle reimplementation
if grep -E 'COLOR\[|WHITE=|GRAY=|BLACK=' "$LIB" >/dev/null; then
  fail "epic-lib reimplements cycle DFS"
else
  pass
fi
grep -q 'dag-lib' "$LIB" && pass || fail "epic-lib should wrap dag-lib"

CYC=$(mktemp "${TMPDIR:-/tmp}/epic-cyc.XXXXXX")
ACYC=$(mktemp "${TMPDIR:-/tmp}/epic-acyc.XXXXXX")
printf '%s\n' '[{"task_id":"CDV-30-C1","depends_on":["CDV-30-C2"]},{"task_id":"CDV-30-C2","depends_on":["CDV-30-C1"]}]' > "$CYC"
printf '%s\n' '[{"task_id":"CDV-30-C1","depends_on":[]},{"task_id":"CDV-30-C2","depends_on":["CDV-30-C1"]}]' > "$ACYC"

set +e
OUT=$(EPIC_ROOT="$TMPROOT" bash "$LIB" check-cycle "$CYC" 2>&1)
RC=$?
set -e
[ "$RC" -eq 1 ] && pass || fail "cyclic check-cycle want exit 1 got $RC"
echo "$OUT" | grep -qi cycle && pass || fail "cycle message missing: $OUT"

set +e
OUT=$(EPIC_ROOT="$TMPROOT" bash "$LIB" check-cycle "$ACYC" 2>&1)
RC=$?
set -e
[ "$RC" -eq 0 ] && pass || fail "acyclic check-cycle want 0 got $RC out=$OUT"

# also direct dag-lib (AC14 — external reuse)
set +e
bash "$DAG" check-cycle "$CYC" >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 1 ] && pass || fail "direct dag-lib cycle want 1 got $RC"

# ---- ID scheme regex --------------------------------------------------------
echo "CDV-30-C1" | grep -Eq '^CDV-30-C[0-9]+$' && pass || fail "ID scheme C1"
echo "CDV-30-2" | grep -Eq '^CDV-30-C[0-9]+$' && fail "within-ticket key must not match -C scheme" || pass

# ---- resume idempotency: exists + show no re-init ---------------------------
run_in 0 exists CDV-30
run_in 0 show CDV-30
echo "$OUT" | jq -e '.epic_id=="CDV-30"' >/dev/null && pass || fail "show resume"
run_in 2 init CDV-30 --title "nope" --mode kickoff

# ---- missing dep keeps non-ready --------------------------------------------
run_in 0 init CDV-MISS --title "miss" --mode kickoff
run_in 0 add-child CDV-MISS --id CDV-MISS-C1 --slug m --title "M" --estimate S --agent ic4 \
  --depends-on '["CDV-MISS-C9"]'
READY=$(EPIC_ROOT="$TMPROOT" bash "$LIB" ready-set CDV-MISS)
[ -z "$READY" ] && pass || fail "missing dep should stay non-ready got [$READY]"

# ---- invalid status ---------------------------------------------------------
run_in 64 set-status CDV-30 CDV-30-C1 bogostate
run_in 1 set-status CDV-30 CDV-30-C99 completed

# ---- orchestrate mode init --------------------------------------------------
run_in 0 init CDV-ORCH --title "orch" --mode orchestrate
MODE=$(EPIC_ROOT="$TMPROOT" bash "$LIB" show CDV-ORCH | jq -r '.execution_mode')
[ "$MODE" = "orchestrate" ] && pass || fail "mode orchestrate got $MODE"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
