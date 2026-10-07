#!/usr/bin/env bash
# Bite-tests for epic-lib.sh (SPEC-025) + parse-flags.sh (CDT-141-C1 / M14).
# Run: bash skills/epic/test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/epic-lib.sh"
PARSE="$HERE/parse-flags.sh"
DAG="$HERE/../orchestrate/dag-lib.sh"
# WP 7-04 split: mode bodies live beside the router. Content greps and section
# extractions target the concatenated skill body, so a pattern matches in any
# stage file; router-only checks (frontmatter, existence) keep $SKILL.
SKILL_BODY=$(mktemp "${TMPDIR:-/tmp}/epic-skill-body.XXXXXX")
cat "$HERE"/SKILL.md "$HERE"/run-start.md "$HERE"/mode-a-decompose.md \
  "$HERE"/mode-b-execute.md "$HERE"/mode-c-status.md "$HERE"/mode-d-complete.md \
  "$HERE"/mode-e-redecompose.md "$HERE"/mode-f-sync.md > "$SKILL_BODY"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/path.sh
. "$HERE/../../tests/lib/path.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$HERE/../../tests/lib/fence.sh"
hermetic_init
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
  # set -e stays in the command-substitution subshell. This shell stays set -u.
  RC=0
  OUT=$(set -e; EPIC_ROOT="${EPIC_ROOT:-}" bash "$LIB" "$@" 2>&1) || RC=$?
  if [ "$RC" -eq "$want" ]; then pass
  else fail "exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 400; echo
  fi
}

# ---- T0: usage --------------------------------------------------------------
run_lib 64
echo "$OUT" | grep -q Usage && pass || fail "usage text missing"

# ---- isolated root ----------------------------------------------------------
# CDT-424: every temp dir is tracked. The EXIT trap removes all of them.
# errexit is not enabled in this shell.
TMP_DIRS=()
keep_tmp() {
  [ -n "${1:-}" ] || return 0
  TMP_DIRS+=("$1")
}
sweep_tracked() {
  local d
  for d in ${TMP_DIRS[@]+"${TMP_DIRS[@]}"}; do
    rm -rf "$d"
  done
}
cleanup() { sweep_tracked; hermetic_cleanup; }
trap cleanup EXIT
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/epic-test.XXXXXX")
keep_tmp "$TMPROOT"
export EPIC_ROOT="$TMPROOT"

run_in() {
  local want="$1"; shift
  RC=0
  OUT=$(set -e; EPIC_ROOT="$TMPROOT" bash "$LIB" "$@" 2>&1) || RC=$?
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
[ "$RC" -eq 1 ] && pass || fail "cyclic check-cycle want exit 1 got $RC"
echo "$OUT" | grep -qi cycle && pass || fail "cycle message missing: $OUT"

set +e
OUT=$(EPIC_ROOT="$TMPROOT" bash "$LIB" check-cycle "$ACYC" 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass || fail "acyclic check-cycle want 0 got $RC out=$OUT"

# also direct dag-lib (AC14 — external reuse)
set +e
bash "$DAG" check-cycle "$CYC" >/dev/null 2>&1
RC=$?
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
[ -f "$SKILL_BODY" ] || fail "skills/epic/SKILL.md missing"

if [ -f "$SKILL_BODY" ]; then
  # M8: no skip-PM path (mandatory PM; no enablement flag)
  grep -q 'no skip-PM path' "$SKILL_BODY" \
    && pass || fail "SKILL missing 'no skip-PM path' (M8)"
  if grep -nE -- '--skip-pm|SKIP_PM=|skip_pm' "$SKILL_BODY" ${CMD:+"$CMD"} 2>/dev/null; then
    fail "skip-PM enablement path still present (M8)"
  else
    pass
  fi

  # M13 present + fail-closed halt string
  grep -q 'M13' "$SKILL_BODY" \
    && pass || fail "SKILL missing M13"
  grep -q 'context-discipline: seed failed' "$SKILL_BODY" \
    && pass || fail "SKILL missing fail-closed string 'context-discipline: seed failed'"

  # Guardrail + measurement + CDT-126 non-goal (M13.5 / AC2 / M13.9)
  grep -q '400k' "$SKILL_BODY" \
    && pass || fail "SKILL missing 400k guardrail threshold"
  grep -qE 'ε[[:space:]]*=[[:space:]]*0\.5' "$SKILL_BODY" \
    && pass || fail "SKILL missing ε = 0.5 measurement target"
  grep -q 'CDT-126 non-goal' "$SKILL_BODY" \
    && pass || fail "SKILL missing CDT-126 non-goal note"

  # No dual status SoT + M11 still holds under M13
  grep -q 'no dual status SoT' "$SKILL_BODY" \
    && pass || fail "SKILL missing no dual status SoT (M13.2a)"
  grep -q 'M11 under M13' "$SKILL_BODY" \
    && pass || fail "SKILL missing 'M11 under M13' preservation note"
  grep -q 'What /epic MUST NOT do (M11)' "$SKILL_BODY" \
    && pass || fail "SKILL missing M11 MUST NOT section"

  # CDT-141-C1 / M14 protocol presence
  grep -q 'Step 0.4: Worktree / release flags' "$SKILL_BODY" \
    && pass || fail "SKILL missing Step 0.4 worktree/release flags"
  grep -q 'skills/epic/parse-flags.sh' "$SKILL_BODY" \
    && pass || fail "SKILL missing parse-flags.sh reference"
  # CDT-141-C2: ensure-integration-worktree wire + M11 carve-out
  # (the unscoped ensure-integration-worktree mention grep is superseded by
  # the c7-e8 structural fence-cmds-vs-case-list check below)
  grep -q 'M11 carve-out' "$SKILL_BODY" \
    && pass || fail "SKILL missing M11 carve-out for integration WT"
  # A.6 real init fence must wire INIT_EXTRA + ensure after init
  A6_BLOCK=$(awk '/^### A\.6 Persist/,/^#### Dual-write persistence/' "$SKILL_BODY")
  echo "$A6_BLOCK" | grep -qE 'INIT_EXTRA|--worktree-enabled' \
    && pass || fail "A.6 init fence missing INIT_EXTRA/--worktree-enabled"
  echo "$A6_BLOCK" | grep -q 'ensure-integration-worktree' \
    && pass || fail "A.6 missing ensure-integration-worktree after init"
  # M4.1 link-before-create: inventory parent children; adopt/halt; no blind create
  grep -q 'M4.1 Link-before-create' "$SKILL_BODY" \
    && pass || fail "SKILL missing M4.1 Link-before-create section"
  grep -q 'parentId' "$SKILL_BODY" \
    && pass || fail "SKILL missing list_issues parentId inventory (M4.1)"
  grep -q 'refusing duplicate create' "$SKILL_BODY" \
    && pass || fail "SKILL missing M4.1 HALT duplicate-create line"
  grep -q 'Adopted N existing Linear child' "$SKILL_BODY" \
    && pass || fail "SKILL missing M4.1 adopt advisory line"
  grep -q 'MUST NOT force-create under autopilot' "$SKILL_BODY" \
    && pass || fail "SKILL missing M4.1 autopilot no force-create"
  # B.1 resume must ensure when state enabled
  B1_BLOCK=$(awk '/^### B\.1 Rollup/,/^### B\.2 /' "$SKILL_BODY")
  echo "$B1_BLOCK" | grep -q 'ensure-integration-worktree' \
    && pass || fail "B.1 missing ensure-integration-worktree on resume"
  # CDT-141-C6: resolve-resume-flags + conflict policy documented
  # (the unscoped resolve-resume-flags mention grep is superseded by the
  # c7-e8 structural fence-cmds-vs-case-list check below)
  grep -q 'Resume flag-vs-state policy' "$SKILL_BODY" \
    && pass || fail "SKILL missing Resume flag-vs-state policy (C6)"
  grep -q 'Honor store' "$SKILL_BODY" \
    && pass || fail "SKILL missing Honor store (C6)"
  grep -q -- '--worktree' "$SKILL_BODY" \
    && pass || fail "SKILL Arguments missing --worktree"
  grep -q -- '--release' "$SKILL_BODY" \
    && pass || fail "SKILL Arguments missing --release"
fi

# ---- CDT-159 / SPEC-025 M7: AUTOPILOT_ON continue Mode B while ready-set ----
# Protocol greps only (AC6). Operational home = SKILL B.5, not B.2 empty-set.
SKILL="$HERE/SKILL.md"
CMD="$HERE/../../commands/epic.md"
SPEC="$HERE/../../specs/core/SPEC-025-epic-umbrella-decomposition.md"
DOCS_EPIC="$HERE/../../docs/commands/epic.md"
B5_BLOCK=$(awk '/^### B\.5 Completion/,/^### B\.6 /' "$SKILL_BODY")
B2_BLOCK=$(awk '/^### B\.2 /, /^### B\.3 /' "$SKILL_BODY")
M7_BLOCK=$(awk '/^\- \*\*M7 —/,/^\- \*\*M8 —/' "$SPEC")

# (a) B.5 / AUTOPILOT_ON + ready-set + same run + first-shipped-child phrase
echo "$B5_BLOCK" | grep -q 'AUTOPILOT_ON' \
  && pass || fail "CDT-159 B.5 missing AUTOPILOT_ON"
echo "$B5_BLOCK" | grep -q 'ready-set' \
  && pass || fail "CDT-159 B.5 missing ready-set"
echo "$B5_BLOCK" | grep -q 'same run' \
  && pass || fail "CDT-159 B.5 missing same-run continue"
echo "$B5_BLOCK" | grep -qF 'Do **not** end the epic after the first shipped child' \
  && pass || fail "CDT-159 B.5 missing first-shipped-child phrase"
echo "$B5_BLOCK" | grep -q 'new `/epic`' \
  && pass || fail "CDT-159 B.5 missing no-new-/epic (same-run, no reinvoke)"

# (b) stop list in B.5 (unchanged stops; no new stop)
echo "$B5_BLOCK" | grep -qE 'B\.3' \
  && echo "$B5_BLOCK" | grep -qE 'halt' \
  && echo "$B5_BLOCK" | grep -qE '`n`' \
  && pass || fail "CDT-159 B.5 stop list missing B.3 halt/n"
echo "$B5_BLOCK" | grep -q 'empty ready-set' \
  && pass || fail "CDT-159 B.5 stop list missing empty ready-set"
echo "$B5_BLOCK" | grep -qE 'all children `completed`' \
  && echo "$B5_BLOCK" | grep -q 'B.7' \
  && pass || fail "CDT-159 B.5 stop list missing B.7 only when all completed"
echo "$B5_BLOCK" | grep -q 'context-discipline: seed failed' \
  && pass || fail "CDT-159 B.5 stop list missing M13 seed-fail string"
echo "$B5_BLOCK" | grep -q 'MUST NOT run while ready-set' \
  && pass || fail "CDT-159 B.5 missing B.7 MUST NOT while ready-set non-empty"
# B.2 keeps empty-set / blocked-only / all-done stops
echo "$B2_BLOCK" | grep -q 'No ready children' \
  && pass || fail "CDT-159 B.2 missing empty ready-set stop"
echo "$B2_BLOCK" | grep -q 'blocked/in_progress' \
  && pass || fail "CDT-159 B.2 missing blocked/in_progress-only stop"

# (c) commands/epic.md --autopilot row: walk until those stops
if [ -f "$CMD" ]; then
  AP_ROW=$(grep -E '^\| `\[--autopilot' "$CMD")
  echo "$AP_ROW" | grep -q 'keeps walking' \
    && pass || fail "CDT-159 commands/epic.md --autopilot row missing keeps walking"
  echo "$AP_ROW" | grep -q 'ready-set' \
    && pass || fail "CDT-159 commands/epic.md --autopilot row missing ready-set"
else
  fail "CDT-159 commands/epic.md missing"
fi

# docs execute summary + SPEC-025 M7 (AC7/AC8)
if [ -f "$DOCS_EPIC" ]; then
  grep -q 'keeps walking' "$DOCS_EPIC" \
    && pass || fail "CDT-159 docs/commands/epic.md missing keeps walking"
else
  fail "CDT-159 docs/commands/epic.md missing"
fi
echo "$M7_BLOCK" | grep -q 'same run' \
  && pass || fail "CDT-159 SPEC-025 M7 missing same-run continue"
echo "$M7_BLOCK" | grep -q 'SPEC-033' \
  && pass || fail "CDT-159 SPEC-025 M7 missing SPEC-033 cite"
echo "$M7_BLOCK" | grep -q 'N8' \
  && pass || fail "CDT-159 SPEC-025 M7 missing N8 cite"
echo "$M7_BLOCK" | grep -q 'M5e' \
  && pass || fail "CDT-159 SPEC-025 M7 missing M5e cite"

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
keep_tmp "$WT_TMP"
run_wt() {
  local want="$1"; shift
  set +e
  OUT=$(EPIC_ROOT="$WT_TMP" bash "$LIB" "$@" 2>&1)
  RC=$?
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
keep_tmp "$C2_TMP"
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
  # Both sides canonical: TMPDIR with a trailing slash spells C2_TMP with `//`,
  # while the live script prints the collapsed form (macOS lane).
  [ "$(path_canon "$INT_PATH")" = "$(path_canon "$C2_TMP/.worktrees/epic-CDV-C2-ON")" ] \
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
  keep_tmp "$C4_TMP"
  run_c4() {
    local want="$1"; shift
    set +e
    OUT=$(EPIC_ROOT="$C4_TMP" bash "$LIB" "$@" 2>&1)
    RC=$?
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
  # ONLY while the state is seal-staged (seal_stage non-null; WP 1-09 / W3-37).
  jq 'del(.sealed)' "$C4_TMP/.claude/epics/CDV-C4-END/state.json" \
    >"$C4_TMP/c4-unseal.tmp"
  mv "$C4_TMP/c4-unseal.tmp" "$C4_TMP/.claude/epics/CDV-C4-END/state.json"
  # a leaked env var alone (no seal_stage) bypasses nothing
  set +e
  OUT=$(EPIC_ROOT="$C4_TMP" EPIC_ALLOW_SEAL_RELEASE=1 \
    bash "$LIB" assert-release-allowed CDV-C4-END 2>&1)
  RC=$?
  [ "$RC" -eq 64 ] && pass || fail "c4-8 env without seal_stage must not bypass (rc=$RC out=$OUT)"
  echo "$OUT" | grep -q 'release=end mode until seal' \
    && pass || fail "c4-8 env-without-stage message (out=$OUT)"
  # seal-staged + env → allowed
  jq '.seal_stage={base_sha:"b",staged_tree:"t",added_paths:[]}' \
    "$C4_TMP/.claude/epics/CDV-C4-END/state.json" >"$C4_TMP/c4-stage.tmp"
  mv "$C4_TMP/c4-stage.tmp" "$C4_TMP/.claude/epics/CDV-C4-END/state.json"
  set +e
  OUT=$(EPIC_ROOT="$C4_TMP" EPIC_ALLOW_SEAL_RELEASE=1 \
    bash "$LIB" assert-release-allowed CDV-C4-END 2>&1)
  RC=$?
  [ "$RC" -eq 0 ] && pass || fail "c4-8 seal env bypass while staged rc=$RC out=$OUT"
  # seal-staged without env still fails (the stage is not a bypass by itself)
  run_c4 64 assert-release-allowed CDV-C4-END
  # stage cleared → env no longer bypasses
  jq '.seal_stage=null' "$C4_TMP/.claude/epics/CDV-C4-END/state.json" \
    >"$C4_TMP/c4-unstage.tmp"
  mv "$C4_TMP/c4-unstage.tmp" "$C4_TMP/.claude/epics/CDV-C4-END/state.json"
  set +e
  OUT=$(EPIC_ROOT="$C4_TMP" EPIC_ALLOW_SEAL_RELEASE=1 \
    bash "$LIB" assert-release-allowed CDV-C4-END 2>&1)
  RC=$?
  [ "$RC" -eq 64 ] && pass || fail "c4-8 env after stage cleared must not bypass (rc=$RC)"
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
  keep_tmp "$C5_TMP"
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

    # (c5-6) seal failure (hook fail) -> master clean, sealed=false, no partial
    HOOK_LOG=$(mktemp "${TMPDIR:-/tmp}/epic-c5-hook.XXXXXX")
    : >"$HOOK_LOG"
    FAIL_HOOK="echo FAIL_HOOK >>\"$HOOK_LOG\"; exit 1"
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" EPIC_TEST_MODE=1 EPIC_SEAL_RELEASE_HOOK="$FAIL_HOOK" \
      bash "$LIB" seal CDV-C5-END 2>&1)
    RC=$?
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
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" EPIC_TEST_MODE=1 EPIC_SEAL_RELEASE_HOOK="$OK_HOOK" \
      bash "$LIB" seal CDV-C5-END 2>&1)
    RC=$?
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
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" EPIC_TEST_MODE=1 EPIC_SEAL_RELEASE_HOOK="$OK_HOOK" \
      bash "$LIB" seal CDV-C5-END 2>&1)
    RC=$?
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
    # WP 1-05 C2: staged seal_stage matches write-tree and nothing else is
    # dirty -> bare --abort resets it via safe-reset --stage (rc=0); no
    # --force needed for the seal-owned stage itself.
    run_c5 0 seal CDV-C5-HO --abort
    echo "$OUT" | jq -e '.aborted==true and .sealed==false' >/dev/null \
      && pass || fail "c5-9 staged bare abort JSON (out=$OUT)"
    git -C "$C5_TMP" diff --quiet && git -C "$C5_TMP" diff --cached --quiet \
      && pass || fail "c5-9 staged bare abort left dirty"
    jq -e '.seal_stage == null' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json" >/dev/null 2>&1 \
      && pass || fail "c5-9 staged bare abort seal_stage not nulled"
    jq -e '(.sealed // false)==false' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json" >/dev/null \
      && pass || fail "c5-9 abort must not seal"

    # (c5-d2) clean bare abort → rc=0 (tree already clean after bare abort)
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
    [ "$RC" -eq 1 ] && pass || fail "c5-d1 dirty bare abort rc=$RC out=$OUT"
    echo "$OUT" | grep -q 'dirty' && echo "$OUT" | grep -q 'refuse' \
      && pass || fail "c5-d1 stderr dirty+refuse (out=$OUT)"
    [ -f "$C5_TMP/wip.txt" ] && pass || fail "c5-d1 wip.txt wiped on bare abort"
    [ "$(git -C "$C5_TMP" hash-object wip.txt)" = "$WIP_SHA" ] \
      && pass || fail "c5-d1 wip content mutated"
    [ "$(jq -r '.sealed // false' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json")" = "$SEALED_BEFORE" ] \
      && pass || fail "c5-d1 sealed flipped"

    # (c5-d3) dirty (tracked edit + untracked wip.txt) + --abort --force ->
    # C2: stash then reset. Named stash holds the tracked edit; the
    # untracked wip.txt survives (plain `git stash push` has no -u; `reset
    # --hard` never removes untracked files; never `git clean`).
    printf '# c5-d3 tracked edit\n' >>"$C5_TMP/.gitignore"
    C5_D3_ERR=$(mktemp "${TMPDIR:-/tmp}/epic-c5-d3-err.XXXXXX")
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" bash "$LIB" seal CDV-C5-HO --abort --force 2>"$C5_D3_ERR")
    RC=$?
    ERR=$(cat "$C5_D3_ERR"); rm -f "$C5_D3_ERR"
    [ "$RC" -eq 0 ] && pass || fail "c5-d3 abort --force rc=$RC out=$OUT err=$ERR"
    echo "$OUT" | jq -e '(.aborted==true or .reason=="already_sealed")' >/dev/null \
      && pass || fail "c5-d3 force JSON (out=$OUT)"
    printf '%s' "$ERR" | grep -qi 'stash then reset' \
      && pass || fail "c5-d3 stderr missing 'stash then reset' (err=$ERR)"
    [ -f "$C5_TMP/wip.txt" ] && pass || fail "c5-d3 force wiped untracked wip.txt"
    STASH_REF=$(git -C "$C5_TMP" stash list | grep "epic-seal-CDV-C5-HO-" | head -1 | cut -d: -f1)
    [ -n "$STASH_REF" ] && pass || fail "c5-d3 force missing named stash"
    if [ -n "$STASH_REF" ]; then
      git -C "$C5_TMP" stash show -p "$STASH_REF" | grep -q 'c5-d3 tracked edit' \
        && pass || fail "c5-d3 stash missing tracked edit"
    fi
    git -C "$C5_TMP" diff --quiet && git -C "$C5_TMP" diff --cached --quiet \
      && pass || fail "c5-d3 force left dirty tracked tree"

    # (c5-d4) already_sealed + dirty bare abort → rc=1; no wipe; sealed still true
    jq -e '.sealed==true' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json" >/dev/null \
      && pass || fail "c5-d4 precondition sealed=true"
    printf 'wip-sealed\n' >"$C5_TMP/wip-sealed.txt"
    set +e
    OUT=$(cd "$C5_TMP" && EPIC_ROOT="$C5_TMP" bash "$LIB" seal CDV-C5-HO --abort 2>&1)
    RC=$?
    [ "$RC" -eq 1 ] && pass || fail "c5-d4 already_sealed dirty abort rc=$RC out=$OUT"
    echo "$OUT" | grep -q 'dirty' && echo "$OUT" | grep -q 'refuse' \
      && pass || fail "c5-d4 stderr dirty+refuse (out=$OUT)"
    [ -f "$C5_TMP/wip-sealed.txt" ] && pass || fail "c5-d4 wiped wip-sealed.txt"
    jq -e '.sealed==true' "$C5_TMP/.claude/epics/CDV-C5-HO/state.json" >/dev/null \
      && pass || fail "c5-d4 sealed no longer true"
    # cleanup dirty for later cases
    rm -f "$C5_TMP/wip.txt" "$C5_TMP/wip-sealed.txt"

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
for f in "$CMD" "$DOCS_EPIC" "$SKILL_BODY"; do
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
for f in "$CMD" "$DOCS_EPIC" "$SKILL_BODY" "$SPEC"; do
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

# (c7-e8) CDT-293 [05 E8]: structural — every epic-lib subcommand invoked in
# the skill body / commands doc exists in epic-lib.sh's `case "$SUBCMD"`
# dispatch. Replaces prose-phrase mention greps: a fence naming a subcommand
# the lib does not implement (F9-style drift) fails here, not at runtime.
# A token counts as an invoked subcommand only after `"$EPIC_LIB"` (fence
# call) or inside one backtick span of `epic-lib[.sh] <sub>` (prose cite,
# bounded path prefix allowed) — bare prose like "epic-lib thin wrapper" or
# "`epic-lib` only" is not a call. Inline-code shapes with args after the sub
# (e.g. `epic-lib.sh mark-done "$T"`) are not extracted — the fences carry
# the callable surface.
epic_lib_case_subcmds() {
  awk '/^case "\$SUBCMD" in/ {f=1; next} /^esac/ {f=0} f && /^[[:space:]]+[a-z][a-z-]*\)/ {sub(/\).*/,""); sub(/^[[:space:]]+/,""); print}' "$1" | LC_ALL=C sort -u
}
epic_lib_used_subcmds() {
  grep -hoE '"\$EPIC_LIB"[[:space:]]+[a-z][a-z-]+|`[^`]{0,40}epic-lib(\.sh)?[[:space:]]+[a-z][a-z-]+`' "$@" 2>/dev/null \
    | sed -E 's/.*[[:space:]]//; s/`$//' | LC_ALL=C sort -u
}
IMPL_SUBCMDS=$(epic_lib_case_subcmds "$LIB")
USED_SUBCMDS=$(epic_lib_used_subcmds "$SKILL_BODY" "$CMD")
if [ -n "$IMPL_SUBCMDS" ] && [ -n "$USED_SUBCMDS" ]; then
  E8_DRIFT=$(comm -23 <(printf '%s\n' "$USED_SUBCMDS") <(printf '%s\n' "$IMPL_SUBCMDS"))
  if [ -z "$E8_DRIFT" ]; then
    pass
  else
    fail "c7-e8 fence cmds not in epic-lib case list: $(printf '%s' "$E8_DRIFT" | tr '\n' ' ')"
  fi
else
  fail "c7-e8 extractor empty (impl=[${IMPL_SUBCMDS:-}] used=[${USED_SUBCMDS:-}])"
fi
# c7-e8-bite (negative control): a planted fence invoking a nonexistent
# subcommand is flagged by the same extractor+diff, proving the check bites.
printf 'bash "$EPIC_LIB" bogus-sub X\n`epic-lib.sh init` Y\n' > "$TMPROOT/c7-e8-neg.md"
E8_DRIFT_NEG=$(epic_lib_used_subcmds "$TMPROOT/c7-e8-neg.md" | comm -23 - <(printf '%s\n' "$IMPL_SUBCMDS"))
rm -f "$TMPROOT/c7-e8-neg.md"
if [ "$E8_DRIFT_NEG" = "bogus-sub" ]; then
  pass
else
  fail "c7-e8 negative control: planted bogus-sub not flagged (got: ${E8_DRIFT_NEG:-none})"
fi

# (c7-4) docs/commands documents seal + M11 carve-out
if [ -f "$DOCS_EPIC" ]; then
  grep -qi 'seal' "$DOCS_EPIC" && pass || fail "c7-4 docs/commands/epic.md missing seal"
  grep -q 'carve-out\|M11' "$DOCS_EPIC" && pass || fail "c7-4 docs missing M11/carve-out"
  grep -q 'epic-<ID>\|epic-<EPIC-ID>' "$DOCS_EPIC" \
    && pass || fail "c7-4 docs missing epic-<ID> path"
fi

# (c7-5) skill documents M11 carve-out + seal B.7
if [ -f "$SKILL_BODY" ]; then
  grep -q 'M11 carve-out' "$SKILL_BODY" && pass || fail "c7-5 SKILL missing M11 carve-out"
  grep -q 'B.7 End-of-epic seal\|### B.7' "$SKILL_BODY" && pass || fail "c7-5 SKILL missing B.7"
  grep -q 'ensure-integration-worktree' "$SKILL_BODY" && pass || fail "c7-5 SKILL missing ensure"
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
keep_tmp "$SYNC_ROOT"
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
if [ -f "$SKILL_BODY" ]; then
  grep -q 'Mode F' "$SKILL_BODY" && grep -q 'sync-apply' "$SKILL_BODY" \
    && pass || fail "s8 SKILL missing Mode F / sync-apply"
  grep -q '/epic sync' "$SKILL_BODY" \
    && pass || fail "s8 SKILL missing /epic sync"
fi

rm -f "$V1" "$V2" "$V3" "$V4"
rm -rf "$SYNC_ROOT"
unset EPIC_ROOT

# ---- CDT-169: EPIC-ID charset (AC2–AC8) ------------------------------------
{
  CS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/epic-charset.XXXXXX")
  keep_tmp "$CS_TMP"
  run_cs() {
    local want="$1"; shift
    set +e
    OUT=$(EPIC_ROOT="$CS_TMP" bash "$LIB" "$@" 2>&1)
    RC=$?
    if [ "$RC" -eq "$want" ]; then pass
    else fail "cs exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 500; echo
    fi
  }

  # Soft stderr lock (AC8): invalid + allowlist pattern
  assert_cs_reject() {
    local label="$1"; shift
    run_cs 64 "$@"
    echo "$OUT" | grep -qi 'invalid' \
      && pass || fail "cs $label missing 'invalid' (out=$OUT)"
    echo "$OUT" | grep -qE '\[A-Za-z0-9_-\]|allowed' \
      && pass || fail "cs $label missing allowlist (out=$OUT)"
  }

  BAD_IDS=('../' '../../' 'foo/../bar' '..' '.' '/tmp/x' '/' 'has space')

  # (cs-1) read paths reject (AC5, AC9)
  for bad in "${BAD_IDS[@]}"; do
    assert_cs_reject "show:$bad" show "$bad"
    assert_cs_reject "exists:$bad" exists "$bad"
    assert_cs_reject "ready-set:$bad" ready-set "$bad"
  done

  # (cs-2) write path rejects before FS side effects (AC3)
  mkdir -p "$CS_TMP/.claude/epics"
  before=$(find "$CS_TMP/.claude/epics" -mindepth 1 2>/dev/null | sort || true)
  for bad in "${BAD_IDS[@]}"; do
    assert_cs_reject "init:$bad" init "$bad" --title "x" --mode kickoff
  done
  after=$(find "$CS_TMP/.claude/epics" -mindepth 1 2>/dev/null | sort || true)
  [ "$before" = "$after" ] \
    && pass || fail "cs init created paths under epics (after=$after)"

  # (cs-3) empty id → 64 (cmd-level missing; AC5)
  run_cs 64 show ""
  echo "$OUT" | grep -qi 'missing' \
    && pass || fail "cs empty show want missing (out=$OUT)"
  run_cs 64 exists ""
  run_cs 64 init "" --title "x" --mode kickoff

  # (cs-4) assert-release-allowed bypass also allowlisted (AC4)
  assert_cs_reject "assert:../evil" assert-release-allowed '../evil'
  assert_cs_reject "assert:.." assert-release-allowed '..'
  assert_cs_reject "assert:/tmp/x" assert-release-allowed '/tmp/x'
  # valid unknown ticket still allow (unchanged happy path for charset)
  run_cs 0 assert-release-allowed CDT-169-C99

  # (cs-5) happy path valid ids (AC6)
  for good in CDT-169 EPIC-001 epic_demo-1; do
    run_cs 0 init "$good" --title "ok $good" --mode kickoff
    run_cs 0 exists "$good"
    run_cs 0 show "$good"
    echo "$OUT" | jq -e --arg id "$good" '.epic_id==$id' >/dev/null \
      && pass || fail "cs show $good shape (out=$OUT)"
  done

  rm -rf "$CS_TMP"
}

# ---- CDT-158 / SPEC-025 M16: gap-callout (mid-epic ship warn) ---------------
{
  GAP_TMP=$(mktemp -d "${TMPDIR:-/tmp}/epic-gap.XXXXXX")
  keep_tmp "$GAP_TMP"
  GAP_ERR=$(mktemp "${TMPDIR:-/tmp}/epic-gap-err.XXXXXX")
  run_gap() {
    local want="$1"; shift
    set +e
    OUT=$(EPIC_ROOT="$GAP_TMP" bash "$LIB" "$@" 2>"$GAP_ERR")
    RC=$?
    ERR=$(cat "$GAP_ERR")
    if [ "$RC" -eq "$want" ]; then pass
    else fail "gap exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 400; echo
      echo "  err: $ERR" | head -c 200; echo
    fi
  }
  assert_needles() {
    local label="$1"
    echo "$OUT" | grep -q 'mid-epic ship' \
      && pass || fail "$label missing 'mid-epic ship' (out=$OUT)"
    echo "$OUT" | grep -q 'incomplete:' \
      && pass || fail "$label missing 'incomplete:' (out=$OUT)"
    echo "$OUT" | grep -q 'includes:' \
      && pass || fail "$label missing 'includes:' (out=$OUT)"
    echo "$OUT" | grep -q 'pending:' \
      && pass || fail "$label missing 'pending:' (out=$OUT)"
    echo "$OUT" | grep -q 'partial product:' \
      && pass || fail "$label missing 'partial product:' (out=$OUT)"
  }

  # (g1) usage
  run_gap 64 gap-callout
  run_gap 64 gap-callout A B

  # (g2) unknown ticket / no epic → empty stdout, rc 0
  run_gap 0 gap-callout CDT-GAP-UNKNOWN
  [ -z "$OUT" ] && pass || fail "g2 unknown stdout not empty (out=$OUT)"
  [ -z "$ERR" ] && pass || fail "g2 unknown stderr not empty (err=$ERR)"

  # fixture: C1 completed, C2 pending (per-child release path; no release_bump)
  run_gap 0 init CDT-GAP --title "gap epic" --mode orchestrate
  run_gap 0 add-child CDT-GAP --id CDT-GAP-C1 --slug g1 --title "Child one complete" \
    --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
  run_gap 0 add-child CDT-GAP --id CDT-GAP-C2 --slug g2 --title "Child two pending" \
    --estimate S --agent ic4 --depends-on '["CDT-GAP-C1"]' --problem p --ac '["a"]'
  run_gap 0 set-status CDT-GAP CDT-GAP-C1 completed
  STATE_BEFORE=$(cat "$GAP_TMP/.claude/epics/CDT-GAP/state.json")

  # (g3) C1 completed / C2 pending, shipping C1 → callout + rc 0
  run_gap 0 gap-callout CDT-GAP-C1
  assert_needles "g3"
  echo "$OUT" | grep -q 'CDT-GAP-C2' \
    && pass || fail "g3 missing C2 id (out=$OUT)"
  echo "$OUT" | grep -q 'Child two pending' \
    && pass || fail "g3 missing C2 title (out=$OUT)"
  echo "$OUT" | grep 'includes:' | grep -q 'Child one complete' \
    && pass || fail "g3 includes missing C1 title (out=$OUT)"
  echo "$OUT" | grep 'pending:' | grep -q 'Child two pending' \
    && pass || fail "g3 pending missing C2 title (out=$OUT)"
  echo "$OUT" | grep 'pending:' | grep -q 'Child one complete' \
    && fail "g3 pending must not list shipping C1 (out=$OUT)" || pass

  # (g3b) epic-dir lookup (same fixture)
  run_gap 0 gap-callout CDT-GAP
  assert_needles "g3b epic-id"
  echo "$OUT" | grep -q 'CDT-GAP-C2' \
    && pass || fail "g3b missing C2 id (out=$OUT)"

  # (g3c) read-only — state unchanged
  STATE_AFTER=$(cat "$GAP_TMP/.claude/epics/CDT-GAP/state.json")
  [ "$STATE_BEFORE" = "$STATE_AFTER" ] \
    && pass || fail "g3c gap-callout mutated state.json"

  # (g4) linear_id lookup of completed C1
  jq '(.children[] | select(.id=="CDT-GAP-C1") | .linear_id) = "LIN-GAP-1"' \
    "$GAP_TMP/.claude/epics/CDT-GAP/state.json" >"$GAP_TMP/gap-lin.tmp"
  mv "$GAP_TMP/gap-lin.tmp" "$GAP_TMP/.claude/epics/CDT-GAP/state.json"
  run_gap 0 gap-callout LIN-GAP-1
  assert_needles "g4 linear_id"
  echo "$OUT" | grep -q 'CDT-GAP-C2' \
    && pass || fail "g4 missing C2 id via linear_id (out=$OUT)"
  echo "$OUT" | grep -q 'Child two pending' \
    && pass || fail "g4 missing C2 title via linear_id (out=$OUT)"

  # (g5) last remaining child (C2 pending, all others completed) → empty
  run_gap 0 gap-callout CDT-GAP-C2
  [ -z "$OUT" ] && pass || fail "g5 last-remaining stdout not empty (out=$OUT)"
  [ "$RC" -eq 0 ] && pass || fail "g5 last-remaining rc=$RC"

  # (g6) shipping in_progress counts as includes
  run_gap 0 set-status CDT-GAP CDT-GAP-C1 in_progress
  run_gap 0 gap-callout CDT-GAP-C1
  assert_needles "g6 in_progress-shipping"
  echo "$OUT" | grep 'includes:' | grep -q 'Child one complete' \
    && pass || fail "g6 includes missing in_progress shipping (out=$OUT)"
  echo "$OUT" | grep 'pending:' | grep -q 'Child two pending' \
    && pass || fail "g6 pending missing C2 (out=$OUT)"
  echo "$OUT" | grep 'pending:' | grep -q 'Child one complete' \
    && fail "g6 pending must not list shipping (out=$OUT)" || pass

  # (g7) all-complete → empty stdout rc 0
  run_gap 0 set-status CDT-GAP CDT-GAP-C1 completed
  run_gap 0 set-status CDT-GAP CDT-GAP-C2 completed
  run_gap 0 gap-callout CDT-GAP-C1
  [ -z "$OUT" ] && pass || fail "g7 all-complete C1 stdout not empty (out=$OUT)"
  run_gap 0 gap-callout CDT-GAP
  [ -z "$OUT" ] && pass || fail "g7 all-complete epic stdout not empty (out=$OUT)"

  # (g8) charset reject 64 before path join (same allowlist as assert)
  run_gap 64 gap-callout '../evil'
  echo "$ERR" | grep -qi 'invalid' \
    && pass || fail "g8 missing 'invalid' (err=$ERR)"
  echo "$ERR" | grep -qE '\[A-Za-z0-9_-\]|allowed' \
    && pass || fail "g8 missing allowlist (err=$ERR)"
  run_gap 64 gap-callout '..'
  echo "$ERR" | grep -qi 'invalid' \
    && pass || fail "g8 .. missing invalid (err=$ERR)"
  run_gap 64 gap-callout '/tmp/x'
  echo "$ERR" | grep -qi 'invalid' \
    && pass || fail "g8 /tmp/x missing invalid (err=$ERR)"
  # no path created from invalid id
  [ ! -e "$GAP_TMP/.claude/epics/../evil" ] \
    && pass || fail "g8 path joined before charset reject"

  # (g9) C4 still 64 under release_bump — callout not mixed into that message
  run_gap 0 init CDT-GAP-END --title "end" --mode orchestrate \
    --worktree-enabled true --release-bump minor
  run_gap 0 add-child CDT-GAP-END --id CDT-GAP-END-C1 --slug e1 --title "E1" \
    --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
  run_gap 0 add-child CDT-GAP-END --id CDT-GAP-END-C2 --slug e2 --title "E2" \
    --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
  run_gap 0 set-status CDT-GAP-END CDT-GAP-END-C1 completed
  set +e
  C4_OUT=$(EPIC_ROOT="$GAP_TMP" bash "$LIB" assert-release-allowed CDT-GAP-END-C1 2>&1)
  C4_RC=$?
  [ "$C4_RC" -eq 64 ] && pass || fail "g9 C4 rc=$C4_RC want 64"
  echo "$C4_OUT" | grep -q 'epic CDT-GAP-END is in release=end mode until seal (CDT-141)' \
    && pass || fail "g9 C4 message drifted (out=$C4_OUT)"
  echo "$C4_OUT" | grep -q 'mid-epic ship' \
    && fail "g9 callout mixed into C4 message (out=$C4_OUT)" || pass
  echo "$C4_OUT" | grep -q 'partial product:' \
    && fail "g9 partial-product mixed into C4 (out=$C4_OUT)" || pass
  # gap-callout itself still 0 + needles (orthogonal to C4)
  run_gap 0 gap-callout CDT-GAP-END-C1
  assert_needles "g9 gap under release_bump"

  # (g10) /release Step 0 wires gap-callout
  REL_SKILL="$HERE/../release/SKILL.md"
  grep -q 'gap-callout' "$REL_SKILL" \
    && pass || fail "g10 skills/release/SKILL.md missing gap-callout"

  rm -f "$GAP_ERR"
  rm -rf "$GAP_TMP"
}

# ---- M6 concurrent RMW flock (CDT-165 / SPEC-025 AC1+AC7) --------------------
echo ""
echo "=== M6 concurrent state RMW (CDT-165) ==="
# regression: pre-CDT-165 unlocked RMW lost updates under concurrent mutators
# (last-write-wins drops C2 or C1 status/outcome when set-status ∥ add-child).
RACE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/epic-race-XXXXXX")
keep_tmp "$RACE_ROOT"
export EPIC_ROOT="$RACE_ROOT"

bash "$LIB" init CDV-RACE --title "Race epic" --mode kickoff >/dev/null
bash "$LIB" add-child CDV-RACE --id CDV-RACE-C1 --slug base --title "Base" \
  --estimate S --agent ic4 --depends-on '[]' >/dev/null

# Pair A: set-status C1 completed + outcome  ∥  add-child C2
EPIC_ROOT="$RACE_ROOT" bash "$LIB" set-status CDV-RACE CDV-RACE-C1 completed \
  --outcome "from-A" >"$RACE_ROOT/out-a.txt" 2>&1 &
pid_a=$!
EPIC_ROOT="$RACE_ROOT" bash "$LIB" add-child CDV-RACE --id CDV-RACE-C2 --slug peer \
  --title "Peer" --estimate M --agent ic5 --depends-on '[]' \
  >"$RACE_ROOT/out-b.txt" 2>&1 &
pid_b=$!
rc_a=0; wait "$pid_a" || rc_a=$?
rc_b=0; wait "$pid_b" || rc_b=$?

[ "$rc_a" -eq 0 ] && pass || fail "race set-status rc=$rc_a: $(head -c 200 "$RACE_ROOT/out-a.txt")"
[ "$rc_b" -eq 0 ] && pass || fail "race add-child C2 rc=$rc_b: $(head -c 200 "$RACE_ROOT/out-b.txt")"

STATE_RACE="$RACE_ROOT/.claude/epics/CDV-RACE/state.json"
jq -e '.children[] | select(.id=="CDV-RACE-C1") | .status=="completed"' "$STATE_RACE" >/dev/null \
  && pass || fail "race: C1 status not completed (lost update)"
jq -e --arg id CDV-RACE-C1 \
  '.children[] | select(.id==$id) | .outcome_summary=="from-A"' "$STATE_RACE" >/dev/null \
  && pass || fail "race: C1 outcome missing (lost update)"
jq -e '[.children[].id] | index("CDV-RACE-C2") != null' "$STATE_RACE" >/dev/null \
  && pass || fail "race: C2 missing from children (lost update)"

# Stress: three concurrent pure mutators — project + seed path + C3
EPIC_ROOT="$RACE_ROOT" bash "$LIB" set-linear-project CDV-RACE proj-race \
  >"$RACE_ROOT/out-c.txt" 2>&1 &
pid_c=$!
EPIC_ROOT="$RACE_ROOT" bash "$LIB" set-last-seed CDV-RACE /tmp/seed-race.md \
  >"$RACE_ROOT/out-d.txt" 2>&1 &
pid_d=$!
EPIC_ROOT="$RACE_ROOT" bash "$LIB" add-child CDV-RACE --id CDV-RACE-C3 --slug third \
  --title "Third" --estimate S --agent ic4 --depends-on '[]' \
  >"$RACE_ROOT/out-e.txt" 2>&1 &
pid_e=$!
rc_c=0; wait "$pid_c" || rc_c=$?
rc_d=0; wait "$pid_d" || rc_d=$?
rc_e=0; wait "$pid_e" || rc_e=$?

[ "$rc_c" -eq 0 ] && pass || fail "race set-linear-project rc=$rc_c: $(head -c 200 "$RACE_ROOT/out-c.txt")"
[ "$rc_d" -eq 0 ] && pass || fail "race set-last-seed rc=$rc_d: $(head -c 200 "$RACE_ROOT/out-d.txt")"
[ "$rc_e" -eq 0 ] && pass || fail "race add-child C3 rc=$rc_e: $(head -c 200 "$RACE_ROOT/out-e.txt")"

jq -e '.linear_project_id=="proj-race"' "$STATE_RACE" >/dev/null \
  && pass || fail "race: linear_project_id lost"
jq -e '.last_seed_path=="/tmp/seed-race.md"' "$STATE_RACE" >/dev/null \
  && pass || fail "race: last_seed_path lost"
jq -e '[.children[].id] | index("CDV-RACE-C3") != null' "$STATE_RACE" >/dev/null \
  && pass || fail "race: C3 missing (lost update)"
# Prior fields still present after stress
jq -e '.children[] | select(.id=="CDV-RACE-C1") | .status=="completed"' "$STATE_RACE" >/dev/null \
  && pass || fail "race stress: C1 status lost"
jq -e '[.children[].id] | index("CDV-RACE-C2") != null' "$STATE_RACE" >/dev/null \
  && pass || fail "race stress: C2 lost"
N_RACE=$(jq '.children | length' "$STATE_RACE")
[ "$N_RACE" -eq 3 ] && pass || fail "race: expected 3 children got $N_RACE"

# EPICS_LOCK: a portable-lock directory (CDT-284) holding a pid+epoch stamp —
# released again after the run, so assert the shape the mutators leave behind.
if [ -e "$RACE_ROOT/.claude/epics/.lock" ]; then
  fail "race: EPICS_LOCK left behind at .claude/epics/.lock (release failed)"
else
  pass "race: EPICS_LOCK released"
fi
LEFTOVER=$(find "$RACE_ROOT/.claude/epics" -name 'state.json.tmp.*' 2>/dev/null | wc -l)
[ "$LEFTOVER" -eq 0 ] && pass || fail "race: tmp leftovers $LEFTOVER"

rm -rf "$RACE_ROOT"
unset EPIC_ROOT

# ---- SPEC-033 wp-1-08-autopilot-state AC G ----------------------------------

# G1: no bash fence in SKILL.md has a top-level `return` line.
G_RET="$(fence_top_level_returns "$SKILL_BODY")"
[ -z "$G_RET" ] && pass || fail "SKILL.md fence has a top-level return: $G_RET"

# G2: the B.6 build-seed fence, run with a failing build-seed stub (via a
# CLAUDE_PLUGIN_ROOT fixture root — plugin-dir.sh Tier 0 force, real
# plugin-dir.sh copied in, epic-lib.sh replaced by the stub), exits
# non-zero and never reaches validate-seed. Unwrapped (no function
# wrapper): the fence's `return`-turned-`exit 1` needs to halt at the top
# level, the same discipline test-end-state-safety.sh uses for AC F.
G_FIXROOT=$(mktemp -d "${TMPDIR:-/tmp}/epic-g2.XXXXXX")
keep_tmp "$G_FIXROOT"
mkdir -p "$G_FIXROOT/skills/epic"
cp "$HERE/../plugin-dir.sh" "$G_FIXROOT/skills/plugin-dir.sh"
VALIDATE_MARKER="$G_FIXROOT/validate-seed-called"
cat >"$G_FIXROOT/skills/epic/epic-lib.sh" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  build-seed) echo "stub: build-seed failed" >&2; exit 1 ;;
  validate-seed) : >"$VALIDATE_MARKER"; exit 0 ;;
  *) exit 64 ;;
esac
STUB_EOF
chmod +x "$G_FIXROOT/skills/epic/epic-lib.sh"

B6_BLOCK="$(fence_nth "$SKILL_BODY" "### B.6" 1)"
if [ -z "$B6_BLOCK" ]; then
  fail "B.6 build-seed fence not found"
else
  B6_SUBST="$(printf '%s\n' "$B6_BLOCK" | sed \
    -e 's|<EPIC-ID>|M13-G2|g' \
    -e 's|<next ready CHILD-ID or omit --next for auto>|M13-G2-C1|g')"
  B6_RUNFILE=$(mktemp "$G_FIXROOT/run-b6.XXXXXX")
  printf '%s\n' "$B6_SUBST" >"$B6_RUNFILE"
  set +e
  B6_OUT=$(CLAUDE_PLUGIN_ROOT="$G_FIXROOT" bash "$B6_RUNFILE" 2>&1)
  B6_RC=$?
  [ "$B6_RC" -ne 0 ] && pass || fail "B.6 fence exits non-zero on build-seed failure (rc=$B6_RC): $B6_OUT"
  if [ -f "$VALIDATE_MARKER" ]; then
    fail "B.6 fence called validate-seed after build-seed failed"
  else
    pass
  fi
  echo "$B6_OUT" | grep -qF 'context-discipline: seed failed' \
    && pass || fail "B.6 fence prints the fail-closed one-liner: $B6_OUT"
fi
rm -rf "$G_FIXROOT"

# G3: epic-lib.sh init X --title --mode orchestrate -> 64, no state.json
# (AC-literal case — already 64 on pre-fix code via a different code path:
# "orchestrate" lands as an unexpected trailing positional. Non-bite; kept
# because the AC text names it verbatim).
G3_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/epic-g3.XXXXXX")
keep_tmp "$G3_ROOT"
set +e
G3_OUT=$(EPIC_ROOT="$G3_ROOT" bash "$LIB" init X --title --mode orchestrate 2>&1)
G3_RC=$?
[ "$G3_RC" -eq 64 ] && pass || fail "init X --title --mode orchestrate rc=$G3_RC want 64: $G3_OUT"
if [ -f "$G3_ROOT/.claude/epics/X/state.json" ]; then
  fail "init X --title --mode orchestrate wrote state.json"
else
  pass
fi
rm -rf "$G3_ROOT"

# G4: the real bite — --title swallows the NEXT flag as its value when
# --title is not the last flag processed; --worktree-enabled never runs as
# its own flag, wt_set stays false, and title="--worktree-enabled" still
# passes the non-empty check, so pre-fix code writes state.json with that
# title. Fails on pre-fix epic-lib.sh; passes only with the new guard.
G4_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/epic-g4.XXXXXX")
keep_tmp "$G4_ROOT"
set +e
G4_OUT=$(EPIC_ROOT="$G4_ROOT" bash "$LIB" init X --mode orchestrate --title --worktree-enabled 2>&1)
G4_RC=$?
[ "$G4_RC" -eq 64 ] && pass || fail "init X --mode orchestrate --title --worktree-enabled rc=$G4_RC want 64: $G4_OUT"
if [ -f "$G4_ROOT/.claude/epics/X/state.json" ]; then
  fail "init X --mode orchestrate --title --worktree-enabled wrote state.json"
else
  pass
fi
rm -rf "$G4_ROOT"

# ---- SPEC-025 wp-1-09-epic-seal ----------------------------------------------
echo "=== WP 1-09 epic seal ==="
W9_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/epic-w109.XXXXXX")
keep_tmp "$W9_ROOT"
W9_SKILL="$SKILL_BODY"   # WP 7-04: section bodies live in stage files
W9_CMD="$HERE/../../commands/epic.md"
W9_DOCS="$HERE/../../docs/commands/epic.md"

# w9 <want-rc> <lib args...> — private EPIC_ROOT; sets OUT, RC.
w9() {
  local want="$1"; shift
  set +e
  OUT=$(cd "$W9_ROOT" && EPIC_ROOT="$W9_ROOT" bash "$LIB" "$@" 2>&1)
  RC=$?
  if [ "$RC" -eq "$want" ]; then pass
  else fail "w109 exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 500; echo
  fi
}

# --- T1 / CDT-305: commands/epic.md --autopilot row says seal-intent, not "unused"
# _w9_ap_row_ok <file>: the --autopilot row names seal-intent and release_bump
# and says neither "Unused" nor "Independent of" (Linear goal: one contract in
# commands/epic.md, the epic SKILL and SPEC-033).
_w9_ap_row_ok() {
  local row
  row=$(grep -F '| `[--autopilot[=<token>]]` |' "$1" | head -n1)
  [ -n "$row" ] || return 1
  printf '%s' "$row" | grep -q 'seal-intent' || return 1
  printf '%s' "$row" | grep -q 'release_bump' || return 1
  if printf '%s' "$row" | grep -qi 'unused'; then return 1; fi
  if printf '%s' "$row" | grep -qi 'independent of'; then return 1; fi
  return 0
}
# planted negative controls: the pre-WP 1-09 wording, and a row that has the new
# words but still says "Independent of"
W9_OLD_ROW=$(mktemp "$W9_ROOT/old-row.XXXXXX")
printf '%s\n' '| `[--autopilot[=<token>]]` | self-answer gates. Unused by `/epic` (never ships) but resolved+carried for seed parity. |' >"$W9_OLD_ROW"
if _w9_ap_row_ok "$W9_OLD_ROW"; then fail "w109 T1 negative control: old row accepted"; else pass; fi
W9_IND_ROW=$(mktemp "$W9_ROOT/ind-row.XXXXXX")
printf '%s\n' '| `[--autopilot[=<token>]]` | A bump is seal-intent and sets release_bump. Independent of `--worktree`/`--release`. |' >"$W9_IND_ROW"
if _w9_ap_row_ok "$W9_IND_ROW"; then fail "w109 T1 negative control: 'Independent of' row accepted"; else pass; fi
if _w9_ap_row_ok "$W9_CMD"; then pass; else fail "w109 T1 commands/epic.md --autopilot row: want seal-intent + release_bump, no 'Unused' / 'Independent of'"; fi

# _w9_no_orth <file>: no "Orthogonal to `--autopilot`" claim (a bump token is seal-intent)
_w9_no_orth() { if grep -qF 'Orthogonal to `--autopilot`' "$1"; then return 1; fi; return 0; }
W9_ORTH=$(mktemp "$W9_ROOT/orth.XXXXXX")
printf '%s\n' 'Without this flag: no epic seal path. Orthogonal to `--autopilot`. |' >"$W9_ORTH"
if _w9_no_orth "$W9_ORTH"; then fail "w109 T1 negative control: Orthogonal claim accepted"; else pass; fi
if _w9_no_orth "$W9_CMD"; then pass; else fail "w109 T1 commands/epic.md still says Orthogonal to --autopilot"; fi
if _w9_no_orth "$W9_SKILL"; then pass; else fail "w109 T1 SKILL.md still says Orthogonal to --autopilot"; fi
if grep -qF 'Token is unused by' "$W9_SKILL"; then fail "w109 T1 SKILL.md Step 0.5 still says the token is unused"; else pass; fi

# _w9_m5_ok <file>: the M5 ship-choice row's /epic cell says the seal ships it
# (B.7, M14) and not "/epic never ships".
_w9_m5_ok() {
  local row
  row=$(grep -F '| `ship-choice` |' "$1" | head -n1)
  [ -n "$row" ] || return 1
  printf '%s' "$row" | grep -qF 'ships only via B.7 seal (M14)' || return 1
  if printf '%s' "$row" | grep -qF '`/epic` never ships'; then return 1; fi
  return 0
}
W9_OLD_M5=$(mktemp "$W9_ROOT/old-m5.XXXXXX")
printf '%s\n' '  | `ship-choice` | Step 11 (ship options) | **N/A** — `/kickoff` never ships | **N/A** — `/epic` never ships (M11: no code) |' >"$W9_OLD_M5"
if _w9_m5_ok "$W9_OLD_M5"; then fail "w109 T1 negative control: old M5 cell accepted"; else pass; fi
if _w9_m5_ok "$HERE/../autopilot/SKILL.md"; then pass; else fail "w109 T1 skills/autopilot/SKILL.md M5 ship-choice cell: want 'ships only via B.7 seal (M14)'"; fi
if _w9_m5_ok "$HERE/../../specs/core/SPEC-033-autopilot-policy.md"; then pass; else fail "w109 T1 SPEC-033 M5 ship-choice cell: want 'ships only via B.7 seal (M14)'"; fi

# _w9_ap_doc_ok <file>: prose names seal-intent and the resume exit 64 rule
_w9_ap_doc_ok() {
  grep -q 'seal-intent' "$1" || return 1
  grep -q 'release_bump' "$1" || return 1
  grep -qi 'resume' "$1" || return 1
  grep -q '64' "$1" || return 1
  return 0
}
W9_OLD_DOC=$(mktemp "$W9_ROOT/old-doc.XXXXXX")
printf '%s\n' '`--autopilot`: Mode B keeps walking until B.3 halt/`n`.' >"$W9_OLD_DOC"
if _w9_ap_doc_ok "$W9_OLD_DOC"; then fail "w109 T1 negative control: old doc accepted"; else pass; fi
if _w9_ap_doc_ok "$W9_DOCS"; then pass
else fail "w109 T1 docs/commands/epic.md: want seal-intent, release_bump, and the resume exit 64 rule for --autopilot"; fi
W9_S05=$(md_section "$W9_SKILL" "## Step 0.5")
if printf '%s\n' "$W9_S05" | grep -q 'resolve-resume-flags' \
  && printf '%s\n' "$W9_S05" | grep -qi 'on resume'; then pass
else fail "w109 T1 SKILL Step 0.5: BC5 seal-intent must name the resume rule (resolve-resume-flags, on resume)"; fi

# --- T1 / rv-w2-34: resume with --autopilot=<bump> and null release_bump -> 64
w9 0 init W34-NULL --title "null bump" --mode orchestrate
w9 0 init W34-WT --title "worktree only" --mode orchestrate --worktree-enabled true
w9 0 init W34-SEAL --title "sealed intent" --mode orchestrate --worktree-enabled true --release-bump patch
W34_STATE="$W9_ROOT/.claude/epics/W34-NULL/state.json"
W34_SUM=$(cksum <"$W34_STATE")
for W34_TOK in patch minor major; do
  w9 64 resolve-resume-flags W34-NULL -- W34-NULL "--autopilot=$W34_TOK"
  if printf '%s' "$OUT" | grep -q 'release_bump' && printf '%s' "$OUT" | grep -qi 'seal'; then pass
  else fail "w109 W2-34 $W34_TOK: 64 message must name release_bump and seal: $OUT"; fi
done
w9 64 resolve-resume-flags W34-WT -- W34-WT --autopilot=minor
# zero side effects on the refusal
[ "$(cksum <"$W34_STATE")" = "$W34_SUM" ] && pass || fail "w109 W2-34 state changed by the refused resume"
# token that is not a release bump never adds seal-intent: still resumes
w9 0 resolve-resume-flags W34-NULL -- W34-NULL --autopilot=master
printf '%s' "$OUT" | jq -e '.release_bump==null' >/dev/null && pass || fail "w109 W2-34 master token: release_bump must stay null ($OUT)"
w9 0 resolve-resume-flags W34-NULL -- W34-NULL --autopilot
w9 0 resolve-resume-flags W34-NULL -- W34-NULL
# state already holds the bump: resume keeps it and assert-release-allowed blocks a mid-epic land
w9 0 resolve-resume-flags W34-SEAL -- W34-SEAL --autopilot=patch
printf '%s' "$OUT" | jq -e '.release_bump=="patch" and .worktree_enabled==true' >/dev/null \
  && pass || fail "w109 W2-34 resume with stored bump: want patch/true ($OUT)"
w9 64 assert-release-allowed W34-SEAL

# --- T2 / CDT-315: ensure-integration-worktree / ensure-ticket-worktree never
# exit 0 when worktree-lib fails. A stub that exits 0 with an empty path is a
# failure; a stub that exits N keeps rc N.
W9_WT_EMPTY="$W9_ROOT/wt-exit0-empty.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$W9_WT_EMPTY"
W9_WT_RC3="$W9_ROOT/wt-exit3.sh"
printf '#!/usr/bin/env bash\necho "stub: boom" >&2\nexit 3\n' >"$W9_WT_RC3"
# w9wt <want-rc> <wt-lib> <lib args...>
w9wt() {
  local want="$1" wtlib="$2"; shift 2
  set +e
  OUT=$(cd "$W9_ROOT" && EPIC_ROOT="$W9_ROOT" EPIC_WT_LIB="$wtlib" bash "$LIB" "$@" 2>&1)
  RC=$?
  if [ "$RC" -eq "$want" ]; then pass
  else fail "w109 wt exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 500; echo
  fi
}
w9 0 init W315 --title "wt fail" --mode orchestrate --worktree-enabled true
w9wt 1 "$W9_WT_EMPTY" ensure-integration-worktree W315
w9wt 3 "$W9_WT_RC3" ensure-integration-worktree W315
if jq -e '(.integration_path // null) == null' "$W9_ROOT/.claude/epics/W315/state.json" >/dev/null; then pass
else fail "w109 CDT-315 failed ensure must not record integration_path"; fi
w9wt 1 "$W9_WT_EMPTY" ensure-ticket-worktree W315-NOSUCH-TICKET
w9wt 3 "$W9_WT_RC3" ensure-ticket-worktree W315-NOSUCH-TICKET

# --- T4 / W3-37: parent lookup prefers the active parent; mark-done is scoped
# w9child <epic> <child-id> <deps-json> [linear-id]
w9child() {
  local epic="$1" cid="$2" deps="$3" lin="${4:-}"
  if [ -n "$lin" ]; then
    w9 0 add-child "$epic" --id "$cid" --slug s --title t --estimate S --agent ic4 \
      --depends-on "$deps" --problem p --ac '["a"]' --linear-id "$lin"
  else
    w9 0 add-child "$epic" --id "$cid" --slug s --title t --estimate S --agent ic4 \
      --depends-on "$deps" --problem p --ac '["a"]'
  fi
}
# w9state <epic> <jq filter> — rewrite that epic's state.json
w9state() {
  local f="$W9_ROOT/.claude/epics/$1/state.json"
  jq "$2" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}
# Two epics share linear id LIN-DUP-1: A-OLD (sealed, older; first alphabetically)
# and B-NEW (unsealed, newer). The active parent is B-NEW.
w9 0 init A-OLD --title old --mode orchestrate --worktree-enabled true --release-bump patch
w9 0 init B-NEW --title new --mode orchestrate --worktree-enabled true --release-bump patch
w9child A-OLD A-OLD-C1 '[]' LIN-DUP-1
w9child B-NEW B-NEW-C1 '[]' LIN-DUP-1
w9state A-OLD '.sealed=true | .created_at="2026-01-01T00:00:00Z"'
w9state B-NEW '.created_at="2026-06-01T00:00:00Z"'
w9 0 resolve-child-worktree LIN-DUP-1
printf '%s' "$OUT" | jq -e '.epic_id=="B-NEW"' >/dev/null \
  && pass || fail "w109 W3-37 resolve-child-worktree must pick the unsealed parent B-NEW ($OUT)"
w9 64 assert-release-allowed LIN-DUP-1
printf '%s' "$OUT" | grep -q 'epic B-NEW is in release=end mode' \
  && pass || fail "w109 W3-37 assert-release-allowed must name B-NEW, not the sealed A-OLD ($OUT)"

# both unsealed: newest created_at wins, even when the older one sorts first
w9 0 init C-ONE --title one --mode orchestrate
w9 0 init D-TWO --title two --mode orchestrate
w9child C-ONE C-ONE-C1 '[]' LIN-DUP-2
w9child D-TWO D-TWO-C1 '[]' LIN-DUP-2
w9state C-ONE '.created_at="2026-01-01T00:00:00Z"'
w9state D-TWO '.created_at="2026-06-01T00:00:00Z"'
w9 0 resolve-child-worktree LIN-DUP-2
printf '%s' "$OUT" | jq -e '.epic_id=="D-TWO"' >/dev/null \
  && pass || fail "w109 W3-37 newest unsealed parent D-TWO must win ($OUT)"

# both sealed: newest sealed wins
w9 0 init G-S1 --title s1 --mode orchestrate
w9 0 init H-S2 --title s2 --mode orchestrate
w9child G-S1 G-S1-C1 '[]' LIN-DUP-3
w9child H-S2 H-S2-C1 '[]' LIN-DUP-3
w9state G-S1 '.sealed=true | .created_at="2026-01-01T00:00:00Z"'
w9state H-S2 '.sealed=true | .created_at="2026-06-01T00:00:00Z"'
w9 0 resolve-child-worktree LIN-DUP-3
printf '%s' "$OUT" | jq -e '.epic_id=="H-S2"' >/dev/null \
  && pass || fail "w109 W3-37 newest sealed parent H-S2 must win when all are sealed ($OUT)"

# a single match still resolves (no regression)
w9 0 resolve-child-worktree B-NEW-C1
printf '%s' "$OUT" | jq -e '.epic_id=="B-NEW" and .is_epic_child==true' >/dev/null \
  && pass || fail "w109 W3-37 single-match lookup ($OUT)"

# mark-done completes the child only in the resolved epic
w9 0 mark-done LIN-DUP-1
[ "$(jq -r '.children[0].status' "$W9_ROOT/.claude/epics/B-NEW/state.json")" = "completed" ] \
  && pass || fail "w109 W3-37 mark-done must complete the child in B-NEW"
[ "$(jq -r '.children[0].status' "$W9_ROOT/.claude/epics/A-OLD/state.json")" = "pending" ] \
  && pass || fail "w109 W3-37 mark-done must not touch the sealed epic A-OLD"
w9 0 mark-done LIN-NO-SUCH-TICKET

# --- T4 / W3-37: waves in one Kahn pass, one ready-set definition
# w9waves <epic> <expected>
w9waves() {
  w9 0 waves "$1"
  [ "$OUT" = "$2" ] && pass || fail "w109 W3-37 waves $1: got [$OUT] want [$2]"
}
w9 0 init WV-D --title d --mode orchestrate
w9child WV-D WV-D-C1 '[]'
w9child WV-D WV-D-C2 '["WV-D-C1"]'
w9child WV-D WV-D-C3 '["WV-D-C1"]'
w9child WV-D WV-D-C4 '["WV-D-C2","WV-D-C3"]'
w9waves WV-D 'Wave 1: WV-D-C1 → Wave 2: WV-D-C2, WV-D-C3 → Wave 3: WV-D-C4'
# cycle: the cyclic pair lands in one final wave
w9 0 init WV-X --title x --mode orchestrate
w9child WV-X WV-X-C1 '["WV-X-C2"]'
w9child WV-X WV-X-C2 '["WV-X-C1"]'
w9child WV-X WV-X-C3 '[]'
w9waves WV-X 'Wave 1: WV-X-C3 → Wave 2: WV-X-C1, WV-X-C2'
# unknown dep is ignored; a duplicated dep counts once per wave
w9 0 init WV-G --title g --mode orchestrate
w9child WV-G WV-G-C1 '["GHOST-1"]'
w9child WV-G WV-G-C2 '["WV-G-C1","WV-G-C1"]'
w9waves WV-G 'Wave 1: WV-G-C1 → Wave 2: WV-G-C2'
# self-dependency never becomes ready: it falls into the final wave
w9 0 init WV-S --title s --mode orchestrate
w9child WV-S WV-S-C1 '["WV-S-C1"]'
w9child WV-S WV-S-C2 '[]'
w9waves WV-S 'Wave 1: WV-S-C2 → Wave 2: WV-S-C1'
# no children: one empty line
w9 0 init WV-E --title e --mode orchestrate
w9waves WV-E ''
# ids sort as strings (C1 < C10 < C11 < C2)
w9 0 init WV-10 --title t --mode orchestrate
for W9_I in 1 2 3 10 11; do w9child WV-10 "WV-10-C$W9_I" '[]'; done
w9child WV-10 WV-10-C4 '["WV-10-C10"]'
w9waves WV-10 'Wave 1: WV-10-C1, WV-10-C10, WV-10-C11, WV-10-C2, WV-10-C3 → Wave 2: WV-10-C4'
w9 0 ready-set WV-10
[ "$(printf '%s\n' "$OUT" | paste -sd, -)" = "WV-10-C1,WV-10-C10,WV-10-C11,WV-10-C2,WV-10-C3" ] \
  && pass || fail "w109 W3-37 ready-set WV-10 ($OUT)"
w9 0 show WV-10
printf '%s' "$OUT" | jq -e '.ready == ["WV-10-C1","WV-10-C10","WV-10-C11","WV-10-C2","WV-10-C3"]' >/dev/null \
  && pass || fail "w109 W3-37 show.ready WV-10 ($OUT)"

# process count: jq runs per `waves` call must not grow with the edge count
W9_SHIM="$W9_ROOT/shim"
W9_JQLOG="$W9_ROOT/jq-calls.log"
mkdir -p "$W9_SHIM"
W9_REAL_JQ=$(command -v jq)
printf '#!/usr/bin/env bash\necho x >>"%s"\nexec "%s" "$@"\n' "$W9_JQLOG" "$W9_REAL_JQ" >"$W9_SHIM/jq"
chmod +x "$W9_SHIM/jq"
# big fixture: 12 children, 3 deps each (written straight to state.json)
mkdir -p "$W9_ROOT/.claude/epics/WV-BIG"
jq -n '{epic_id:"WV-BIG", title:"big", execution_mode:"orchestrate", children:
  [range(1;13) as $n | {id:"WV-BIG-C\($n)", status:"pending",
    depends_on:([range(1;$n) | "WV-BIG-C\(.)"] | .[-3:])}]}' \
  >"$W9_ROOT/.claude/epics/WV-BIG/state.json"
w9_waves_jq_calls() {  # <epic> -> prints the number of jq processes one `waves` call starts
  : >"$W9_JQLOG"
  ( cd "$W9_ROOT" && PATH="$W9_SHIM:$PATH" EPIC_ROOT="$W9_ROOT" bash "$LIB" waves "$1" >/dev/null 2>&1 ) || true
  wc -l <"$W9_JQLOG" | tr -d ' '
}
W9_CALLS_SMALL=$(w9_waves_jq_calls WV-D)
W9_CALLS_BIG=$(w9_waves_jq_calls WV-BIG)
[ "$W9_CALLS_SMALL" -eq "$W9_CALLS_BIG" ] && pass \
  || fail "w109 W3-37 waves jq processes grow with edges: small=$W9_CALLS_SMALL big=$W9_CALLS_BIG"
[ "$W9_CALLS_BIG" -le 3 ] && pass || fail "w109 W3-37 waves starts $W9_CALLS_BIG jq processes (want <= 3)"

# one copy of the ready-set rule: epic-lib.sh holds it once (negative control:
# a planted file with three copies must be seen as three)
W9_READY_PLANT=$(mktemp "$W9_ROOT/ready-plant.XXXXXX")
for W9_I in 1 2 3; do printf '%s\n' '| select(.status == "pending")' >>"$W9_READY_PLANT"; done
[ "$(grep -c 'select(.status == "pending")' "$W9_READY_PLANT")" -eq 3 ] \
  && pass || fail "w109 W3-37 negative control: planted copies not counted"
[ "$(grep -c 'select(.status == "pending")' "$LIB")" -eq 1 ] \
  && pass || fail "w109 W3-37 epic-lib.sh must hold one ready-set definition, found $(grep -c 'select(.status == "pending")' "$LIB")"

# --- T4 / W3-37: more check-cycle coverage (thin wrapper over dag-lib)
# w9cyc <want-rc> <json>
w9cyc() {
  local want="$1" json="$2" f
  f=$(mktemp "$W9_ROOT/cyc.XXXXXX")
  printf '%s\n' "$json" >"$f"
  w9 "$want" check-cycle "$f"
}
w9cyc 1 '[{"task_id":"A","depends_on":["A"]}]'
w9cyc 1 '[{"task_id":"A","depends_on":["B"]},{"task_id":"B","depends_on":["C"]},{"task_id":"C","depends_on":["A"]}]'
printf '%s' "$OUT" | grep -qi cycle && pass || fail "w109 W3-37 3-cycle message ($OUT)"
w9cyc 0 '[{"task_id":"A","depends_on":[]},{"task_id":"B","depends_on":["A"]},{"task_id":"C","depends_on":["A"]},{"task_id":"D","depends_on":["B","C"]}]'
w9cyc 0 '[{"task_id":"A","depends_on":["NOT-A-NODE"]}]'
w9cyc 0 '[]'
w9cyc 2 'not json'
w9 2 check-cycle "$W9_ROOT/no-such-file.json"
w9 64 check-cycle
set +e
OUT=$(cd "$W9_ROOT" && EPIC_ROOT="$W9_ROOT" EPIC_DAG_LIB="$W9_ROOT/no-such-dag-lib.sh" bash "$LIB" check-cycle "$W9_ROOT/no-such-file.json" 2>&1)
RC=$?
[ "$RC" -eq 1 ] && pass || fail "w109 W3-37 missing dag-lib must exit 1 (rc=$RC out=$OUT)"

# --- T4 / W3-37: SKILL Step 0.4 passes the tool's own exit code through.
# The fence runs against a stub plugin root whose epic-lib.sh answers `exists`
# with 0 and `resolve-resume-flags` with the rc in STUB_RC.
W9_FIX="$W9_ROOT/fix04"
mkdir -p "$W9_FIX/skills/epic"
cp "$HERE/../plugin-dir.sh" "$W9_FIX/skills/plugin-dir.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$W9_FIX/skills/epic/parse-flags.sh"
cat >"$W9_FIX/skills/epic/epic-lib.sh" <<'STUB_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  exists) exit 0 ;;
  resolve-resume-flags) echo "stub: resolve failed" >&2; exit "${STUB_RC:-0}" ;;
  *) exit 64 ;;
esac
STUB_EOF
chmod +x "$W9_FIX/skills/epic/epic-lib.sh" "$W9_FIX/skills/epic/parse-flags.sh"
W9_F04=$(fence_nth "$W9_SKILL" "## Step 0.4" 1)
if [ -z "$W9_F04" ]; then
  fail "w109 W3-37 Step 0.4 fence not found"
else
  W9_F04_RUN="$W9_FIX/run-04.sh"
  printf '%s\n' "$W9_F04" | sed -e 's|<EPIC-ID>|W9-04|g' >"$W9_F04_RUN"
  for W9_RC in 64 1 2 7; do
    set +e
    OUT=$(cd "$W9_ROOT" && CLAUDE_PLUGIN_ROOT="$W9_FIX" PDH="$W9_FIX" STUB_RC="$W9_RC" bash "$W9_F04_RUN" --worktree 2>&1)
    RC=$?
    [ "$RC" -eq "$W9_RC" ] && pass || fail "w109 W3-37 Step 0.4 fence: resolve rc $W9_RC must exit $W9_RC, got $RC ($OUT)"
  done
fi

# --- T4 / CDT-404: sync-apply pulls status forward only
# w9sync <epic> <child-json-array>; sets OUT (report JSON)
w9sync() {
  local f
  f=$(mktemp "$W9_ROOT/verdicts.XXXXXX")
  printf '{"children":%s}\n' "$2" >"$f"
  w9 0 sync-apply "$1" --verdicts "$f"
}
# w9status <epic> <child-id> -> local status
w9status() { jq -r --arg id "$2" '.children[] | select(.id==$id) | .status' "$W9_ROOT/.claude/epics/$1/state.json"; }
w9 0 init SY --title sync --mode orchestrate
for W9_I in 1 2 3 4 5 6; do w9child SY "SY-C$W9_I" '[]'; done
w9 0 set-status SY SY-C2 in_progress
w9 0 set-status SY SY-C3 in_progress
w9 0 set-status SY SY-C4 blocked
w9 0 set-status SY SY-C5 blocked
w9 0 set-status SY SY-C6 completed
# backward: in_progress -> pending, blocked -> pending: skipped, status kept
w9sync SY '[{"id":"SY-C2","status":"pending"},{"id":"SY-C4","status":"pending"}]'
printf '%s' "$OUT" | jq -e '[.skipped[] | select(.action=="no_backward_status")] | length == 2' >/dev/null \
  && pass || fail "w109 CDT-404 backward moves must be skipped as no_backward_status ($OUT)"
printf '%s' "$OUT" | jq -e '.applied_count==0' >/dev/null && pass || fail "w109 CDT-404 nothing applied ($OUT)"
[ "$(w9status SY SY-C2)" = "in_progress" ] && pass || fail "w109 CDT-404 C2 must stay in_progress, got $(w9status SY SY-C2)"
[ "$(w9status SY SY-C4)" = "blocked" ] && pass || fail "w109 CDT-404 C4 must stay blocked, got $(w9status SY SY-C4)"
# completed is still never downgraded (its own action name)
w9sync SY '[{"id":"SY-C6","status":"pending"},{"id":"SY-C6","status":"in_progress"}]'
printf '%s' "$OUT" | jq -e '[.skipped[] | select(.action=="no_downgrade_completed")] | length == 2' >/dev/null \
  && pass || fail "w109 CDT-404 completed downgrade action ($OUT)"
# forward and lateral moves apply: pending->in_progress, in_progress->completed,
# in_progress->blocked, blocked->in_progress
w9sync SY '[{"id":"SY-C1","status":"in_progress"},{"id":"SY-C2","status":"completed"},{"id":"SY-C3","status":"blocked"},{"id":"SY-C5","status":"in_progress"}]'
printf '%s' "$OUT" | jq -e '.applied_count==4' >/dev/null && pass || fail "w109 CDT-404 forward/lateral moves apply ($OUT)"
[ "$(w9status SY SY-C1)" = "in_progress" ] && [ "$(w9status SY SY-C2)" = "completed" ] \
  && [ "$(w9status SY SY-C3)" = "blocked" ] && [ "$(w9status SY SY-C5)" = "in_progress" ] \
  && pass || fail "w109 CDT-404 forward/lateral end states"

# --- T4 / CDT-322: SKILL defines the /epic decision map. reroute-epic never
# loops back into /epic and never passes A.5 silently; B.3 states the nested-epic
# rule. Predicates run on the real SKILL and on planted old text.
# _w9_map_ok <A.5-text> <B.3-text>
_w9_map_ok() {
  if printf '%s\n%s\n' "$1" "$2" | grep -q 'shared C4 Decision→action map'; then return 1; fi
  # A.5: more than 8 children -> soft warn card line, continue; otherwise halt; never a silent proceed
  printf '%s\n' "$1" | grep -q 'reroute-epic' || return 1
  printf '%s\n' "$1" | grep -qF 'scope-confirm reroute-epic (soft warn)' || return 1
  printf '%s\n' "$1" | grep -qi 'more than 8 children' || return 1
  printf '%s\n' "$1" | grep -qi 'treat as `halt`' || return 1
  if printf '%s\n' "$1" | grep -qi 'treat as `proceed`'; then return 1; fi
  # B.3: halt + --redecompose, and an explicit nested-epic rule
  printf '%s\n' "$2" | grep -q 'reroute-epic' || return 1
  printf '%s\n' "$2" | grep -qi 'treat as `halt`' || return 1
  printf '%s\n' "$2" | grep -q -- '--redecompose' || return 1
  printf '%s\n' "$2" | grep -qi 'nested epic' || return 1
  printf '%s\n' "$2" | grep -qi 'not allowed' || return 1
  if printf '%s\n%s\n' "$1" "$2" | grep -qE 'hand (that child )?to `/epic`'; then return 1; fi
  return 0
}
W9_OLD_A5='- any other decision follows the shared C4 Decision→action map (e.g. `reroute-epic` → same one-line message, then hand to `/epic` decompose).'
W9_OLD_B3='- any other decision follows the shared C4 Decision→action map (e.g. `reroute-epic` → same one-line message, then hand that child to `/epic` decompose per M11 self-reroute).'
if _w9_map_ok "$W9_OLD_A5" "$W9_OLD_B3"; then fail "w109 CDT-322 negative control: old text accepted"; else pass; fi
W9_A5=$(md_section "$W9_SKILL" "### A.5")
W9_B3=$(md_section "$W9_SKILL" "### B.3")
# the first WP 1-09 wording passed A.5 silently: it must be rejected too
W9_SILENT_A5='- `reroute-epic` (BC5 complexity overflow) → treat as `proceed`. `/epic` decompose is itself the reroute target. Continue to **A.6**.
- any other value → treat as `halt`.'
if _w9_map_ok "$W9_SILENT_A5" "$W9_B3"; then fail "w109 CDT-322 negative control: silent-proceed A.5 accepted"; else pass; fi
if _w9_map_ok "$W9_A5" "$W9_B3"; then pass
else fail "w109 CDT-322 SKILL A.5/B.3: A.5 reroute-epic = soft warn when more than 8 children, else halt (never a silent proceed); B.3 = halt + --redecompose + a nested-epic rule; no shared map, no hand back to /epic"; fi
if grep -q 'shared C4 Decision→action map' "$W9_SKILL"; then fail "w109 CDT-322 SKILL still cites the undefined shared C4 map"; else pass; fi

# _w9_spec_ok <file>: the spec text carries the soft-warn rule and the nested-epic rule
_w9_spec_ok() {
  grep -qi 'soft warn' "$1" || return 1
  grep -qi 'nested epic' "$1" || return 1
  return 0
}
W9_OLD_SPEC=$(mktemp "$W9_ROOT/old-spec.XXXXXX")
printf '%s\n' 'A.5 runs reroute-epic as proceed. B.3 runs it as halt.' >"$W9_OLD_SPEC"
if _w9_spec_ok "$W9_OLD_SPEC"; then fail "w109 CDT-322 negative control: old spec text accepted"; else pass; fi
if _w9_spec_ok "$HERE/../../specs/core/SPEC-025-epic-umbrella-decomposition.md"; then pass; else fail "w109 CDT-322 SPEC-025 must state the A.5 soft warn and the B.3 nested-epic rule"; fi
if _w9_spec_ok "$HERE/../../specs/core/SPEC-033-autopilot-policy.md"; then pass; else fail "w109 CDT-322 SPEC-033 must state the A.5 soft warn and the B.3 nested-epic rule"; fi

# --- TL fix 4: resolve-resume-flags takes the bump from the autopilot parser
# (skills/autopilot/parse-flags.sh owns the token grammar; epic-lib never copies it).
# A stub parser that reports bump=minor proves the delegation: no --autopilot
# argument is needed to trip the rule.
W9_AP_STUB="$W9_ROOT/ap-stub.sh"
# w9ap <want-rc> <stub-json-or-rc> <args...>
w9ap() {
  local want="$1" stub="$2"; shift 2
  case "$stub" in
    rc:*) printf '#!/usr/bin/env bash\necho "stub: parser failed" >&2\nexit %s\n' "${stub#rc:}" >"$W9_AP_STUB" ;;
    warn:*)
      printf '%s\n' "${stub#warn:}" >"$W9_AP_STUB.json"
      printf '#!/usr/bin/env bash\necho "stub: a warning on stderr" >&2\ncat "%s.json"\n' "$W9_AP_STUB" >"$W9_AP_STUB"
      ;;
    *)
      printf '%s\n' "$stub" >"$W9_AP_STUB.json"
      printf '#!/usr/bin/env bash\ncat "%s.json"\n' "$W9_AP_STUB" >"$W9_AP_STUB"
      ;;
  esac
  set +e
  OUT=$(cd "$W9_ROOT" && EPIC_ROOT="$W9_ROOT" EPIC_AUTOPILOT_PARSE_FLAGS="$W9_AP_STUB" bash "$LIB" "$@" 2>&1)
  RC=$?
  if [ "$RC" -eq "$want" ]; then pass
  else fail "w109 TL4 exit $RC != $want for stub=$stub: $*"; echo "  out: $OUT" | head -c 400; echo
  fi
}
w9ap 64 '{"enabled":true,"bump":"minor","source":"flag"}' resolve-resume-flags W34-NULL -- W34-NULL
w9ap 64 '{"enabled":true,"bump":"major","source":"flag"}' resolve-resume-flags W34-WT -- W34-WT
w9ap 0 '{"enabled":true,"bump":"master","source":"flag"}' resolve-resume-flags W34-NULL -- W34-NULL
w9ap 0 '{"enabled":true,"bump":null,"source":"flag"}' resolve-resume-flags W34-NULL -- W34-NULL
w9ap 0 '{"enabled":true,"bump":"minor","source":"flag"}' resolve-resume-flags W34-SEAL -- W34-SEAL
w9ap 64 rc:64 resolve-resume-flags W34-NULL -- W34-NULL --autopilot=patch
# parser output that is not JSON must fail closed (exit non-zero), never "no bump"
w9ap 1 'this is not json' resolve-resume-flags W34-NULL -- W34-NULL
w9ap 1 '' resolve-resume-flags W34-NULL -- W34-NULL
# stderr noise from the parser is not part of its JSON: a valid bump still trips the rule
w9ap 64 'warn:{"enabled":true,"bump":"minor","source":"flag"}' resolve-resume-flags W34-NULL -- W34-NULL
# no copy of the token grammar in epic-lib.sh (planted negative control)
_w9_no_grammar_copy() { if grep -q -- '--autopilot=patch|--autopilot=minor|--autopilot=major' "$1"; then return 1; fi; return 0; }
W9_GRAM=$(mktemp "$W9_ROOT/gram.XXXXXX")
printf '%s\n' '      --autopilot=patch|--autopilot=minor|--autopilot=major)' >"$W9_GRAM"
if _w9_no_grammar_copy "$W9_GRAM"; then fail "w109 TL4 negative control: grammar copy not detected"; else pass; fi
if _w9_no_grammar_copy "$LIB"; then pass; else fail "w109 TL4 epic-lib.sh still copies the --autopilot token grammar"; fi

rm -rf "$W9_ROOT"

# ---- CDT-388 / CDT-424 / CDT-281 prose --------------------------------------
DOCS_EPIC_388="$HERE/../../docs/commands/epic.md"
CMD_388="$HERE/../../commands/epic.md"
# argument-hint flags must appear in the docs flags page
for flag in --worktree --release --autopilot --no-context-discipline --redecompose --dry-run; do
  if grep -q -- "$flag" "$DOCS_EPIC_388"; then pass
  else fail "cdt388 docs/commands/epic.md missing $flag"
  fi
done
if grep -q 'Mid-epic forbid (release=end)' "$DOCS_EPIC_388"; then
  fail "cdt388 docs heading still uses rejected token end"
else
  pass "cdt388 docs heading does not say release=end"
fi
if grep -q 'each`/`end`' "$DOCS_EPIC_388"; then
  pass "cdt388 rejected end token still documented as illegal"
else
  fail "cdt388 docs dropped the rejected end token"
fi
if grep -q -- '--not-a-real-epic-flag' "$DOCS_EPIC_388"; then
  fail "cdt388 negative: planted flag matched docs"
else
  pass "cdt388 negative: planted flag is absent"
fi
# descriptions (frontmatter only) name the flags argument-hint already has
cmd_desc=$(awk '/^description:/{p=1} /^argument-hint:/{exit} /^---$/ && p && NR>1{exit} p{print}' "$CMD_388")
if printf '%s\n' "$cmd_desc" | grep -q -- '--autopilot' \
  && printf '%s\n' "$cmd_desc" | grep -q -- '--no-context-discipline'; then
  pass "cdt388 commands/epic.md description names autopilot and no-context-discipline"
else
  fail "cdt388 commands/epic.md description missing a flag"
fi
skill_desc=$(awk 'BEGIN{p=0} /^description:/{p=1} p{print} /^---$/ && p && NR>1{exit}' "$SKILL_BODY")
if printf '%s\n' "$skill_desc" | grep -q -- '--autopilot' \
  && printf '%s\n' "$skill_desc" | grep -q -- '--no-context-discipline'; then
  pass "cdt388 epic SKILL description names autopilot and no-context-discipline"
else
  fail "cdt388 epic SKILL description missing a flag"
fi
if grep -F 'unblock` \| `sync`' "$SKILL_BODY" >/dev/null; then
  pass "cdt388 --worktree illegal list includes sync"
else
  fail "cdt388 --worktree illegal list omits sync"
fi

# CDT-281: one resolver block; "$@" fences say to substitute argv; B.7 fences
# are not indented inside the list.
n_resolve=$(grep -c 'Bash stdout = model string' "$SKILL_BODY" || true)
if [ "$n_resolve" -eq 1 ]; then
  pass "cdt281 model resolver prose appears once"
else
  fail "cdt281 model resolver prose count=$n_resolve (want 1)"
fi
if grep -q 'Substitute the real `/epic` invocation arguments' "$SKILL_BODY" \
  && grep -q '"$@"' "$SKILL_BODY"; then
  pass "cdt281 fences still use \$@ and tell the reader to substitute argv"
else
  fail "cdt281 missing argv-substitute note or the \$@ placeholder"
fi
if awk '
  /^### B\.7 / { sect=1 }
  /^## Mode C / { sect=0 }
  sect && /^   ```bash$/ { bad=1 }
  END { exit bad ? 0 : 1 }
' "$SKILL_BODY"; then
  fail "cdt281 B.7 still has an indented bash fence"
else
  pass "cdt281 B.7 bash fences are not list-indented"
fi
# negative control: an indented fence must trip the same awk
PLANT_MD=$(mktemp "${TMPDIR:-/tmp}/cdt281-plant.XXXXXX")
keep_tmp "$PLANT_MD"
printf '%s\n' '### B.7 plant' '   ```bash' 'echo hi' '   ```' '## Mode C' >"$PLANT_MD"
if awk '
  /^### B\.7 / { sect=1 }
  /^## Mode C / { sect=0 }
  sect && /^   ```bash$/ { bad=1 }
  END { exit bad ? 0 : 1 }
' "$PLANT_MD"; then
  pass "cdt281 negative: planted indented B.7 fence is detected"
else
  fail "cdt281 negative: planted indented fence was not detected"
fi

if grep -F -q 'disk side effects except the audit card' "$SKILL_BODY" \
  && grep -F -q 'On **decline**: exit, **zero** disk side effects' "$SKILL_BODY"; then
  pass "cdt424 A.5 halt allows the audit card; human decline stays zero writes"
else
  fail "cdt424 A.5 side-effect wording"
fi

# CDT-424: this shell must not have errexit on, and the sweeper removes a
# tracked dir that is not TMPROOT.
case $- in
  *e*) fail "cdt424 test shell has errexit on" ;;
  *) pass "cdt424 test shell stayed without errexit" ;;
esac
CDT424_PROBE=$(mktemp -d "${TMPDIR:-/tmp}/epic-cdt424.XXXXXX")
(
  TMP_DIRS=("$CDT424_PROBE")
  sweep_tracked
)
if [ -d "$CDT424_PROBE" ]; then
  fail "cdt424 sweep_tracked left $CDT424_PROBE"
else
  pass "cdt424 sweep_tracked removes a tracked dir other than TMPROOT"
fi

# =============================================================================
# cdt287 — epic-lib doctor (CDT-287 [05 E10] tool prerequisites)
# =============================================================================
run_in 0 doctor
echo "$OUT" | awk -F'\t' '$1=="bash.version" && $2=="PASS"' | grep -q . \
  && pass || fail "cdt287 doctor bash.version PASS row missing"
echo "$OUT" | awk -F'\t' '$1=="jq" && $2=="PASS"' | grep -q . \
  && pass || fail "cdt287 doctor jq PASS row missing"
echo "$OUT" | awk -F'\t' '$1=="lock.support"' | grep -q . \
  && pass || fail "cdt287 doctor lock.support row missing"
echo "$OUT" | grep -q '^summary	' \
  && pass || fail "cdt287 doctor summary row missing"
bash "$LIB" 2>&1 | grep -q 'tool-prerequisite report' \
  && pass || fail "cdt287 usage lists the doctor subcommand"

# Soft deps degrade to WARN under a stripped PATH (jq kept: hard requirement);
# flock absent but portable.sh present → lock fallback PASS.
CDT287_STRIP=$(mktemp -d "${TMPDIR:-/tmp}/epic-cdt287-strip.XXXXXX")
keep_tmp "$CDT287_STRIP"
for b in bash jq git awk sed dirname cat; do
  p=$(command -v "$b" 2>/dev/null || true)
  if [ -n "$p" ] && [ ! -e "$CDT287_STRIP/$b" ]; then
    ln -s "$p" "$CDT287_STRIP/$b" 2>/dev/null || true
  fi
done
RC=0
OUT=$(set -e; PATH="$CDT287_STRIP" EPIC_ROOT="$TMPROOT" bash "$LIB" doctor 2>&1) || RC=$?
if [ "$RC" -eq 1 ] \
  && echo "$OUT" | awk -F'\t' '$1=="sqlite3" && $2=="WARN"' | grep -q . \
  && echo "$OUT" | awk -F'\t' '$1=="python3" && $2=="WARN"' | grep -q . \
  && echo "$OUT" | awk -F'\t' '$1=="lock.support" && $2=="PASS"' | grep -q .; then
  pass "cdt287 stripped PATH → sqlite3/python3 WARN, lock fallback PASS, exit 1"
else
  fail "cdt287 stripped PATH rc=$RC out=$OUT"
fi

# Negative control A: without the doctor dispatch the subcommand is unknown
# (exit 64) — every assertion above fails on the old code. The copy keeps the
# epic/ + lib/ shape so $HERE/../lib/portable.sh still resolves.
CDT287_D=$(mktemp -d "${TMPDIR:-/tmp}/epic-cdt287-neg.XXXXXX")
keep_tmp "$CDT287_D"
mkdir -p "$CDT287_D/epic" "$CDT287_D/lib"
cp "$HERE/../lib/portable.sh" "$CDT287_D/lib/portable.sh"
grep -vF 'cmd_doctor "$@" ;;' "$LIB" > "$CDT287_D/epic/epic-lib.sh"
RC=0
OUT=$(set -e; EPIC_ROOT="$TMPROOT" bash "$CDT287_D/epic/epic-lib.sh" doctor 2>&1) || RC=$?
if [ "$RC" -eq 64 ] && echo "$OUT" | grep -q 'unknown subcommand'; then
  pass "cdt287 negative: doctor dispatch removed → 64 (old-code control)"
else
  fail "cdt287 negative A rc=$RC out=$OUT"
fi

# Negative control B: a raised bash floor trips FAIL + exit 2 (the version
# comparison is live, not a constant PASS row).
sed 's/EPIC_DOC_BASH_MAJ:-3/EPIC_DOC_BASH_MAJ:-99/' "$LIB" > "$CDT287_D/epic/epic-lib.sh"
RC=0
OUT=$(set -e; EPIC_ROOT="$TMPROOT" bash "$CDT287_D/epic/epic-lib.sh" doctor 2>&1) || RC=$?
if [ "$RC" -eq 2 ] \
  && echo "$OUT" | awk -F'\t' '$1=="bash.version" && $2=="FAIL"' | grep -q .; then
  pass "cdt287 negative: raised bash floor → FAIL exit 2 (comparison live)"
else
  fail "cdt287 negative B rc=$RC out=$OUT"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
