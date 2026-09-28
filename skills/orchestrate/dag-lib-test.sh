#!/usr/bin/env bash
# skills/orchestrate/dag-lib-test.sh — bite-tests for dag-lib.sh (SPEC-017
# § dag-lib.sh contract, WP 1-07). Covers AC G, H, I, J, K, L.
#
# Machine-check: bash skills/orchestrate/dag-lib-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DAG="$HERE/dag-lib.sh"
ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

[ -f "$DAG" ] || { echo "FATAL: dag-lib.sh not found at $DAG" >&2; exit 1; }
[ -x "$DAG" ] || chmod +x "$DAG"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

STDOUT_F="$HERMETIC_ROOT/stdout"
STDERR_F="$HERMETIC_ROOT/stderr"
RC=0
OUT=""
ERR=""

# run_dag <desc> <want_rc> <arg...> — runs dag-lib.sh with stdin closed,
# captures stdout/stderr separately into $OUT/$ERR, rc into $RC.
run_dag() {
  local desc="$1" want="$2"; shift 2
  RC=0
  bash "$DAG" "$@" >"$STDOUT_F" 2>"$STDERR_F" </dev/null || RC=$?
  OUT=$(cat "$STDOUT_F")
  ERR=$(cat "$STDERR_F")
  if [ "$RC" -eq "$want" ]; then pass
  else fail "$desc: rc=$RC want=$want stdout=[$OUT] stderr=[$ERR]"
  fi
}

# run_dag_stdin <desc> <want_rc> <stdin_file> <arg...> — like run_dag but
# feeds a real file on stdin instead of /dev/null.
run_dag_stdin() {
  local desc="$1" want="$2" stdin_file="$3"; shift 3
  RC=0
  bash "$DAG" "$@" >"$STDOUT_F" 2>"$STDERR_F" <"$stdin_file" || RC=$?
  OUT=$(cat "$STDOUT_F")
  ERR=$(cat "$STDERR_F")
  if [ "$RC" -eq "$want" ]; then pass
  else fail "$desc: rc=$RC want=$want stdout=[$OUT] stderr=[$ERR]"
  fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then pass
  else fail "$name: got=[$got] want=[$want]"
  fi
}

assert_match() {
  local name="$1" got="$2" pattern="$3"
  if printf '%s\n' "$got" | grep -qE -- "$pattern"; then pass
  else fail "$name: [$got] does not match /$pattern/"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass
  else fail "$name: [$needle] missing in [$haystack]"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    fail "$name: [$needle] unexpectedly present in [$haystack]"
  else
    pass
  fi
}

FIX="$HERMETIC_ROOT/fixtures"
mkdir -p "$FIX"

# =============================================================================
echo "== (G) usage / exit-code contract =="

run_dag "G1 no args" 64
run_dag "G2 unknown subcommand" 64 bogus
run_dag "G3 check-cycle 0 args" 64 check-cycle
run_dag "G4 check-cycle 2 args" 64 check-cycle a b
run_dag "G5 ready-set unknown flag" 64 ready-set --bogus
run_dag "G6 status-of 0 args" 64 status-of
run_dag "G7 status-of 2 args" 64 status-of a b

printf '%s' '[]' > "$FIX/g-missing-check.json"
run_dag "G8 check-cycle missing file" 2 check-cycle "$FIX/g-does-not-exist.json"

printf '%s' '{}' > "$FIX/g-obj.json"
run_dag "G9 check-cycle {} input" 2 check-cycle "$FIX/g-obj.json"

printf '%s' '[{"task_id":"A","depends_on":["C"]},{"task_id":"B","depends_on":["A"]},{"task_id":"C","depends_on":["B"]}]' \
  > "$FIX/g-3cycle.json"
run_dag "G10 check-cycle 3-cycle exits 1" 1 check-cycle "$FIX/g-3cycle.json"

# missing jq → 64. Resolve bash's absolute path first so an empty PATH
# still finds the interpreter itself (only jq must be unresolvable).
BASH_BIN=$(command -v bash)
EMPTY_DIR="$HERMETIC_ROOT/empty-path"
mkdir -p "$EMPTY_DIR"
RC=0
env PATH="$EMPTY_DIR" "$BASH_BIN" "$DAG" ready-set >"$STDOUT_F" 2>"$STDERR_F" </dev/null || RC=$?
if [ "$RC" -eq 64 ]; then pass
else fail "G11 missing jq: rc=$RC want=64 stderr=[$(cat "$STDERR_F")]"
fi

# =============================================================================
echo "== (H) check-cycle is one jq program; grep + behaviour cases =="

# Static check: no bash associative arrays, negative array index or mapfile.
GREP_COUNT=$(grep -cE 'declare -A|\[-1\]|mapfile' "$DAG")
assert_eq "H1 no forbidden bash constructs in dag-lib.sh" "$GREP_COUNT" "0"

# Planted negative control: confirm the grep pattern itself actually
# matches when the forbidden constructs are present (not vacuously 0).
printf 'declare -A FOO\nx=${a[-1]}\nmapfile -t y\n' > "$FIX/h-negative-control.txt"
NEG_COUNT=$(grep -cE 'declare -A|\[-1\]|mapfile' "$FIX/h-negative-control.txt")
if [ "$NEG_COUNT" -eq 3 ]; then pass
else fail "H2 negative control: grep matched $NEG_COUNT want 3"
fi

printf '%s' '[]' > "$FIX/h-empty.json"
run_dag "H3 empty array acyclic" 0 check-cycle "$FIX/h-empty.json"

printf '%s' '[{"task_id":"A","depends_on":[]},{"task_id":"B","depends_on":["A"]},{"task_id":"C","depends_on":["A"]},{"task_id":"D","depends_on":["B","C"]}]' \
  > "$FIX/h-diamond.json"
run_dag "H4 diamond acyclic" 0 check-cycle "$FIX/h-diamond.json"

printf '%s' '[{"task_id":"A","depends_on":["ZZZ-does-not-exist"]}]' > "$FIX/h-unknown-dep.json"
run_dag "H5 unknown dep is a root, acyclic" 0 check-cycle "$FIX/h-unknown-dep.json"

printf '%s' '[{"task_id":"A","depends_on":["A"]}]' > "$FIX/h-self.json"
run_dag "H6 self-loop is a cycle" 1 check-cycle "$FIX/h-self.json"
assert_match "H6 cycle line format" "$ERR" '^cycle: [^ ]+ -> [^ ]+$'
assert_contains "H6 both ids on cycle (from)" "$ERR" "A"

printf '%s' '[{"task_id":"A","depends_on":["B"]},{"task_id":"B","depends_on":["A"]}]' > "$FIX/h-2cycle.json"
run_dag "H7 2-cycle" 1 check-cycle "$FIX/h-2cycle.json"
assert_match "H7 cycle line format" "$ERR" '^cycle: [^ ]+ -> [^ ]+$'
assert_contains "H7 A on cycle" "$ERR" "A"
assert_contains "H7 B on cycle" "$ERR" "B"

printf '%s' '[{"task_id":"A","depends_on":["C"]},{"task_id":"B","depends_on":["A"]},{"task_id":"C","depends_on":["B"]}]' \
  > "$FIX/h-3cycle.json"
run_dag "H8 3-cycle" 1 check-cycle "$FIX/h-3cycle.json"
assert_match "H8 cycle line format" "$ERR" '^cycle: [^ ]+ -> [^ ]+$'
CY_FROM=$(printf '%s' "$ERR" | sed -nE 's/^cycle: ([^ ]+) -> ([^ ]+)$/\1/p')
CY_TO=$(printf '%s' "$ERR" | sed -nE 's/^cycle: ([^ ]+) -> ([^ ]+)$/\2/p')
if printf '%s\n' "A B C" | grep -qw -- "$CY_FROM"; then pass; else fail "H8 from-id [$CY_FROM] not in cycle set {A,B,C}"; fi
if printf '%s\n' "A B C" | grep -qw -- "$CY_TO"; then pass; else fail "H8 to-id [$CY_TO] not in cycle set {A,B,C}"; fi

run_dag_stdin "H9 - reads stdin (cycle)" 1 "$FIX/h-2cycle.json" check-cycle -
assert_match "H9 cycle line format" "$ERR" '^cycle: [^ ]+ -> [^ ]+$'

run_dag_stdin "H10 - reads stdin (acyclic)" 0 "$FIX/h-diamond.json" check-cycle -

# =============================================================================
echo "== (I) ready-set --issue scoping =="

REPO="$HERMETIC_ROOT/repo-i"
mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
TASKS="$REPO/.claude/tasks"
mkdir -p "$TASKS"

write_task() {
  # write_task <path> <task_id> <status> <deps-json>
  jq -n --arg tid "$2" --arg s "$3" --argjson deps "$4" \
    '{task_id:$tid, subject:"t", requires_council:false, depends_on:$deps, status:$s}' \
    > "$1"
}

write_task "$TASKS/T-1-1.json" "T-1-1" pending '[]'
write_task "$TASKS/T-1-2.json" "T-1-2" pending '[]'
write_task "$TASKS/T-2-1.json" "T-2-1" pending '[]'
write_task "$TASKS/T-1-C1-2.json" "T-1-C1-2" pending '[]'
write_task "$TASKS/T-1-ci-fixer.json" "T-1-ci-fixer" pending '[]'

RC=0
OUT=$(cd "$REPO" && bash "$DAG" ready-set --issue T-1 2>"$STDERR_F") || RC=$?
if [ "$RC" -eq 0 ]; then pass; else fail "I1 ready-set --issue T-1 rc=$RC"; fi
assert_contains "I2 T-1-1 ready" "$OUT" "T-1-1"
assert_contains "I3 T-1-2 ready" "$OUT" "T-1-2"
assert_not_contains "I4 T-2-1 excluded" "$OUT" "T-2-1"
assert_not_contains "I5 T-1-C1-2 excluded" "$OUT" "T-1-C1-2"
assert_not_contains "I6 T-1-ci-fixer excluded" "$OUT" "T-1-ci-fixer"

RC=0
OUT=$(cd "$REPO" && bash "$DAG" ready-set 2>"$STDERR_F") || RC=$?
if [ "$RC" -eq 0 ]; then pass; else fail "I7 ready-set no-flag rc=$RC"; fi
assert_contains "I8 T-1-1 present unscoped" "$OUT" "T-1-1"
assert_contains "I9 T-2-1 present unscoped" "$OUT" "T-2-1"
assert_contains "I10 T-1-C1-2 present unscoped" "$OUT" "T-1-C1-2"
assert_contains "I11 T-1-ci-fixer present unscoped" "$OUT" "T-1-ci-fixer"

RC=0
(cd "$REPO" && bash "$DAG" ready-set --issue 'a/b') >"$STDOUT_F" 2>"$STDERR_F" || RC=$?
if [ "$RC" -eq 64 ]; then pass; else fail "I12 bad --issue value rc=$RC want=64"; fi

RC=0
(cd "$REPO" && bash "$DAG" ready-set --issue) >"$STDOUT_F" 2>"$STDERR_F" || RC=$?
if [ "$RC" -eq 64 ]; then pass; else fail "I13 --issue missing value rc=$RC want=64"; fi

RC=0
(cd "$REPO" && bash "$DAG" ready-set --issue '') >"$STDOUT_F" 2>"$STDERR_F" || RC=$?
if [ "$RC" -eq 64 ]; then pass; else fail "I14 --issue empty value rc=$RC want=64"; fi

RC=0
(cd "$REPO" && bash "$DAG" ready-set --issue T-1 --issue T-2) >"$STDOUT_F" 2>"$STDERR_F" || RC=$?
if [ "$RC" -eq 64 ]; then pass; else fail "I15 --issue given twice rc=$RC want=64"; fi

# =============================================================================
echo "== (J) ready-set corrupt-tolerant single-process read =="

REPO_J="$HERMETIC_ROOT/repo-j"
mkdir -p "$REPO_J/.claude/tasks"
git init -q "$REPO_J"
git -C "$REPO_J" config user.email t@example.invalid
git -C "$REPO_J" config user.name t
git -C "$REPO_J" commit -q --allow-empty -m init
TASKS_J="$REPO_J/.claude/tasks"

printf 'this is not json at all' > "$TASKS_J/bad.json"
printf '%s' '[1,2,3]' > "$TASKS_J/arr.json"
printf '%s' '{"no_task_id":true}' > "$TASKS_J/noid.json"
write_task "$TASKS_J/Z-1.json" "Z-1" pending '[]'

RC=0
OUT=$(cd "$REPO_J" && bash "$DAG" ready-set 2>"$STDERR_F") || RC=$?
if [ "$RC" -eq 0 ]; then pass; else fail "J1 ready-set with bad file rc=$RC"; fi
assert_eq "J2 stdout is exactly the one ready task" "$OUT" "Z-1"
WARN_LINES=$(printf '%s\n' "$(cat "$STDERR_F")" | grep -c '^warning:')
assert_eq "J3 exactly one warning line" "$WARN_LINES" "1"
assert_contains "J4 warning names the bad file" "$(cat "$STDERR_F")" "bad.json"
assert_not_contains "J5 warning does not name the array file" "$(cat "$STDERR_F")" "arr.json"
assert_not_contains "J6 warning does not name the no-id file" "$(cat "$STDERR_F")" "noid.json"

# H1 fix: a doc whose depends_on is a string (not an array or null) must
# not crash the pass -- it is excluded, and every other valid task still
# gets its normal ready/warn treatment.
REPO_J2="$HERMETIC_ROOT/repo-j2"
mkdir -p "$REPO_J2/.claude/tasks"
git init -q "$REPO_J2"
git -C "$REPO_J2" config user.email t@example.invalid
git -C "$REPO_J2" config user.name t
git -C "$REPO_J2" commit -q --allow-empty -m init
TASKS_J2="$REPO_J2/.claude/tasks"
jq -n '{task_id:"J2-1", status:"pending", depends_on:"J2-1"}' > "$TASKS_J2/J2-1.json"
write_task "$TASKS_J2/J2-2.json" "J2-2" pending '[]'

RC=0
OUT=$(cd "$REPO_J2" && bash "$DAG" ready-set 2>"$STDERR_F") || RC=$?
if [ "$RC" -eq 0 ]; then pass; else fail "J7 ready-set with non-array depends_on rc=$RC"; fi
assert_eq "J8 stdout is exactly the valid ready task" "$OUT" "J2-2"

# H1 fix: a file that cannot be opened (permission denied) becomes a
# warning for that file only, and never drops the files after it.
REPO_J3="$HERMETIC_ROOT/repo-j3"
mkdir -p "$REPO_J3/.claude/tasks"
git init -q "$REPO_J3"
git -C "$REPO_J3" config user.email t@example.invalid
git -C "$REPO_J3" config user.name t
git -C "$REPO_J3" commit -q --allow-empty -m init
TASKS_J3="$REPO_J3/.claude/tasks"
write_task "$TASKS_J3/A-unreadable.json" "A-unreadable" pending '[]'
write_task "$TASKS_J3/Z-after.json" "Z-after" pending '[]'
chmod 000 "$TASKS_J3/A-unreadable.json"

RC=0
OUT=$(cd "$REPO_J3" && bash "$DAG" ready-set 2>"$STDERR_F") || RC=$?
chmod 644 "$TASKS_J3/A-unreadable.json"
if [ "$RC" -eq 0 ]; then pass; else fail "J9 ready-set with unreadable file rc=$RC"; fi
assert_contains "J10 later file still ready" "$OUT" "Z-after"
assert_contains "J11 warning names the unreadable file" "$(cat "$STDERR_F")" "A-unreadable.json"

# The completed set spans every readable file, so a dep completed under a
# different issue still frees an in-scope task.
REPO_J4="$HERMETIC_ROOT/repo-j4"
mkdir -p "$REPO_J4/.claude/tasks"
git init -q "$REPO_J4"
git -C "$REPO_J4" config user.email t@example.invalid
git -C "$REPO_J4" config user.name t
git -C "$REPO_J4" commit -q --allow-empty -m init
TASKS_J4="$REPO_J4/.claude/tasks"
write_task "$TASKS_J4/OTHER-9.json" "OTHER-9" completed '[]'
write_task "$TASKS_J4/J4-1.json" "J4-1" pending '["OTHER-9"]'

RC=0
OUT=$(cd "$REPO_J4" && bash "$DAG" ready-set --issue J4 2>"$STDERR_F") || RC=$?
if [ "$RC" -eq 0 ]; then pass; else fail "J12 ready-set cross-issue completed dep rc=$RC"; fi
assert_eq "J13 in-scope task ready via cross-issue completed dep" "$OUT" "J4-1"

# =============================================================================
echo "== (K) blocked-dep reporting stays off stdout =="

REPO_K="$HERMETIC_ROOT/repo-k"
mkdir -p "$REPO_K/.claude/tasks"
git init -q "$REPO_K"
git -C "$REPO_K" config user.email t@example.invalid
git -C "$REPO_K" config user.name t
git -C "$REPO_K" commit -q --allow-empty -m init
TASKS_K="$REPO_K/.claude/tasks"

write_task "$TASKS_K/K-dep.json" "K-dep" blocked '[]'
write_task "$TASKS_K/K-1.json" "K-1" pending '["K-dep"]'

RC=0
OUT=$(cd "$REPO_K" && bash "$DAG" ready-set 2>"$STDERR_F") || RC=$?
if [ "$RC" -eq 0 ]; then pass; else fail "K1 ready-set with blocked dep rc=$RC"; fi
assert_eq "K2 stdout empty (task not ready)" "$OUT" ""
assert_eq "K3 exact blocked-dep stderr line" "$(cat "$STDERR_F")" "blocked-dep: K-1 <- K-dep"

# =============================================================================
echo "== (L) status-of resolution =="

REPO_L="$HERMETIC_ROOT/repo-l"
mkdir -p "$REPO_L/.claude/tasks"
git init -q "$REPO_L"
git -C "$REPO_L" config user.email t@example.invalid
git -C "$REPO_L" config user.name t
git -C "$REPO_L" commit -q --allow-empty -m init
TASKS_L="$REPO_L/.claude/tasks"

write_task "$TASKS_L/L-exact.json" "L-exact" in_progress '[]'
write_task "$TASKS_L/PFX-7.json" "PFX-7" completed '[]'
write_task "$TASKS_L/A-9.json" "A-9" pending '[]'
write_task "$TASKS_L/B-9.json" "B-9" pending '[]'

for bad in '../x' 'a.b' 'a/b'; do
  RC=0
  (cd "$REPO_L" && bash "$DAG" status-of "$bad") >"$STDOUT_F" 2>"$STDERR_F" || RC=$?
  if [ "$RC" -eq 64 ]; then pass; else fail "L1 status-of '$bad' rc=$RC want=64"; fi
done

RC=0
OUT=$(cd "$REPO_L" && bash "$DAG" status-of L-exact) || RC=$?
[ "$RC" -eq 0 ] && pass || fail "L2 status-of exact rc=$RC"
assert_eq "L2 exact file status" "$OUT" "in_progress"

RC=0
OUT=$(cd "$REPO_L" && bash "$DAG" status-of 7) || RC=$?
[ "$RC" -eq 0 ] && pass || fail "L3 status-of bare 7 rc=$RC"
assert_eq "L3 one *-7.json match" "$OUT" "completed"

RC=0
(cd "$REPO_L" && bash "$DAG" status-of 9) >"$STDOUT_F" 2>"$STDERR_F" || RC=$?
if [ "$RC" -eq 2 ]; then pass; else fail "L4 status-of ambiguous 9 rc=$RC want=2"; fi
assert_contains "L4 names A-9" "$(cat "$STDERR_F")" "A-9.json"
assert_contains "L4 names B-9" "$(cat "$STDERR_F")" "B-9.json"

RC=0
OUT=$(cd "$REPO_L" && bash "$DAG" status-of no-such-id) || RC=$?
[ "$RC" -eq 0 ] && pass || fail "L5 status-of no match rc=$RC"
assert_eq "L5 no match prints pending" "$OUT" "pending"

# L1 fix: a corrupt or non-object matched file exits 2, not a raw jq code.
printf 'garbage' > "$TASKS_L/CORRUPT-1.json"
RC=0
(cd "$REPO_L" && bash "$DAG" status-of CORRUPT-1) >"$STDOUT_F" 2>"$STDERR_F" || RC=$?
if [ "$RC" -eq 2 ]; then pass; else fail "L6 status-of corrupt exact file rc=$RC want=2"; fi

printf '%s' '[1]' > "$TASKS_L/CORRUPT-2.json"
RC=0
(cd "$REPO_L" && bash "$DAG" status-of CORRUPT-2) >"$STDOUT_F" 2>"$STDERR_F" || RC=$?
if [ "$RC" -eq 2 ]; then pass; else fail "L7 status-of non-object exact file rc=$RC want=2"; fi

# =============================================================================
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
