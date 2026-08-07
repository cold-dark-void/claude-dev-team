#!/usr/bin/env bash
# Bite-tests for epic-lib.sh (SPEC-025) + parse-flags.sh (CDT-141-C1 / M14).
# Run: bash skills/epic/test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/epic-lib.sh"
PARSE="$HERE/parse-flags.sh"
DAG="$HERE/../orchestrate/dag-lib.sh"
PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# expect_rc <want> <desc> <cmd...>
expect_rc() {
  local want=$1 desc=$2; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then pass
  else fail "$desc rc=$rc (want $want)"
  fi
}

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

# ---- linear_project_id (CDT-64 / SPEC-025 M12) ------------------------------
# After init: field present and null (jq only — no python3)
jq -e '.linear_project_id == null' "$STATE" >/dev/null \
  && pass || fail "init linear_project_id want null"

# set → overwrite → --clear → null
run_in 0 set-linear-project CDV-30 proj_abc
jq -e '.linear_project_id == "proj_abc"' "$STATE" >/dev/null \
  && pass || fail "set-linear-project want proj_abc"

run_in 0 set-linear-project CDV-30 proj_xyz
jq -e '.linear_project_id == "proj_xyz"' "$STATE" >/dev/null \
  && pass || fail "overwrite want proj_xyz"

# show surfaces field when set
run_in 0 show CDV-30
echo "$OUT" | jq -e '.linear_project_id=="proj_xyz"' >/dev/null && pass || fail "show linear_project_id when set"

run_in 0 set-linear-project CDV-30 --clear
jq -e '.linear_project_id == null' "$STATE" >/dev/null \
  && pass || fail "--clear want linear_project_id null"

# null keyword and empty also clear
run_in 0 set-linear-project CDV-30 proj_again
run_in 0 set-linear-project CDV-30 null
jq -e '.linear_project_id == null' "$STATE" >/dev/null \
  && pass || fail "null keyword want linear_project_id null"

run_in 0 set-linear-project CDV-30 proj_empty
run_in 0 set-linear-project CDV-30 ""
jq -e '.linear_project_id == null' "$STATE" >/dev/null \
  && pass || fail "empty-string clear want linear_project_id null"

# flag typo must not persist as project id (usage 64)
run_in 64 set-linear-project CDV-30 --clea
jq -e '.linear_project_id == null' "$STATE" >/dev/null \
  && pass || fail "--clea must not write; field still null"

# missing epic → exit 1 (same as read_state / set-status; not die 2)
run_in 1 set-linear-project NO-SUCH-EPIC proj_x

# pre-v1.2.0 legacy state: field *absent* (not null) — show/rollup // null; set creates field
run_in 0 init CDV-LEG --title "Legacy" --mode kickoff
LEGSTATE="$TMPROOT/.claude/epics/CDV-LEG/state.json"
jq 'del(.linear_project_id)' "$LEGSTATE" > "${LEGSTATE}.tmp" && mv "${LEGSTATE}.tmp" "$LEGSTATE"
jq -e 'has("linear_project_id") | not' "$LEGSTATE" >/dev/null \
  && pass || fail "legacy fixture must omit linear_project_id key"
run_in 0 show CDV-LEG
echo "$OUT" | jq -e '.linear_project_id == null' >/dev/null \
  && pass || fail "show on legacy-absent field want null via // null"
run_in 0 add-child CDV-LEG --id CDV-LEG-C1 --slug leg --title "Leg child" --estimate S --agent ic4 \
  --depends-on '[]' --problem "p" --ac '["a"]'
ROLL_LEG=$(EPIC_ROOT="$TMPROOT" bash "$LIB" rollup)
echo "$ROLL_LEG" | jq -e 'select(.epic_id=="CDV-LEG") | .linear_project_id == null' >/dev/null \
  && pass || fail "rollup on legacy-absent field want null"
run_in 0 set-linear-project CDV-LEG proj_from_legacy
jq -e '.linear_project_id == "proj_from_legacy"' "$LEGSTATE" >/dev/null \
  && pass || fail "set on legacy state creates linear_project_id field"
run_in 0 show CDV-LEG
echo "$OUT" | jq -e '.linear_project_id=="proj_from_legacy"' >/dev/null \
  && pass || fail "show after set-on-legacy"
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

# rollup surfaces linear_project_id when set (and null when not)
run_in 0 set-linear-project CDV-ACTIVE proj_rollup
ROLL=$(EPIC_ROOT="$TMPROOT" bash "$LIB" rollup)
echo "$ROLL" | jq -e 'select(.epic_id=="CDV-ACTIVE") | .linear_project_id=="proj_rollup"' >/dev/null \
  && pass || fail "rollup linear_project_id when set"
# CDV-30 was cleared earlier → null key present in rollup object
echo "$ROLL" | jq -e 'select(.epic_id=="CDV-30") | .linear_project_id == null' >/dev/null \
  && pass || fail "rollup linear_project_id null when cleared"

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

# ---- M13 context discipline (CDT-127 / SPEC-025) -----------------------------
# Mechanical seed shape + fail-closed validate; status remains sole SoT.

run_in 0 init M13-E --title "M13 seed epic" --mode kickoff
run_in 0 add-child M13-E --id M13-E-C1 --slug m13a --title "M13 A" --estimate S --agent ic4 \
  --depends-on '[]' --problem "m13-p1" --ac '["m13-ac1"]'
run_in 0 add-child M13-E --id M13-E-C2 --slug m13b --title "M13 B" --estimate M --agent ic5 \
  --depends-on '["M13-E-C1"]' --problem "m13-p2" --ac '["m13-ac2"]'

# outcome_summary round-trip via set-status --outcome
run_in 0 set-status M13-E M13-E-C1 completed --outcome "shipped M13 base"
M13STATE="$TMPROOT/.claude/epics/M13-E/state.json"
jq -e '.children[] | select(.id=="M13-E-C1") | .outcome_summary == "shipped M13 base"' "$M13STATE" >/dev/null \
  && pass || fail "outcome_summary not persisted on completed"
# show surfaces outcome_summary
run_in 0 show M13-E
echo "$OUT" | jq -e '.children[] | select(.id=="M13-E-C1") | .outcome_summary == "shipped M13 base"' >/dev/null \
  && pass || fail "show outcome_summary round-trip"
# --outcome rejected on pending/in_progress
run_in 64 set-status M13-E M13-E-C2 pending --outcome "nope"
run_in 64 set-status M13-E M13-E-C2 in_progress --outcome "nope"

# build-seed happy path: STM headers + epic_id + next_child; writes last_seed_path
run_in 0 build-seed M13-E
SEED_PATH=$(echo "$OUT" | tail -n1)
[ -f "$SEED_PATH" ] && pass || fail "build-seed did not write file: $SEED_PATH"
# headers in order (State now → Through-line → appendix)
awk '
  /^## State now$/ { s=NR }
  /^## Through-line$/ { t=NR }
  /^## appendix$/ { a=NR }
  END { exit (s && t && a && s < t && t < a) ? 0 : 1 }
' "$SEED_PATH" && pass || fail "seed headers missing or out of order"
grep -qE '^epic_id:[[:space:]]*M13-E' "$SEED_PATH" && pass || fail "seed missing epic_id: M13-E"
grep -qE '^next_child:[[:space:]]*M13-E-C2' "$SEED_PATH" && pass || fail "seed missing next_child: M13-E-C2"
grep -qE '^### Next:[[:space:]]*M13-E-C2' "$SEED_PATH" && pass || fail "seed missing ### Next: M13-E-C2"
grep -q 'shipped M13 base' "$SEED_PATH" && pass || fail "seed missing completed outcome_summary"
# validate-seed accepts good packet
run_in 0 validate-seed "$SEED_PATH"
# last_seed_path recorded
jq -e --arg p "$SEED_PATH" '.last_seed_path == $p' "$M13STATE" >/dev/null \
  && pass || fail "build-seed did not set last_seed_path"
run_in 0 show M13-E
echo "$OUT" | jq -e --arg p "$SEED_PATH" '.last_seed_path == $p' >/dev/null \
  && pass || fail "show last_seed_path after build-seed"

# build-seed MUST NOT mark next child in_progress (status remains sole SoT)
STAT=$(jq -r '.children[] | select(.id=="M13-E-C2") | .status' "$M13STATE")
[ "$STAT" = "pending" ] && pass || fail "build-seed mutated next status want pending got $STAT"
# C1 remains completed
STAT=$(jq -r '.children[] | select(.id=="M13-E-C1") | .status' "$M13STATE")
[ "$STAT" = "completed" ] && pass || fail "build-seed mutated C1 status want completed got $STAT"

# validate-seed rejects empty / missing header / missing file
EMPTY_SEED=$(mktemp "${TMPDIR:-/tmp}/epic-empty-seed.XXXXXX")
: > "$EMPTY_SEED"
run_in 1 validate-seed "$EMPTY_SEED"
rm -f "$EMPTY_SEED"
run_in 1 validate-seed "$TMPROOT/no-such-seed.md"
# missing ## State now (other markers present)
BAD_SEED=$(mktemp "${TMPDIR:-/tmp}/epic-bad-seed.XXXXXX")
cat > "$BAD_SEED" <<'EOF'
epic_id: M13-E
next_child: M13-E-C2
## Through-line
- (none)
## appendix
### Next: M13-E-C2
EOF
run_in 1 validate-seed "$BAD_SEED"
# missing ## Through-line
cat > "$BAD_SEED" <<'EOF'
epic_id: M13-E
next_child: M13-E-C2
## State now
- counts: total=0
## appendix
### Next: M13-E-C2
EOF
run_in 1 validate-seed "$BAD_SEED"
# missing ## appendix
cat > "$BAD_SEED" <<'EOF'
epic_id: M13-E
next_child: M13-E-C2
## State now
- counts: total=0
## Through-line
- (none)
EOF
run_in 1 validate-seed "$BAD_SEED"
# missing epic_id / next markers
cat > "$BAD_SEED" <<'EOF'
## State now
- counts: total=0
## Through-line
- (none)
## appendix
### Next: M13-E-C2
EOF
run_in 1 validate-seed "$BAD_SEED"
cat > "$BAD_SEED" <<'EOF'
epic_id: M13-E
## State now
- counts: total=0
## Through-line
- (none)
## appendix
no next marker
EOF
run_in 1 validate-seed "$BAD_SEED"
rm -f "$BAD_SEED"

# legacy state without last_seed_path still show/rollup
run_in 0 init M13-LEG --title "M13 legacy" --mode kickoff
run_in 0 add-child M13-LEG --id M13-LEG-C1 --slug leg --title "Leg" --estimate S --agent ic4 \
  --depends-on '[]' --problem "p" --ac '["a"]'
LEG13="$TMPROOT/.claude/epics/M13-LEG/state.json"
jq 'del(.last_seed_path) | .children |= map(del(.outcome_summary))' "$LEG13" > "${LEG13}.tmp" \
  && mv "${LEG13}.tmp" "$LEG13"
jq -e 'has("last_seed_path") | not' "$LEG13" >/dev/null \
  && pass || fail "legacy fixture must omit last_seed_path"
run_in 0 show M13-LEG
echo "$OUT" | jq -e '.last_seed_path == null' >/dev/null \
  && pass || fail "show on legacy-absent last_seed_path want null"
echo "$OUT" | jq -e '.children[0] | has("outcome_summary") | not or .outcome_summary == null' >/dev/null \
  && pass || fail "show tolerates missing outcome_summary"
ROLL_M13=$(EPIC_ROOT="$TMPROOT" bash "$LIB" rollup)
echo "$ROLL_M13" | jq -e 'select(.epic_id=="M13-LEG") | .last_seed_path == null' >/dev/null \
  && pass || fail "rollup on legacy-absent last_seed_path want null"
# set-last-seed creates field on legacy
run_in 0 set-last-seed M13-LEG /tmp/fake-seed.md
jq -e '.last_seed_path == "/tmp/fake-seed.md"' "$LEG13" >/dev/null \
  && pass || fail "set-last-seed on legacy creates last_seed_path"
run_in 0 set-last-seed M13-LEG --clear
jq -e '.last_seed_path == null' "$LEG13" >/dev/null \
  && pass || fail "set-last-seed --clear want null"

# build-seed fail-closed: zero children → exit 1, no seed file
run_in 0 init M13-Z --title "zero kids" --mode kickoff
run_in 1 build-seed M13-Z
[ ! -d "$TMPROOT/.claude/epics/M13-Z/seeds" ] \
  && pass || {
    # dir may exist empty; require no .md
    NSEED=$(find "$TMPROOT/.claude/epics/M13-Z/seeds" -name '*.md' 2>/dev/null | wc -l)
    [ "$NSEED" -eq 0 ] && pass || fail "zero-child build-seed wrote seed files"
  }

# ---- Protocol greps (CDT-127 T6 / SPEC-025 M8,M11,M13) -----------------------
SKILL="$HERE/SKILL.md"
CMD="$HERE/../../commands/epic.md"
[ -f "$SKILL" ] || fail "skills/epic/SKILL.md missing"

if [ -f "$SKILL" ]; then
  # M8: no skip-PM path (mandatory PM; no enablement flag)
  grep -q 'no skip-PM path' "$SKILL" \
    && pass || fail "SKILL missing 'no skip-PM path' (M8)"
  if grep -nE -- '--skip-pm|SKIP_PM=|skip_pm' "$SKILL" ${CMD:+"$CMD"} 2>/dev/null; then
    fail "skip-PM enablement path still present (M8)"
  else
    pass
  fi

  # M13 present + fail-closed halt string
  grep -q 'M13' "$SKILL" \
    && pass || fail "SKILL missing M13"
  grep -q 'context-discipline: seed failed' "$SKILL" \
    && pass || fail "SKILL missing fail-closed string 'context-discipline: seed failed'"

  # Guardrail + measurement + CDT-126 non-goal (M13.5 / AC2 / M13.9)
  grep -q '400k' "$SKILL" \
    && pass || fail "SKILL missing 400k guardrail threshold"
  grep -qE 'ε[[:space:]]*=[[:space:]]*0\.5' "$SKILL" \
    && pass || fail "SKILL missing ε = 0.5 measurement target"
  grep -q 'CDT-126 non-goal' "$SKILL" \
    && pass || fail "SKILL missing CDT-126 non-goal note"

  # No dual status SoT + M11 still holds under M13
  grep -q 'no dual status SoT' "$SKILL" \
    && pass || fail "SKILL missing no dual status SoT (M13.2a)"
  grep -q 'M11 under M13' "$SKILL" \
    && pass || fail "SKILL missing 'M11 under M13' preservation note"
  grep -q 'What /epic MUST NOT do (M11)' "$SKILL" \
    && pass || fail "SKILL missing M11 MUST NOT section"

  # CDT-141-C1 / M14 protocol presence
  grep -q 'Step 0.4: Worktree / release flags' "$SKILL" \
    && pass || fail "SKILL missing Step 0.4 worktree/release flags"
  grep -q 'skills/epic/parse-flags.sh' "$SKILL" \
    && pass || fail "SKILL missing parse-flags.sh reference"
  # CDT-141-C2: ensure-integration-worktree wire + M11 carve-out
  grep -q 'ensure-integration-worktree' "$SKILL" \
    && pass || fail "SKILL missing ensure-integration-worktree"
  grep -q 'M11 carve-out' "$SKILL" \
    && pass || fail "SKILL missing M11 carve-out for integration WT"
  # A.6 real init fence must wire INIT_EXTRA + ensure after init
  A6_BLOCK=$(awk '/^### A\.6 Persist/,/^#### Dual-write persistence/' "$SKILL")
  echo "$A6_BLOCK" | grep -qE 'INIT_EXTRA|--worktree-enabled' \
    && pass || fail "A.6 init fence missing INIT_EXTRA/--worktree-enabled"
  echo "$A6_BLOCK" | grep -q 'ensure-integration-worktree' \
    && pass || fail "A.6 missing ensure-integration-worktree after init"
  # M4.1 link-before-create: inventory parent children; adopt/halt; no blind create
  grep -q 'M4.1 Link-before-create' "$SKILL" \
    && pass || fail "SKILL missing M4.1 Link-before-create section"
  grep -q 'parentId' "$SKILL" \
    && pass || fail "SKILL missing list_issues parentId inventory (M4.1)"
  grep -q 'refusing duplicate create' "$SKILL" \
    && pass || fail "SKILL missing M4.1 HALT duplicate-create line"
  grep -q 'Adopted N existing Linear child' "$SKILL" \
    && pass || fail "SKILL missing M4.1 adopt advisory line"
  grep -q 'MUST NOT force-create under autopilot' "$SKILL" \
    && pass || fail "SKILL missing M4.1 autopilot no force-create"
  # B.1 resume must ensure when state enabled
  B1_BLOCK=$(awk '/^### B\.1 Rollup/,/^### B\.2 /' "$SKILL")
  echo "$B1_BLOCK" | grep -q 'ensure-integration-worktree' \
    && pass || fail "B.1 missing ensure-integration-worktree on resume"
  # CDT-141-C6: resolve-resume-flags + conflict policy documented
  grep -q 'resolve-resume-flags' "$SKILL" \
    && pass || fail "SKILL missing resolve-resume-flags"
  grep -q 'Resume flag-vs-state policy' "$SKILL" \
    && pass || fail "SKILL missing Resume flag-vs-state policy (C6)"
  grep -q 'Honor store' "$SKILL" \
    && pass || fail "SKILL missing Honor store (C6)"
  grep -q -- '--worktree' "$SKILL" \
    && pass || fail "SKILL Arguments missing --worktree"
  grep -q -- '--release' "$SKILL" \
    && pass || fail "SKILL Arguments missing --release"
fi

# ---- CDT-141-C1 / M14: parse-flags.sh --------------------------------------
if [ -f "$PARSE" ]; then pass; else fail "parse-flags.sh missing"; fi
bash -n "$PARSE" && pass || fail "parse-flags.sh bash -n"

# (pf1) no flags → worktree false, release null
OUT=$(bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.worktree_enabled==false and .release_bump==null' >/dev/null; then
  pass
else
  fail "pf1 no flags → false/null (rc=$RC out=$OUT)"
fi

# (pf2) bare --worktree
OUT=$(bash "$PARSE" --worktree 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump==null' >/dev/null; then
  pass
else
  fail "pf2 bare --worktree (rc=$RC out=$OUT)"
fi

# (pf3) --worktree --release patch (space form)
OUT=$(bash "$PARSE" --worktree --release patch 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump=="patch"' >/dev/null; then
  pass
else
  fail "pf3 space --release patch (rc=$RC out=$OUT)"
fi

# (pf4) --release=minor alias + --worktree (order independence)
OUT=$(bash "$PARSE" CDT-99 --release=minor --worktree 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump=="minor"' >/dev/null; then
  pass
else
  fail "pf4 =alias order (rc=$RC out=$OUT)"
fi

# (pf5) --release without --worktree → 64
expect_rc 64 "pf5 --release without --worktree" bash "$PARSE" --release patch

# (pf6) bare --release → 64
expect_rc 64 "pf6 bare --release" bash "$PARSE" --worktree --release

# (pf7) illegal bump → 64
expect_rc 64 "pf7 illegal bump" bash "$PARSE" --worktree --release huge

# (pf8) --release each|end → 64
expect_rc 64 "pf8 --release each" bash "$PARSE" --worktree --release each
expect_rc 64 "pf8b --release end" bash "$PARSE" --worktree --release end

# (pf9) --worktree=mode → 64
expect_rc 64 "pf9 --worktree=shared" bash "$PARSE" --worktree=shared

# (pf10) rejected aliases
expect_rc 64 "pf10 --bump" bash "$PARSE" --bump patch
expect_rc 64 "pf10b --land" bash "$PARSE" --land
expect_rc 64 "pf10c --seal" bash "$PARSE" --seal

# (pf11) duplicates → 64
expect_rc 64 "pf11 dup --worktree" bash "$PARSE" --worktree --worktree
expect_rc 64 "pf11b dup --release" bash "$PARSE" --worktree --release patch --release minor

# (pf12) restricted subcommands
expect_rc 64 "pf12 status --worktree" bash "$PARSE" status CDT-1 --worktree
expect_rc 64 "pf12b complete --release" bash "$PARSE" complete CDT-1 CDT-1-C1 --worktree --release patch
expect_rc 64 "pf12c sync --worktree" bash "$PARSE" sync CDT-1 --worktree
expect_rc 64 "pf12c block --worktree" bash "$PARSE" block X Y --worktree
expect_rc 64 "pf12d unblock --worktree" bash "$PARSE" unblock X Y --worktree

# (pf13) orthogonal --autopilot coexistence
OUT=$(bash "$PARSE" --worktree --release major --autopilot=patch CDT-1 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump=="major"' >/dev/null; then
  pass
else
  fail "pf13 autopilot coexist (rc=$RC out=$OUT)"
fi

# (pf14) --redecompose path allows flags
OUT=$(bash "$PARSE" --redecompose CDT-1 --worktree --release patch 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump=="patch"' >/dev/null; then
  pass
else
  fail "pf14 redecompose allows flags (rc=$RC out=$OUT)"
fi

# (pf15) JSON shape keys only the two M14 fields
OUT=$(bash "$PARSE" --worktree 2>/dev/null)
echo "$OUT" | jq -e 'keys | sort == ["release_bump","worktree_enabled"]' >/dev/null \
  && pass || fail "pf15 JSON keys shape"

# ---- CDT-141-C1: init persists modes when set; default omits keys ----------
WT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/epic-wt.XXXXXX")
run_wt() {
  local want="$1"; shift
  set +e
  OUT=$(EPIC_ROOT="$WT_TMP" bash "$LIB" "$@" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq "$want" ]; then pass
  else fail "exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 400; echo
  fi
}

# default init — no M14 keys
run_wt 0 init CDV-WT-DEF --title "def" --mode kickoff
DEF_STATE="$WT_TMP/.claude/epics/CDV-WT-DEF/state.json"
jq -e '(has("worktree_enabled") | not) and (has("release_bump") | not)' "$DEF_STATE" >/dev/null \
  && pass || fail "default init must omit worktree_enabled/release_bump"
# show defaults false/null
run_wt 0 show CDV-WT-DEF
echo "$OUT" | jq -e '.worktree_enabled==false and .release_bump==null' >/dev/null \
  && pass || fail "show defaults worktree_enabled=false release_bump=null"

# worktree only
run_wt 0 init CDV-WT-ONLY --title "wt" --mode orchestrate --worktree-enabled true
WT_STATE="$WT_TMP/.claude/epics/CDV-WT-ONLY/state.json"
jq -e '.worktree_enabled==true and .release_bump==null' "$WT_STATE" >/dev/null \
  && pass || fail "init --worktree-enabled true → true/null"

# worktree + release
run_wt 0 init CDV-WT-REL --title "rel" --mode orchestrate --worktree-enabled true --release-bump minor
REL_STATE="$WT_TMP/.claude/epics/CDV-WT-REL/state.json"
jq -e '.worktree_enabled==true and .release_bump=="minor"' "$REL_STATE" >/dev/null \
  && pass || fail "init worktree+release-bump minor"

# release without worktree → 64, no state
run_wt 64 init CDV-WT-BAD --title "bad" --mode kickoff --release-bump patch
[ ! -f "$WT_TMP/.claude/epics/CDV-WT-BAD/state.json" ] \
  && pass || fail "illegal init must not create state"

# docs: commands surface documents flags; rejects banned names as public options
CMD="$HERE/../../commands/epic.md"
if [ -f "$CMD" ]; then
  grep -q -- '--worktree' "$CMD" && pass || fail "commands/epic.md missing --worktree"
  grep -q -- '--release' "$CMD" && pass || fail "commands/epic.md missing --release"
  # banned flags must not appear as accepted args (allow "reject" prose)
  if grep -nE '^\| `\[--bump\]|^\| `\[--land\]|^\| `\[--seal\]' "$CMD" >/dev/null 2>&1; then
    fail "commands/epic.md documents banned --bump/--land/--seal"
  else
    pass
  fi
fi

rm -rf "$WT_TMP"

# ---- CDT-141-C2: ensure-integration-worktree --------------------------------
# Isolated git repo so worktree-lib create/reuse is real (slug epic-<ID>).
C2_TMP=$(mktemp -d "${TMPDIR:-/tmp}/epic-c2.XXXXXX")
c2_cleanup() { rm -rf "$C2_TMP"; }
# chain with prior cleanup if any — TMPROOT also cleaned by trap; stack handlers
trap 'rm -rf "$C2_TMP"; cleanup' EXIT

git init -q "$C2_TMP" || { fail "c2 git init"; C2_TMP=""; }
if [ -n "$C2_TMP" ] && [ -d "$C2_TMP/.git" ]; then
  git -C "$C2_TMP" config user.email "test@example.com"
  git -C "$C2_TMP" config user.name "Test"
  git -C "$C2_TMP" commit --allow-empty -q -m "init"

  run_c2() {
    local want="$1"; shift
    set +e
    # worktree-lib resolves MROOT from CWD git; EPIC_ROOT holds state
    OUT=$(cd "$C2_TMP" && EPIC_ROOT="$C2_TMP" bash "$LIB" "$@" 2>&1)
    RC=$?
    set -e
    if [ "$RC" -eq "$want" ]; then pass
    else fail "c2 exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 500; echo
    fi
  }

  # (c2-1) worktree_enabled false / absent → no-op, no .worktrees/epic-*
  run_c2 0 init CDV-C2-OFF --title "off" --mode kickoff
  run_c2 0 ensure-integration-worktree CDV-C2-OFF
  echo "$OUT" | jq -e '.worktree_enabled==false and .integration_path==null' >/dev/null \
    && pass || fail "c2-1 no-op JSON (out=$OUT)"
  EPIC_N=$(find "$C2_TMP/.worktrees" -maxdepth 1 -type d -name 'epic-*' 2>/dev/null | wc -l)
  [ "$EPIC_N" -eq 0 ] && pass || fail "c2-1 must not create epic-* worktree (n=$EPIC_N)"
  jq -e '(has("integration_path") | not) or .integration_path==null' \
    "$C2_TMP/.claude/epics/CDV-C2-OFF/state.json" >/dev/null \
    && pass || fail "c2-1 state must not record integration_path"

  # (c2-2) worktree_enabled true → create exactly one epic-<ID> + branch + state
  run_c2 0 init CDV-C2-ON --title "on" --mode orchestrate --worktree-enabled true
  run_c2 0 ensure-integration-worktree CDV-C2-ON
  echo "$OUT" | jq -e '
    .worktree_enabled==true
    and .integration_slug=="epic-CDV-C2-ON"
    and .integration_branch=="feat/epic-CDV-C2-ON"
    and (.integration_path | type=="string" and length>0)
    and .reused==false
  ' >/dev/null && pass || fail "c2-2 create JSON (out=$OUT)"
  INT_PATH=$(echo "$OUT" | jq -r .integration_path)
  [ -d "$INT_PATH" ] && pass || fail "c2-2 path missing: $INT_PATH"
  [ "$INT_PATH" = "$C2_TMP/.worktrees/epic-CDV-C2-ON" ] \
    && pass || fail "c2-2 path want $C2_TMP/.worktrees/epic-CDV-C2-ON got $INT_PATH"
  git -C "$C2_TMP" rev-parse --verify --quiet refs/heads/feat/epic-CDV-C2-ON >/dev/null \
    && pass || fail "c2-2 branch feat/epic-CDV-C2-ON missing"
  # branch != master and != per-child feat/<child>
  BR=$(git -C "$INT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ "$BR" = "feat/epic-CDV-C2-ON" ] && pass || fail "c2-2 HEAD branch want feat/epic-CDV-C2-ON got $BR"
  case "$BR" in master|main|feat/CDV-C2-ON-C*) fail "c2-2 branch collides with master/child: $BR" ;; esac
  ON_STATE="$C2_TMP/.claude/epics/CDV-C2-ON/state.json"
  jq -e '
    .integration_slug=="epic-CDV-C2-ON"
    and .integration_branch=="feat/epic-CDV-C2-ON"
    and .integration_path != null
  ' "$ON_STATE" >/dev/null && pass || fail "c2-2 state missing integration fields"
  EPIC_N=$(find "$C2_TMP/.worktrees" -maxdepth 1 -type d -name 'epic-*' 2>/dev/null | wc -l)
  [ "$EPIC_N" -eq 1 ] && pass || fail "c2-2 want exactly 1 epic-* dir got $EPIC_N"

  # show surfaces fields
  run_c2 0 show CDV-C2-ON
  echo "$OUT" | jq -e '
    .integration_slug=="epic-CDV-C2-ON"
    and .integration_branch=="feat/epic-CDV-C2-ON"
    and (.integration_path | type=="string")
  ' >/dev/null && pass || fail "c2-2 show integration fields"

  # (c2-3) re-invoke → reuse same path/branch; still one tree; reused=true
  PATH1="$INT_PATH"
  run_c2 0 ensure-integration-worktree CDV-C2-ON
  echo "$OUT" | jq -e --arg p "$PATH1" '
    .reused==true
    and .integration_path==$p
    and .integration_slug=="epic-CDV-C2-ON"
    and .integration_branch=="feat/epic-CDV-C2-ON"
  ' >/dev/null && pass || fail "c2-3 reuse JSON (out=$OUT)"
  EPIC_N=$(find "$C2_TMP/.worktrees" -maxdepth 1 -type d -name 'epic-*' 2>/dev/null | wc -l)
  [ "$EPIC_N" -eq 1 ] && pass || fail "c2-3 still exactly 1 epic-* dir got $EPIC_N"
  # third call still one
  run_c2 0 ensure-integration-worktree CDV-C2-ON
  EPIC_N=$(find "$C2_TMP/.worktrees" -maxdepth 1 -type d -name 'epic-*' 2>/dev/null | wc -l)
  [ "$EPIC_N" -eq 1 ] && pass || fail "c2-3 third ensure still 1 epic-* got $EPIC_N"

  # (c2-4) usage: missing epic id → 64; unknown epic → 1
  run_c2 64 ensure-integration-worktree
  run_c2 1 ensure-integration-worktree NO-SUCH-EPIC

  # (c2-5) explicit worktree_enabled false still no-create
  run_c2 0 init CDV-C2-EXPL --title "expl" --mode kickoff --worktree-enabled false
  run_c2 0 ensure-integration-worktree CDV-C2-EXPL
  echo "$OUT" | jq -e '.worktree_enabled==false and .integration_path==null' >/dev/null \
    && pass || fail "c2-5 explicit false no-op"
  [ ! -d "$C2_TMP/.worktrees/epic-CDV-C2-EXPL" ] \
    && pass || fail "c2-5 must not create epic-CDV-C2-EXPL"

  # ---- CDT-141-C3: children share integration tree --------------------------
  # Mock worktree-lib: log ensure calls; create slug dir under C2_TMP.
  C3_MOCK="$C2_TMP/mock-wt-lib.sh"
  C3_LOG="$C2_TMP/ensure-calls.log"
  : >"$C3_LOG"
  cat >"$C3_MOCK" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
# EPIC_WT_LIB mock — records ensure <slug>; never real git worktree.
ROOT="${MOCK_WT_ROOT:?}"
LOG="${MOCK_WT_LOG:?}"
cmd="${1:-}"
slug="${2:-}"
case "$cmd" in
  ensure)
    echo "ensure:$slug" >>"$LOG"
    mkdir -p "$ROOT/.worktrees/$slug"
    printf '%s\n' "$ROOT/.worktrees/$slug"
    ;;
  release)
    echo "release:$slug" >>"$LOG"
    ;;
  *)
    echo "mock-wt-lib: unknown $cmd" >&2
    exit 64
    ;;
esac
MOCK
  chmod +x "$C3_MOCK"

  run_c3() {
    local want="$1"; shift
    set +e
    OUT=$(cd "$C2_TMP" && EPIC_ROOT="$C2_TMP" EPIC_WT_LIB="$C3_MOCK" \
      MOCK_WT_ROOT="$C2_TMP" MOCK_WT_LOG="$C3_LOG" \
      bash "$LIB" "$@" 2>&1)
    RC=$?
    set -e
    if [ "$RC" -eq "$want" ]; then pass
    else fail "c3 exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 500; echo
    fi
  }

  # (c3-1) unknown ticket → use_shared false, skip_release false
  run_c3 0 resolve-child-worktree CDV-UNKNOWN-C1
  echo "$OUT" | jq -e '
    .use_shared==false and .is_epic_child==false
    and .skip_ensure==false and .skip_release==false
    and .integration_path==null
  ' >/dev/null && pass || fail "c3-1 unknown (out=$OUT)"

  # (c3-2) child of non-worktree epic → not shared; ensure still calls child slug
  run_c3 0 init CDV-C3-OFF --title "off" --mode orchestrate
  run_c3 0 add-child CDV-C3-OFF --id CDV-C3-OFF-C1 --slug s1 --title t1 \
    --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
  run_c3 0 resolve-child-worktree CDV-C3-OFF-C1
  echo "$OUT" | jq -e '
    .is_epic_child==true and .epic_id=="CDV-C3-OFF"
    and .worktree_enabled==false and .use_shared==false
    and .skip_ensure==false and .skip_release==false
  ' >/dev/null && pass || fail "c3-2 non-wt child resolve (out=$OUT)"
  : >"$C3_LOG"
  run_c3 0 ensure-ticket-worktree CDV-C3-OFF-C1
  [ "$OUT" = "$C2_TMP/.worktrees/CDV-C3-OFF-C1" ] \
    && pass || fail "c3-2 default path want child worktree got $OUT"
  grep -qx 'ensure:CDV-C3-OFF-C1' "$C3_LOG" \
    && pass || fail "c3-2 must call ensure for child slug (log=$(cat "$C3_LOG"))"
  [ -d "$C2_TMP/.worktrees/CDV-C3-OFF-C1" ] \
    && pass || fail "c3-2 child worktree dir missing"

  # (c3-3) worktree_enabled + integration → shared; ensure NOT called for child
  run_c3 0 init CDV-C3-ON --title "on" --mode orchestrate --worktree-enabled true
  # plant integration path (skip real ensure-integration; set state fields)
  INT_DIR="$C2_TMP/.worktrees/epic-CDV-C3-ON"
  mkdir -p "$INT_DIR"
  jq '.worktree_enabled=true
      | .integration_slug="epic-CDV-C3-ON"
      | .integration_path="'"$INT_DIR"'"
      | .integration_branch="feat/epic-CDV-C3-ON"' \
    "$C2_TMP/.claude/epics/CDV-C3-ON/state.json" >"$C2_TMP/c3-on-state.tmp"
  mv "$C2_TMP/c3-on-state.tmp" "$C2_TMP/.claude/epics/CDV-C3-ON/state.json"
  run_c3 0 add-child CDV-C3-ON --id CDV-C3-ON-C1 --slug s1 --title t1 \
    --estimate M --agent ic5 --depends-on '[]' --problem p --ac '["a"]'
  run_c3 0 add-child CDV-C3-ON --id CDV-C3-ON-C2 --slug s2 --title t2 \
    --estimate S --agent ic4 --depends-on '["CDV-C3-ON-C1"]' --problem p --ac '["a"]'

  run_c3 0 resolve-child-worktree CDV-C3-ON-C1
  echo "$OUT" | jq -e --arg p "$INT_DIR" '
    .is_epic_child==true and .epic_id=="CDV-C3-ON"
    and .worktree_enabled==true and .use_shared==true
    and .integration_path==$p
    and .integration_slug=="epic-CDV-C3-ON"
    and .integration_branch=="feat/epic-CDV-C3-ON"
    and .skip_ensure==true and .skip_release==true
    and .source=="epic_state"
  ' >/dev/null && pass || fail "c3-3 resolve shared (out=$OUT)"

  : >"$C3_LOG"
  run_c3 0 ensure-ticket-worktree CDV-C3-ON-C1
  [ "$OUT" = "$INT_DIR" ] && pass || fail "c3-3 path want $INT_DIR got $OUT"
  if [ -s "$C3_LOG" ]; then
    fail "c3-3 must NOT call worktree-lib ensure (log=$(cat "$C3_LOG"))"
  else
    pass
  fi
  [ ! -d "$C2_TMP/.worktrees/CDV-C3-ON-C1" ] \
    && pass || fail "c3-3 must not create per-child worktree"

  # second child same path, still no ensure
  : >"$C3_LOG"
  run_c3 0 ensure-ticket-worktree CDV-C3-ON-C2
  [ "$OUT" = "$INT_DIR" ] && pass || fail "c3-3b C2 same path got $OUT"
  [ ! -s "$C3_LOG" ] && pass || fail "c3-3b C2 must not ensure (log=$(cat "$C3_LOG"))"
  [ ! -d "$C2_TMP/.worktrees/CDV-C3-ON-C2" ] \
    && pass || fail "c3-3b no per-child C2 tree"

  # (c3-4) linear_id match also resolves
  jq '(.children[] | select(.id=="CDV-C3-ON-C1") | .linear_id) = "LIN-999"' \
    "$C2_TMP/.claude/epics/CDV-C3-ON/state.json" >"$C2_TMP/c3-lin.tmp"
  mv "$C2_TMP/c3-lin.tmp" "$C2_TMP/.claude/epics/CDV-C3-ON/state.json"
  run_c3 0 resolve-child-worktree LIN-999
  echo "$OUT" | jq -e '.use_shared==true and .epic_id=="CDV-C3-ON"' >/dev/null \
    && pass || fail "c3-4 linear_id resolve (out=$OUT)"

  # (c3-5) EPIC_INTEGRATION_PATH env alone (no epic child) → shared, no ensure
  ENV_INT="$C2_TMP/.worktrees/env-integration"
  mkdir -p "$ENV_INT"
  : >"$C3_LOG"
  set +e
  OUT=$(cd "$C2_TMP" && EPIC_ROOT="$C2_TMP" EPIC_WT_LIB="$C3_MOCK" \
    MOCK_WT_ROOT="$C2_TMP" MOCK_WT_LOG="$C3_LOG" \
    EPIC_INTEGRATION_PATH="$ENV_INT" \
    bash "$LIB" ensure-ticket-worktree FREEFORM-1 2>&1)
  RC=$?
  set -e
  [ "$RC" -eq 0 ] && pass || fail "c3-5 env path rc=$RC"
  [ "$OUT" = "$ENV_INT" ] && pass || fail "c3-5 env path want $ENV_INT got $OUT"
  [ ! -s "$C3_LOG" ] && pass || fail "c3-5 env must not ensure (log=$(cat "$C3_LOG"))"

  # (c3-6) usage errors
  run_c3 64 resolve-child-worktree
  run_c3 64 ensure-ticket-worktree
  run_c3 64 resolve-child-worktree A B

  # (c3-7) skip_release flag stable for wrap-ticket consumers
  run_c3 0 resolve-child-worktree CDV-C3-ON-C1
  echo "$OUT" | jq -e '.skip_release==true' >/dev/null \
    && pass || fail "c3-7 skip_release true for shared child"
  run_c3 0 resolve-child-worktree CDV-C3-OFF-C1
  echo "$OUT" | jq -e '.skip_release==false' >/dev/null \
    && pass || fail "c3-7 skip_release false for non-shared child"

  # ---- CDT-141-C6: resolve-resume-flags (honor store / conflict 64) ---------
  run_c6() {
    local want="$1"; shift
    set +e
    OUT=$(cd "$C2_TMP" && EPIC_ROOT="$C2_TMP" EPIC_WT_LIB="$C3_MOCK" \
      MOCK_WT_ROOT="$C2_TMP" MOCK_WT_LOG="$C3_LOG" \
      bash "$LIB" "$@" 2>&1)
    RC=$?
    set -e
    if [ "$RC" -eq "$want" ]; then pass
    else fail "c6 exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 500; echo
    fi
  }

  # (c6-1) defaults path: no M14 keys, flags omitted → false/null (resume unchanged)
  run_c6 0 init CDV-C6-DEF --title "def" --mode orchestrate
  run_c6 0 resolve-resume-flags CDV-C6-DEF -- CDV-C6-DEF
  echo "$OUT" | jq -e '.worktree_enabled==false and .release_bump==null' >/dev/null \
    && pass || fail "c6-1 defaults honor (out=$OUT)"
  # ensure still no-op; no epic-* for this id
  run_c6 0 ensure-integration-worktree CDV-C6-DEF
  echo "$OUT" | jq -e '.worktree_enabled==false and .integration_path==null' >/dev/null \
    && pass || fail "c6-1 defaults ensure no-op"
  [ ! -d "$C2_TMP/.worktrees/epic-CDV-C6-DEF" ] \
    && pass || fail "c6-1 must not create integration tree"

  # (c6-2) honor store: wt+release patch, flags omitted → true/patch (no silent clear)
  run_c6 0 init CDV-C6-ON --title "on" --mode orchestrate \
    --worktree-enabled true --release-bump patch
  run_c6 0 resolve-resume-flags CDV-C6-ON -- CDV-C6-ON
  echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump=="patch"' >/dev/null \
    && pass || fail "c6-2 honor store omit flags (out=$OUT)"
  # bare resume (no positionals either) still honors
  run_c6 0 resolve-resume-flags CDV-C6-ON
  echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump=="patch"' >/dev/null \
    && pass || fail "c6-2 honor store empty argv (out=$OUT)"

  # (c6-3) flags present and match → OK
  run_c6 0 resolve-resume-flags CDV-C6-ON -- --worktree --release patch
  echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump=="patch"' >/dev/null \
    && pass || fail "c6-3 match flags (out=$OUT)"
  run_c6 0 resolve-resume-flags CDV-C6-ON -- CDV-C6-ON --worktree --release=patch
  echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump=="patch"' >/dev/null \
    && pass || fail "c6-3 match =alias (out=$OUT)"

  # (c6-4) conflict hard-fail 64 — no silent downgrade of end-release
  # --worktree alone would null release_bump vs stored patch
  run_c6 64 resolve-resume-flags CDV-C6-ON -- --worktree
  echo "$OUT" | grep -qi 'conflict' \
    && pass || fail "c6-4 conflict stderr for --worktree alone (out=$OUT)"
  # wrong bump
  run_c6 64 resolve-resume-flags CDV-C6-ON -- --worktree --release minor
  # enabling mid-resume on defaults epic
  run_c6 64 resolve-resume-flags CDV-C6-DEF -- --worktree
  # state wt true rb null vs --worktree --release patch (upgrade attempt)
  run_c6 0 init CDV-C6-WT --title "wt" --mode kickoff --worktree-enabled true
  run_c6 64 resolve-resume-flags CDV-C6-WT -- --worktree --release patch
  # match wt-only
  run_c6 0 resolve-resume-flags CDV-C6-WT -- --worktree
  echo "$OUT" | jq -e '.worktree_enabled==true and .release_bump==null' >/dev/null \
    && pass || fail "c6-4 wt-only match (out=$OUT)"

  # (c6-5) zero side effects on conflict — state modes unchanged
  BEFORE=$(cat "$C2_TMP/.claude/epics/CDV-C6-ON/state.json")
  run_c6 64 resolve-resume-flags CDV-C6-ON -- --worktree --release major
  AFTER=$(cat "$C2_TMP/.claude/epics/CDV-C6-ON/state.json")
  [ "$BEFORE" = "$AFTER" ] && pass || fail "c6-5 conflict must not mutate state"

  # (c6-6) resume reuses same integration path/branch (no second tree; no handoff paste)
  : >"$C3_LOG"
  run_c6 0 ensure-integration-worktree CDV-C6-ON
  echo "$OUT" | jq -e '
    .worktree_enabled==true
    and .integration_slug=="epic-CDV-C6-ON"
    and .integration_branch=="feat/epic-CDV-C6-ON"
    and (.integration_path | type=="string" and length>0)
  ' >/dev/null && pass || fail "c6-6 first ensure (out=$OUT)"
  PATH1=$(echo "$OUT" | jq -r .integration_path)
  # show surfaces integration_path for operator
  run_c6 0 show CDV-C6-ON
  echo "$OUT" | jq -e --arg p "$PATH1" '
    .integration_path==$p
    and .integration_branch=="feat/epic-CDV-C6-ON"
    and .worktree_enabled==true
    and .release_bump=="patch"
  ' >/dev/null && pass || fail "c6-6 show surfaces path+modes (out=$OUT)"
  # second ensure → same path, still one tree
  run_c6 0 ensure-integration-worktree CDV-C6-ON
  echo "$OUT" | jq -e --arg p "$PATH1" '.reused==true and .integration_path==$p' >/dev/null \
    && pass || fail "c6-6 reuse same path (out=$OUT)"
  EPIC_N=$(find "$C2_TMP/.worktrees" -maxdepth 1 -type d -name 'epic-CDV-C6-*' 2>/dev/null | wc -l)
  # only ON + WT may exist as epic-*; DEF must not
  [ -d "$C2_TMP/.worktrees/epic-CDV-C6-ON" ] && pass || fail "c6-6 ON tree missing"
  # ready-set still works under resumed modes
  run_c6 0 add-child CDV-C6-ON --id CDV-C6-ON-C1 --slug c6s1 --title t \
    --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
  run_c6 0 ready-set CDV-C6-ON
  echo "$OUT" | grep -qx 'CDV-C6-ON-C1' \
    && pass || fail "c6-6 ready-set continues (out=$OUT)"

  # (c6-7) usage
  run_c6 64 resolve-resume-flags
  run_c6 1 resolve-resume-flags NO-SUCH
fi

# ---- CDT-141-C4: assert-release-allowed (mid-epic /release + master-merge) --
{
  C4_TMP=$(mktemp -d "${TMPDIR:-/tmp}/epic-c4.XXXXXX")
  run_c4() {
    local want="$1"; shift
    set +e
    OUT=$(EPIC_ROOT="$C4_TMP" bash "$LIB" "$@" 2>&1)
    RC=$?
    set -e
    if [ "$RC" -eq "$want" ]; then pass
    else fail "c4 exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 500; echo
    fi
  }

  # (c4-1) usage
  run_c4 64 assert-release-allowed
  run_c4 64 assert-release-allowed A B

  # (c4-2) unknown ticket → allow (not under release=end)
  run_c4 0 assert-release-allowed CDV-UNKNOWN-C99

  # (c4-3) epic without release_bump → allow (per-child release unchanged)
  run_c4 0 init CDV-C4-OFF --title "off" --mode orchestrate
  run_c4 0 add-child CDV-C4-OFF --id CDV-C4-OFF-C1 --slug s1 --title t1 \
    --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
  run_c4 0 assert-release-allowed CDV-C4-OFF
  run_c4 0 assert-release-allowed CDV-C4-OFF-C1

  # (c4-4) worktree only (release_bump null) → allow
  run_c4 0 init CDV-C4-WT --title "wt" --mode orchestrate --worktree-enabled true
  run_c4 0 add-child CDV-C4-WT --id CDV-C4-WT-C1 --slug s1 --title t1 \
    --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
  jq -e '.release_bump==null' "$C4_TMP/.claude/epics/CDV-C4-WT/state.json" >/dev/null \
    && pass || fail "c4-4 state release_bump null"
  run_c4 0 assert-release-allowed CDV-C4-WT
  run_c4 0 assert-release-allowed CDV-C4-WT-C1

  # (c4-5) release_bump set, not sealed → hard-fail 64 + message (epic id + child id)
  run_c4 0 init CDV-C4-END --title "end" --mode orchestrate \
    --worktree-enabled true --release-bump minor
  run_c4 0 add-child CDV-C4-END --id CDV-C4-END-C1 --slug s1 --title t1 \
    --estimate M --agent ic5 --depends-on '[]' --problem p --ac '["a"]'
  run_c4 0 add-child CDV-C4-END --id CDV-C4-END-C2 --slug s2 --title t2 \
    --estimate S --agent ic4 --depends-on '["CDV-C4-END-C1"]' --problem p --ac '["a"]'
  jq -e '.release_bump=="minor"' "$C4_TMP/.claude/epics/CDV-C4-END/state.json" >/dev/null \
    && pass || fail "c4-5 release_bump persisted"

  run_c4 64 assert-release-allowed CDV-C4-END
  echo "$OUT" | grep -q 'epic CDV-C4-END is in release=end mode until seal (CDT-141)' \
    && pass || fail "c4-5 epic-id message (out=$OUT)"

  run_c4 64 assert-release-allowed CDV-C4-END-C1
  echo "$OUT" | grep -q 'epic CDV-C4-END is in release=end mode until seal (CDT-141)' \
    && pass || fail "c4-5 child-id message (out=$OUT)"

  # still forbidden when all children completed but seal not done
  run_c4 0 set-status CDV-C4-END CDV-C4-END-C1 completed
  run_c4 0 set-status CDV-C4-END CDV-C4-END-C2 completed
  run_c4 64 assert-release-allowed CDV-C4-END-C2
  echo "$OUT" | grep -q 'release=end mode until seal' \
    && pass || fail "c4-5b all-complete still mid-flight (out=$OUT)"

  # (c4-6) durable across re-read (resume): same state file still forbids
  run_c4 64 assert-release-allowed CDV-C4-END
  # re-open from disk (new process already) — plant sealed=false explicitly
  jq '.sealed=false' "$C4_TMP/.claude/epics/CDV-C4-END/state.json" \
    >"$C4_TMP/c4-seal-false.tmp"
  mv "$C4_TMP/c4-seal-false.tmp" "$C4_TMP/.claude/epics/CDV-C4-END/state.json"
  run_c4 64 assert-release-allowed CDV-C4-END

  # (c4-7) sealed=true → allow (C5 post-seal / seal complete)
  jq '.sealed=true' "$C4_TMP/.claude/epics/CDV-C4-END/state.json" \
    >"$C4_TMP/c4-sealed.tmp"
  mv "$C4_TMP/c4-sealed.tmp" "$C4_TMP/.claude/epics/CDV-C4-END/state.json"
  run_c4 0 assert-release-allowed CDV-C4-END
  run_c4 0 assert-release-allowed CDV-C4-END-C1

  # (c4-8) EPIC_ALLOW_SEAL_RELEASE=1 bypasses mid-flight (C5 seal /release path)
  jq 'del(.sealed)' "$C4_TMP/.claude/epics/CDV-C4-END/state.json" \
    >"$C4_TMP/c4-unseal.tmp"
  mv "$C4_TMP/c4-unseal.tmp" "$C4_TMP/.claude/epics/CDV-C4-END/state.json"
  set +e
  OUT=$(EPIC_ROOT="$C4_TMP" EPIC_ALLOW_SEAL_RELEASE=1 \
    bash "$LIB" assert-release-allowed CDV-C4-END 2>&1)
  RC=$?
  set -e
  [ "$RC" -eq 0 ] && pass || fail "c4-8 seal env bypass rc=$RC out=$OUT"
  # without env still fails
  run_c4 64 assert-release-allowed CDV-C4-END

  # (c4-9) linear_id lookup also forbids
  jq '(.children[] | select(.id=="CDV-C4-END-C1") | .linear_id) = "LIN-C4-1"' \
    "$C4_TMP/.claude/epics/CDV-C4-END/state.json" >"$C4_TMP/c4-lin.tmp"
  mv "$C4_TMP/c4-lin.tmp" "$C4_TMP/.claude/epics/CDV-C4-END/state.json"
  run_c4 64 assert-release-allowed LIN-C4-1
  echo "$OUT" | grep -q 'epic CDV-C4-END is in release=end mode until seal (CDT-141)' \
    && pass || fail "c4-9 linear_id message (out=$OUT)"

  # (c4-10) show surfaces sealed default false / true
  run_c4 0 show CDV-C4-END
  echo "$OUT" | jq -e '.sealed==false and .release_bump=="minor"' >/dev/null \
    && pass || fail "c4-10 show sealed false (out=$OUT)"
  jq '.sealed=true' "$C4_TMP/.claude/epics/CDV-C4-END/state.json" \
    >"$C4_TMP/c4-show.tmp"
  mv "$C4_TMP/c4-show.tmp" "$C4_TMP/.claude/epics/CDV-C4-END/state.json"
  run_c4 0 show CDV-C4-END
  echo "$OUT" | jq -e '.sealed==true' >/dev/null \
    && pass || fail "c4-10 show sealed true (out=$OUT)"

  rm -rf "$C4_TMP"
}

# ---- CDT-141-C5: seal (squash → one /release <bump> → sealed) ---------------
{
  C5_TMP=$(mktemp -d "${TMPDIR:-/tmp}/epic-c5.XXXXXX")
  git init -q "$C5_TMP" || { fail "c5 git init"; C5_TMP=""; }
  if [ -n "$C5_TMP" ] && [ -d "$C5_TMP/.git" ]; then
    git -C "$C5_TMP" config user.email "test@example.com"
    git -C "$C5_TMP" config user.name "Test"
    # Mirror product ignores so porcelain dirty ≠ integration tree / epic state
    # (CDT-170 abort gate uses status --porcelain; real repos ignore these)
    printf '%s\n' '.worktrees/' '.claude/epics/' >"$C5_TMP/.gitignore"
    git -C "$C5_TMP" add .gitignore
    git -C "$C5_TMP" commit -q -m "init"
    # Ensure master exists as default (some git use main)
    if ! git -C "$C5_TMP" show-ref --verify --quiet refs/heads/master; then
      git -C "$C5_TMP" branch -M master 2>/dev/null || true
    fi
    MASTER_SHA0=$(git -C "$C5_TMP" rev-parse HEAD)

    run_c5() {
      local want="$1"; shift
      set +e
      OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" bash "$LIB" "$@" 2>&1)
      RC=$?
      set -e
      if [ "$RC" -eq "$want" ]; then pass
      else fail "c5 exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 600; echo
      fi
    }

    # (c5-1) usage
    run_c5 64 seal-ready
    run_c5 64 seal-ready A B
    run_c5 64 seal
    run_c5 64 seal --dry-run

    # (c5-2) without --release (no release_bump) → no seal path
    run_c5 0 init CDV-C5-OFF --title "off" --mode orchestrate
    run_c5 0 add-child CDV-C5-OFF --id CDV-C5-OFF-C1 --slug s1 --title t1 \
      --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
    run_c5 0 set-status CDV-C5-OFF CDV-C5-OFF-C1 completed
    run_c5 0 seal-ready CDV-C5-OFF
    echo "$OUT" | jq -e '.ready==false and .reason=="no_release_bump"' >/dev/null \
      && pass || fail "c5-2 seal-ready no_release_bump (out=$OUT)"
    run_c5 0 seal CDV-C5-OFF
    echo "$OUT" | jq -e '.skipped==true and .sealed==false and .reason=="no_release_bump"' >/dev/null \
      && pass || fail "c5-2 seal skipped (out=$OUT)"
    # master unchanged
    [ "$(git -C "$C5_TMP" rev-parse HEAD)" = "$MASTER_SHA0" ] \
      && pass || fail "c5-2 master moved without seal path"

    # (c5-3) worktree only (release_bump null) → same skip
    run_c5 0 init CDV-C5-WT --title "wt" --mode orchestrate --worktree-enabled true
    run_c5 0 ensure-integration-worktree CDV-C5-WT
    run_c5 0 add-child CDV-C5-WT --id CDV-C5-WT-C1 --slug s1 --title t1 \
      --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
    run_c5 0 set-status CDV-C5-WT CDV-C5-WT-C1 completed
    run_c5 0 seal-ready CDV-C5-WT
    echo "$OUT" | jq -e '.ready==false and .reason=="no_release_bump"' >/dev/null \
      && pass || fail "c5-3 wt-only no seal (out=$OUT)"
    run_c5 0 seal CDV-C5-WT
    echo "$OUT" | jq -e '.skipped==true' >/dev/null \
      && pass || fail "c5-3 seal skip wt-only"

    # (c5-4) release_bump set but children incomplete → not ready / seal 64
    run_c5 0 init CDV-C5-END --title "end" --mode orchestrate \
      --worktree-enabled true --release-bump minor
    run_c5 0 ensure-integration-worktree CDV-C5-END
    INT_BR=$(jq -r .integration_branch "$C5_TMP/.claude/epics/CDV-C5-END/state.json")
    INT_PATH=$(jq -r .integration_path "$C5_TMP/.claude/epics/CDV-C5-END/state.json")
    run_c5 0 add-child CDV-C5-END --id CDV-C5-END-C1 --slug s1 --title t1 \
      --estimate M --agent ic5 --depends-on '[]' --problem p --ac '["a"]'
    run_c5 0 add-child CDV-C5-END --id CDV-C5-END-C2 --slug s2 --title t2 \
      --estimate S --agent ic4 --depends-on '["CDV-C5-END-C1"]' --problem p --ac '["a"]'
    run_c5 0 seal-ready CDV-C5-END
    echo "$OUT" | jq -e '.ready==false and .reason=="children_incomplete"' >/dev/null \
      && pass || fail "c5-4 incomplete (out=$OUT)"
    run_c5 64 seal CDV-C5-END
    echo "$OUT" | grep -q 'not ready' \
      && pass || fail "c5-4 seal mid-epic message (out=$OUT)"
    [ "$(git -C "$C5_TMP" rev-parse HEAD)" = "$MASTER_SHA0" ] \
      && pass || fail "c5-4 master must stay put mid-epic"

    # Land a commit on integration branch (epic delivery)
    echo "epic-payload" >"$INT_PATH/epic-file.txt"
    git -C "$INT_PATH" add epic-file.txt
    git -C "$INT_PATH" commit -q -m "feat: epic child work"
    INT_SHA=$(git -C "$INT_PATH" rev-parse HEAD)
    [ "$INT_SHA" != "$MASTER_SHA0" ] && pass || fail "c5 integration commit missing"

    # (c5-5) all complete → seal-ready; dry-run no side effects
    run_c5 0 set-status CDV-C5-END CDV-C5-END-C1 completed
    run_c5 0 set-status CDV-C5-END CDV-C5-END-C2 completed
    run_c5 0 seal-ready CDV-C5-END
    echo "$OUT" | jq -e \
      --arg b "$INT_BR" \
      '.ready==true and .release_bump=="minor" and .sealed==false
       and .all_children_completed==true and .integration_branch==$b' >/dev/null \
      && pass || fail "c5-5 seal-ready (out=$OUT)"
    run_c5 0 seal CDV-C5-END --dry-run
    echo "$OUT" | jq -e '.dry_run==true and .ready==true and .release_bump=="minor" and .sealed==false' >/dev/null \
      && pass || fail "c5-5 dry-run (out=$OUT)"
    [ "$(git -C "$C5_TMP" rev-parse HEAD)" = "$MASTER_SHA0" ] \
      && pass || fail "c5-5 dry-run moved master"
    jq -e '.sealed != true' "$C5_TMP/.claude/epics/CDV-C5-END/state.json" >/dev/null \
      && pass || fail "c5-5 dry-run must not set sealed"
    # master still lacks epic-file
    [ ! -f "$C5_TMP/epic-file.txt" ] && pass || fail "c5-5 dry-run leaked file to master"

    # (c5-6) seal failure (hook fail) → master clean, sealed=false, no partial
    HOOK_LOG="$C5_TMP/hook.log"
    : >"$HOOK_LOG"
    FAIL_HOOK="echo FAIL_HOOK >>\"$HOOK_LOG\"; exit 1"
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" EPIC_SEAL_RELEASE_HOOK="$FAIL_HOOK" \
      bash "$LIB" seal CDV-C5-END 2>&1)
    RC=$?
    set -e
    [ "$RC" -eq 1 ] && pass || fail "c5-6 hook fail want rc=1 got $RC out=$OUT"
    echo "$OUT" | grep -qi 'release hook failed\|master restored' \
      && pass || fail "c5-6 fail message (out=$OUT)"
    [ "$(git -C "$C5_TMP" rev-parse HEAD)" = "$MASTER_SHA0" ] \
      && pass || fail "c5-6 master SHA changed on fail"
    git -C "$C5_TMP" diff --quiet && git -C "$C5_TMP" diff --cached --quiet \
      && pass || fail "c5-6 master dirty after fail"
    [ ! -f "$C5_TMP/epic-file.txt" ] && pass || fail "c5-6 epic-file on master after fail"
    jq -e '(.sealed // false) == false' "$C5_TMP/.claude/epics/CDV-C5-END/state.json" >/dev/null \
      && pass || fail "c5-6 sealed must stay false"
    # assert still forbids mid-flight
    run_c5 64 assert-release-allowed CDV-C5-END

    # (c5-7) successful seal with mock /release hook — once
    # Hook: commit staged squash as single release commit (simulates /release fold)
    OK_HOOK='git commit -q -m "fix: v9.9.9 — epic seal mock" && echo HOOK_OK >>"'"$HOOK_LOG"'"'
    : >"$HOOK_LOG"
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" EPIC_SEAL_RELEASE_HOOK="$OK_HOOK" \
      bash "$LIB" seal CDV-C5-END 2>&1)
    RC=$?
    set -e
    [ "$RC" -eq 0 ] && pass || fail "c5-7 seal success rc=$RC out=$OUT"
    echo "$OUT" | jq -e '.sealed==true and .release_bump=="minor" and .release_invoked==true' >/dev/null \
      && pass || fail "c5-7 seal JSON (out=$OUT)"
    jq -e '.sealed==true' "$C5_TMP/.claude/epics/CDV-C5-END/state.json" >/dev/null \
      && pass || fail "c5-7 state sealed=true"
    [ -f "$C5_TMP/epic-file.txt" ] && pass || fail "c5-7 epic-file missing on master after seal"
    MASTER_SHA1=$(git -C "$C5_TMP" rev-parse HEAD)
    [ "$MASTER_SHA1" != "$MASTER_SHA0" ] && pass || fail "c5-7 master should advance once"
    # exactly one commit beyond pre-seal master
    N_NEW=$(git -C "$C5_TMP" rev-list --count "$MASTER_SHA0..$MASTER_SHA1")
    [ "$N_NEW" -eq 1 ] && pass || fail "c5-7 want exactly 1 release commit got $N_NEW"
    git -C "$C5_TMP" log -1 --format=%s | grep -q 'fix: v9.9.9' \
      && pass || fail "c5-7 release commit subject"
    HOOK_N=$(grep -c HOOK_OK "$HOOK_LOG" || true)
    [ "$HOOK_N" -eq 1 ] && pass || fail "c5-7 hook once got $HOOK_N"
    # post-seal assert allows
    run_c5 0 assert-release-allowed CDV-C5-END

    # (c5-8) second seal → already_sealed, no second hook/commit
    : >"$HOOK_LOG"
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" EPIC_SEAL_RELEASE_HOOK="$OK_HOOK" \
      bash "$LIB" seal CDV-C5-END 2>&1)
    RC=$?
    set -e
    [ "$RC" -eq 0 ] && pass || fail "c5-8 second seal rc=$RC"
    echo "$OUT" | jq -e '.already_sealed==true and .sealed==true and .skipped==true' >/dev/null \
      && pass || fail "c5-8 already_sealed JSON (out=$OUT)"
    [ "$(git -C "$C5_TMP" rev-parse HEAD)" = "$MASTER_SHA1" ] \
      && pass || fail "c5-8 second seal moved master"
    HOOK_N=$(grep -c HOOK_OK "$HOOK_LOG" || true)
    [ "$HOOK_N" -eq 0 ] && pass || fail "c5-8 hook must not re-fire (n=$HOOK_N)"
    run_c5 0 seal-ready CDV-C5-END
    echo "$OUT" | jq -e '.ready==false and .reason=="already_sealed"' >/dev/null \
      && pass || fail "c5-8 seal-ready already (out=$OUT)"

    # (c5-9) handoff path (no hook): stage only + --complete / --abort
    run_c5 0 init CDV-C5-HO --title "ho" --mode orchestrate \
      --worktree-enabled true --release-bump patch
    run_c5 0 ensure-integration-worktree CDV-C5-HO
    HO_BR=$(jq -r .integration_branch "$C5_TMP/.claude/epics/CDV-C5-HO/state.json")
    HO_PATH=$(jq -r .integration_path "$C5_TMP/.claude/epics/CDV-C5-HO/state.json")
    run_c5 0 add-child CDV-C5-HO --id CDV-C5-HO-C1 --slug h1 --title t1 \
      --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
    run_c5 0 set-status CDV-C5-HO CDV-C5-HO-C1 completed
    echo "handoff-payload" >"$HO_PATH/ho.txt"
    git -C "$HO_PATH" add ho.txt
    git -C "$HO_PATH" commit -q -m "feat: handoff child"
    # reset master clean (prior seal left us on master with commits — ok)
    git -C "$C5_TMP" checkout -q master
    PRE_HO=$(git -C "$C5_TMP" rev-parse HEAD)
    run_c5 0 seal CDV-C5-HO
    echo "$OUT" | jq -e \
      '.staged==true and .sealed==false and .release_invoked==false
       and .release_bump=="patch" and .handoff=="/release patch"' >/dev/null \
      && pass || fail "c5-9 handoff JSON (out=$OUT)"
    echo "$OUT" | jq -e '.env.EPIC_ALLOW_SEAL_RELEASE=="1"' >/dev/null \
      && pass || fail "c5-9 handoff env"
    # staged but not committed
    [ "$(git -C "$C5_TMP" rev-parse HEAD)" = "$PRE_HO" ] \
      && pass || fail "c5-9 handoff must not commit"
    git -C "$C5_TMP" diff --cached --quiet && fail "c5-9 expected staged index" || pass
    # CDT-170: staged seal = porcelain dirty → bare --abort refuses
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" bash "$LIB" seal CDV-C5-HO --abort 2>&1)
    RC=$?
    set -e
    [ "$RC" -eq 1 ] && pass || fail "c5-9 staged bare abort want rc=1 got $RC out=$OUT"
    echo "$OUT" | grep -q 'dirty' && echo "$OUT" | grep -q 'refuse' \
      && pass || fail "c5-9 staged bare abort message (out=$OUT)"
    git -C "$C5_TMP" diff --cached --quiet && fail "c5-9 bare abort wiped staged" || pass
    # intentional wipe of seal stage uses --force
    run_c5 0 seal CDV-C5-HO --abort --force
    echo "$OUT" | jq -e '.aborted==true and .sealed==false' >/dev/null \
      && pass || fail "c5-9 abort --force JSON (out=$OUT)"
    git -C "$C5_TMP" diff --quiet && git -C "$C5_TMP" diff --cached --quiet \
      && pass || fail "c5-9 abort --force left dirty"
    jq -e '(.sealed // false)==false' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json" >/dev/null \
      && pass || fail "c5-9 abort must not seal"

    # (c5-d2) clean bare abort → rc=0 (tree already clean after force)
    run_c5 0 seal CDV-C5-HO --abort
    echo "$OUT" | jq -e '.aborted==true and .sealed==false' >/dev/null \
      && pass || fail "c5-d2 clean abort JSON (out=$OUT)"
    git -C "$C5_TMP" status --porcelain | grep -q . \
      && fail "c5-d2 clean abort dirtied tree" || pass

    # re-stage then --complete (simulates post-/release)
    run_c5 0 seal CDV-C5-HO
    # pretend /release committed
    git -C "$C5_TMP" commit -q -m "fix: v1.2.3 — handoff seal"
    run_c5 0 seal CDV-C5-HO --complete
    echo "$OUT" | jq -e '.sealed==true and .already_sealed==false' >/dev/null \
      && pass || fail "c5-9 complete (out=$OUT)"
    jq -e '.sealed==true' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json" >/dev/null \
      && pass || fail "c5-9 state sealed"
    run_c5 0 assert-release-allowed CDV-C5-HO

    # ---- c5-abort-dirty (CDT-170): porcelain dirty gate on seal --abort ----
    # c5-d2 clean abort: above. c5-d6: c5-6 hook-fail + c5-9 force/clean still pass.

    # (c5-d1) dirty bare abort → refuse; WIP preserved; sealed unchanged
    printf 'wip-content\n' >"$C5_TMP/wip.txt"
    WIP_SHA=$(git -C "$C5_TMP" hash-object wip.txt)
    SEALED_BEFORE=$(jq -r '.sealed // false' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json")
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" bash "$LIB" seal CDV-C5-HO --abort 2>&1)
    RC=$?
    set -e
    [ "$RC" -eq 1 ] && pass || fail "c5-d1 dirty bare abort rc=$RC out=$OUT"
    echo "$OUT" | grep -q 'dirty' && echo "$OUT" | grep -q 'refuse' \
      && pass || fail "c5-d1 stderr dirty+refuse (out=$OUT)"
    [ -f "$C5_TMP/wip.txt" ] && pass || fail "c5-d1 wip.txt wiped on bare abort"
    [ "$(git -C "$C5_TMP" hash-object wip.txt)" = "$WIP_SHA" ] \
      && pass || fail "c5-d1 wip content mutated"
    [ "$(jq -r '.sealed // false' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json")" = "$SEALED_BEFORE" ] \
      && pass || fail "c5-d1 sealed flipped"

    # (c5-d3) dirty + --abort --force → wipe; rc=0
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" bash "$LIB" seal CDV-C5-HO --abort --force 2>&1)
    RC=$?
    set -e
    [ "$RC" -eq 0 ] && pass || fail "c5-d3 abort --force rc=$RC out=$OUT"
    echo "$OUT" | jq -e '(.aborted==true or .reason=="already_sealed")' >/dev/null \
      && pass || fail "c5-d3 force JSON (out=$OUT)"
    [ ! -f "$C5_TMP/wip.txt" ] && pass || fail "c5-d3 force left wip.txt"
    git -C "$C5_TMP" status --porcelain | grep -q . \
      && fail "c5-d3 force left dirty porcelain" || pass

    # (c5-d4) already_sealed + dirty bare abort → rc=1; no wipe; sealed still true
    jq -e '.sealed==true' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json" >/dev/null \
      && pass || fail "c5-d4 precondition sealed=true"
    printf 'wip-sealed\n' >"$C5_TMP/wip-sealed.txt"
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" bash "$LIB" seal CDV-C5-HO --abort 2>&1)
    RC=$?
    set -e
    [ "$RC" -eq 1 ] && pass || fail "c5-d4 already_sealed dirty abort rc=$RC out=$OUT"
    echo "$OUT" | grep -q 'dirty' && echo "$OUT" | grep -q 'refuse' \
      && pass || fail "c5-d4 stderr dirty+refuse (out=$OUT)"
    [ -f "$C5_TMP/wip-sealed.txt" ] && pass || fail "c5-d4 wiped wip-sealed.txt"
    jq -e '.sealed==true' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json" >/dev/null \
      && pass || fail "c5-d4 sealed no longer true"
    # cleanup dirty for later cases
    rm -f "$C5_TMP/wip-sealed.txt"

    # (c5-d5) --force without --abort → 64
    run_c5 64 seal CDV-C5-HO --force
    echo "$OUT" | grep -q 'force only valid with --abort' \
      && pass || fail "c5-d5 force-alone message (out=$OUT)"
    run_c5 64 seal CDV-C5-HO --complete --force
    echo "$OUT" | grep -q 'force only valid with --abort' \
      && pass || fail "c5-d5 complete+force message (out=$OUT)"

    # (c5-10) seal --complete without release_bump → 64
    run_c5 64 seal CDV-C5-OFF --complete

    rm -rf "$C5_TMP"
  fi
}

# ---- CDT-141-C7: SPEC + surface docs + regression greps (M14 contract) ------
SPEC="$HERE/../../specs/core/SPEC-025-epic-umbrella-decomposition.md"
DOCS_EPIC="$HERE/../../docs/commands/epic.md"
SKILL="$HERE/SKILL.md"
CMD="$HERE/../../commands/epic.md"

# (c7-1) SPEC documents CLI table, done-when 1–7, non-public API, illegal combos
if [ -f "$SPEC" ]; then
  grep -q 'M14 CLI table' "$SPEC" && pass || fail "c7-1 SPEC missing M14 CLI table"
  grep -q 'M14 Semantics' "$SPEC" && pass || fail "c7-1 SPEC missing M14 Semantics"
  grep -q 'M14 Illegal combos' "$SPEC" && pass || fail "c7-1 SPEC missing M14 Illegal combos"
  grep -q 'M14 Non-public API' "$SPEC" && pass || fail "c7-1 SPEC missing M14 Non-public API"
  grep -q 'M14 Done when' "$SPEC" && pass || fail "c7-1 SPEC missing M14 Done when"
  # done-when 1–7 anchors (content phrases from CDT-141)
  grep -q 'Master unchanged until seal' "$SPEC" && pass || fail "c7-1 done-when 1"
  grep -q 'Exactly one.*versioned release commit\|Exactly one\*\* versioned release' "$SPEC" \
    && pass || fail "c7-1 done-when 2"
  grep -q 'Zero per-child worktrees' "$SPEC" && pass || fail "c7-1 done-when 3"
  grep -q 'epic-<EPIC-ID>`\*\* convention\|`epic-<EPIC-ID>` convention' "$SPEC" \
    && pass || fail "c7-1 done-when 4"
  grep -q 'Resume\*\* continues the same integration\|same integration branch without pasting' "$SPEC" \
    && pass || fail "c7-1 done-when 5"
  grep -q 'Defaults\*\* (flags omitted)\|byte-identical to pre-M14' "$SPEC" \
    && pass || fail "c7-1 done-when 6"
  grep -q 'Mid-epic `/release` or master merge\|halt exit 64' "$SPEC" \
    && pass || fail "c7-1 done-when 7"
  grep -q 'epic-<EPIC-ID>' "$SPEC" && pass || fail "c7-1 SPEC missing epic-<EPIC-ID> convention"
  grep -q 'M14 carve-out' "$SPEC" && pass || fail "c7-1 SPEC missing M11/M14 carve-out"
  grep -q 'M11 still holds' "$SPEC" && pass || fail "c7-1 SPEC missing M11 still holds under M14"
else
  fail "c7-1 SPEC-025 missing"
fi

# (c7-2) surface docs: both flags + hard-fail on commands, docs, skill
for f in "$CMD" "$DOCS_EPIC" "$SKILL"; do
  bn=$(basename "$(dirname "$f")")/$(basename "$f")
  [ -f "$f" ] || { fail "c7-2 missing $bn"; continue; }
  grep -q -- '--worktree' "$f" && pass || fail "c7-2 $bn missing --worktree"
  grep -q -- '--release' "$f" && pass || fail "c7-2 $bn missing --release"
  # hard-fail / exit 64 mentioned
  grep -qE 'exit \*\*64\*\*|exit 64|hard-fail' "$f" \
    && pass || fail "c7-2 $bn missing hard-fail/64"
done

# (c7-3) no docs advertise rejected names as public flag table rows
# Allow prose that rejects them (e.g. "rejected: --bump"); ban table rows
# that present them as accepted args: | `[--bump]` | etc.
for f in "$CMD" "$DOCS_EPIC" "$SKILL" "$SPEC"; do
  [ -f "$f" ] || continue
  bn=$(basename "$f")
  if grep -nE '^\| `\[--bump\]|^\| `\[--land\]|^\| `\[--seal\]|^\| `--bump`|^\| `--land`|^\| `--seal`' \
    "$f" >/dev/null 2>&1; then
    fail "c7-3 $bn advertises banned flag as table row"
  else
    pass
  fi
  # must not present --release each|end or --worktree mode as accepted usage lines
  if grep -nE '^\| `/epic.*--release each|^\| `/epic.*--worktree (epic|per-child)' \
    "$f" >/dev/null 2>&1; then
    fail "c7-3 $bn advertises rejected mode enums as usage"
  else
    pass
  fi
done

# (c7-4) docs/commands documents seal + M11 carve-out
if [ -f "$DOCS_EPIC" ]; then
  grep -qi 'seal' "$DOCS_EPIC" && pass || fail "c7-4 docs/commands/epic.md missing seal"
  grep -q 'carve-out\|M11' "$DOCS_EPIC" && pass || fail "c7-4 docs missing M11/carve-out"
  grep -q 'epic-<ID>\|epic-<EPIC-ID>' "$DOCS_EPIC" \
    && pass || fail "c7-4 docs missing epic-<ID> path"
fi

# (c7-5) skill documents M11 carve-out + seal B.7
if [ -f "$SKILL" ]; then
  grep -q 'M11 carve-out' "$SKILL" && pass || fail "c7-5 SKILL missing M11 carve-out"
  grep -q 'B.7 End-of-epic seal\|### B.7' "$SKILL" && pass || fail "c7-5 SKILL missing B.7"
  grep -q 'ensure-integration-worktree' "$SKILL" && pass || fail "c7-5 SKILL missing ensure"
fi

# (c7-6) coverage anchors — named suites for AC mapping (exist as comments/labels)
# Legal parse / illegal / defaults / epic path / mid-forbid / seal single-release
grep -q 'CDT-141-C1 / M14: parse-flags' "$HERE/test.sh" \
  && pass || fail "c7-6 missing parse-flags suite label"
grep -q 'default init must omit worktree_enabled' "$HERE/test.sh" \
  && pass || fail "c7-6 missing defaults coverage"
grep -q 'CDT-141-C2: ensure-integration-worktree' "$HERE/test.sh" \
  && pass || fail "c7-6 missing epic-<ID> ensure suite"
grep -q 'CDT-141-C4: assert-release-allowed' "$HERE/test.sh" \
  && pass || fail "c7-6 missing mid-epic forbid suite"
grep -q 'CDT-141-C5: seal' "$HERE/test.sh" \
  && pass || fail "c7-6 missing seal suite"
# single-release invariant in c5-7
grep -q 'exactly 1 release commit' "$HERE/test.sh" \
  && pass || fail "c7-6 missing single-release assert"

# ---- M15 /epic sync: sync-apply (Linear→local, session supplies verdicts) ----
echo ""
echo "=== M15 sync-apply ==="
SYNC_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/epic-sync-XXXXXX")
export EPIC_ROOT="$SYNC_ROOT"
bash "$LIB" init SYNC-E --title "Sync epic" --mode orchestrate >/dev/null
bash "$LIB" add-child SYNC-E --id SYNC-E-C1 --slug c1 --title "Child one" \
  --estimate S --agent ic4 --depends-on '[]' >/dev/null
bash "$LIB" add-child SYNC-E --id SYNC-E-C2 --slug c2 --title "Child two" \
  --estimate M --agent ic5 --depends-on '["SYNC-E-C1"]' --linear-id "LIN-C2" >/dev/null

# (s1) dry-run: fill linear_id + set completed; no write
V1=$(mktemp "${TMPDIR:-/tmp}/epic-sync-v1.XXXXXX")
cat >"$V1" <<'JSON'
{
  "linear_project_id": "proj-abc",
  "children": [
    { "id": "SYNC-E-C1", "linear_id": "LIN-C1", "status": "completed", "outcome_summary": "done via Linear" },
    { "id": "SYNC-E-C2", "status": "in_progress" }
  ],
  "orphans": [{ "linear_id": "LIN-ORPH", "title": "orphan" }],
  "unmatched_local": []
}
JSON
OUT=$(bash "$LIB" sync-apply SYNC-E --verdicts "$V1" --dry-run)
echo "$OUT" | jq -e '.dry_run==true and .applied_count>=3' >/dev/null \
  && pass || fail "s1 dry-run applied_count: $OUT"
STAT=$(bash "$LIB" show SYNC-E | jq -r '.children[] | select(.id=="SYNC-E-C1") | .status')
[ "$STAT" = "pending" ] && pass || fail "s1 dry-run must not write status got $STAT"
LID=$(bash "$LIB" show SYNC-E | jq -r '.children[] | select(.id=="SYNC-E-C1") | .linear_id // "null"')
[ "$LID" = "null" ] && pass || fail "s1 dry-run must not fill linear_id got $LID"
PROJ=$(bash "$LIB" show SYNC-E | jq -r '.linear_project_id // "null"')
[ "$PROJ" = "null" ] && pass || fail "s1 dry-run must not set project got $PROJ"
echo "$OUT" | jq -e '.orphans | length == 1' >/dev/null \
  && pass || fail "s1 orphans pass-through"

# (s2) apply for real
OUT=$(bash "$LIB" sync-apply SYNC-E --verdicts "$V1")
echo "$OUT" | jq -e '.dry_run==false and .applied_count>=3' >/dev/null \
  && pass || fail "s2 apply count: $OUT"
STAT=$(bash "$LIB" show SYNC-E | jq -r '.children[] | select(.id=="SYNC-E-C1") | .status')
[ "$STAT" = "completed" ] && pass || fail "s2 C1 completed got $STAT"
LID=$(bash "$LIB" show SYNC-E | jq -r '.children[] | select(.id=="SYNC-E-C1") | .linear_id')
[ "$LID" = "LIN-C1" ] && pass || fail "s2 C1 linear_id got $LID"
OUTC=$(bash "$LIB" show SYNC-E | jq -r '.children[] | select(.id=="SYNC-E-C1") | .outcome_summary')
[ "$OUTC" = "done via Linear" ] && pass || fail "s2 outcome got $OUTC"
STAT=$(bash "$LIB" show SYNC-E | jq -r '.children[] | select(.id=="SYNC-E-C2") | .status')
[ "$STAT" = "in_progress" ] && pass || fail "s2 C2 in_progress got $STAT"
PROJ=$(bash "$LIB" show SYNC-E | jq -r '.linear_project_id')
[ "$PROJ" = "proj-abc" ] && pass || fail "s2 project got $PROJ"

# (s3) idempotent re-apply → mostly skipped, applied_count 0
OUT=$(bash "$LIB" sync-apply SYNC-E --verdicts "$V1")
echo "$OUT" | jq -e '.applied_count==0' >/dev/null \
  && pass || fail "s3 idempotent apply: $OUT"

# (s4) no_downgrade_completed: Linear reopened → skip
V2=$(mktemp "${TMPDIR:-/tmp}/epic-sync-v2.XXXXXX")
cat >"$V2" <<'JSON'
{ "children": [ { "id": "SYNC-E-C1", "status": "pending" } ] }
JSON
OUT=$(bash "$LIB" sync-apply SYNC-E --verdicts "$V2")
echo "$OUT" | jq -e '[.skipped[] | select(.action=="no_downgrade_completed")] | length == 1' >/dev/null \
  && pass || fail "s4 no_downgrade: $OUT"
STAT=$(bash "$LIB" show SYNC-E | jq -r '.children[] | select(.id=="SYNC-E-C1") | .status')
[ "$STAT" = "completed" ] && pass || fail "s4 C1 still completed got $STAT"

# (s5) linear_id mismatch conflict
V3=$(mktemp "${TMPDIR:-/tmp}/epic-sync-v3.XXXXXX")
cat >"$V3" <<'JSON'
{ "children": [ { "id": "SYNC-E-C2", "linear_id": "LIN-OTHER" } ] }
JSON
OUT=$(bash "$LIB" sync-apply SYNC-E --verdicts "$V3")
echo "$OUT" | jq -e '[.conflicts[] | select(.action=="linear_id_mismatch")] | length == 1' >/dev/null \
  && pass || fail "s5 linear_id_mismatch: $OUT"
LID=$(bash "$LIB" show SYNC-E | jq -r '.children[] | select(.id=="SYNC-E-C2") | .linear_id')
[ "$LID" = "LIN-C2" ] && pass || fail "s5 C2 linear_id unchanged got $LID"

# (s6) unknown child → conflict
V4=$(mktemp "${TMPDIR:-/tmp}/epic-sync-v4.XXXXXX")
cat >"$V4" <<'JSON'
{ "children": [ { "id": "SYNC-E-C99", "status": "completed" } ] }
JSON
OUT=$(bash "$LIB" sync-apply SYNC-E --verdicts "$V4")
echo "$OUT" | jq -e '[.conflicts[] | select(.action=="unknown_child")] | length == 1' >/dev/null \
  && pass || fail "s6 unknown_child: $OUT"

# (s7) usage / missing file
expect_rc 64 "s7 missing verdicts" bash "$LIB" sync-apply SYNC-E
expect_rc 1 "s7 missing file" bash "$LIB" sync-apply SYNC-E --verdicts /no/such/file.json
expect_rc 1 "s7 missing epic" env EPIC_ROOT="$SYNC_ROOT" bash "$LIB" sync-apply NOPE --verdicts "$V1"

# (s8) protocol presence
if [ -f "$SKILL" ]; then
  grep -q 'Mode F' "$SKILL" && grep -q 'sync-apply' "$SKILL" \
    && pass || fail "s8 SKILL missing Mode F / sync-apply"
  grep -q '/epic sync' "$SKILL" \
    && pass || fail "s8 SKILL missing /epic sync"
fi

rm -f "$V1" "$V2" "$V3" "$V4"
rm -rf "$SYNC_ROOT"
unset EPIC_ROOT

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0

