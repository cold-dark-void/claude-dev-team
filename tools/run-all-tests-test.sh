#!/usr/bin/env bash
# SPEC-030 R17: tools/run-all-tests.sh bite-test.
#
# Builds disposable mktemp git trees (git init -q + git add; no commit --
# ls-files --cached reads the index, which avoids identity/signing config on
# CI) and drives the runner against them via --root. Never touches or
# recurses into the real repo tree except to statically read
# .github/workflows/smoke.yml and tools/test-quarantine.txt (Live case,
# read-only, no runner invocation -- that run takes ~2 minutes and would
# blow the <30s budget for this suite).
#
# All temp material lives under mktemp -d / $TMPDIR and is removed on EXIT.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
RUNNER="$REPO_ROOT/tools/run-all-tests.sh"

PASS=0
FAIL=0
OUT=""
ERR=""
RC=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/run-all-tests-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); }
fail() { # fail <message>
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
  [ -n "$OUT" ] && echo "$OUT" | head -20
}

run_runner() { # run_runner <args...> -- captures OUT + RC (stdout+stderr
               # merged). Prefix with VAR=value to set env for this call
               # only, e.g. `RUN_ALL_TESTS_TIMEOUT=2 run_runner --root "$R4"`.
  OUT=$(bash "$RUNNER" "$@" 2>&1)
  RC=$?
}

run_runner_split() { # run_runner_split <args...> -- like run_runner, but
                      # captures stdout (OUT) and stderr (ERR) separately,
                      # so a test can prove a line went to the right stream.
  local errfile
  errfile="$TMP/run_runner_split.stderr.$$"
  OUT=$(bash "$RUNNER" "$@" 2>"$errfile")
  RC=$?
  ERR=$(cat "$errfile" 2>/dev/null)
  rm -f "$errfile"
}

expect_exit() { # expect_exit <want> <label>
  if [ "$RC" -eq "$1" ]; then pass; else
    fail "$2: got exit $RC, want $1"
  fi
}

expect_out() { # expect_out <substring> <label>
  if echo "$OUT" | grep -qF "$1"; then pass; else
    fail "$2: output missing '$1'"
  fi
}

expect_out_line() { # expect_out_line <exact line> <label> -- unlike
                     # expect_out, matches a whole line only (a plain
                     # substring check on e.g. "test.sh" is vacuous: it also
                     # matches "new-test.sh").
  if echo "$OUT" | grep -qFx -- "$1"; then pass; else
    fail "$2: output missing exact line '$1'"
  fi
}

expect_not_out() { # expect_not_out <substring> <label>
  if echo "$OUT" | grep -qF "$1"; then
    fail "$2: output unexpectedly contains '$1'"
  else pass; fi
}

expect_no_process() { # expect_no_process <marker> <label> -- retries pgrep
                       # for up to ~2s to absorb the sub-millisecond
                       # scheduling race between the direct child (bash,
                       # blocked in `wait`) exiting on TERM and the
                       # grandchild -- in the same process group, signalled
                       # at the same instant -- finishing its own exit; a
                       # REAL leftover would still be there well past this
                       # window. Matched by its unique marker (own argv[0],
                       # via `exec -a`), never a bare `sleep 987` -- that
                       # would also match an unrelated host process of the
                       # same name.
  local _try
  for _try in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f -- "$1" >/dev/null 2>&1 || { pass; return; }
    sleep 0.2
  done
  fail "$2 (marker $1 still running)"
}

new_root() { # new_root -- prints a fresh mktemp git tree (init, no commit)
  local d
  d=$(mktemp -d "$TMP/root.XXXXXX")
  git init -q "$d"
  printf '%s\n' "$d"
}

ok_suite()    { printf '#!/usr/bin/env bash\nexit 0\n'; }
fail_suite()  { printf '#!/usr/bin/env bash\nexit 1\n'; }
skip_suite()  { printf '#!/usr/bin/env bash\nexit 77\n'; }
dirty_suite() { printf '#!/usr/bin/env bash\necho dirty > dirty-file.txt\nexit 0\n'; }

gen_sleep_suite() { # gen_sleep_suite <token> [ignore-term] -- suite whose
                     # grandchild sleeps under a unique marker (its argv[0],
                     # via `exec -a`) so a test can `pgrep -f` this exact
                     # invocation without matching an unrelated host `sleep`
                     # process. With the optional second arg "ignore-term",
                     # the grandchild also ignores TERM: the suite leader
                     # itself does not, so it dies on TERM and `wait "$pid"`
                     # in the runner returns before the grandchild does --
                     # only the watchdog's later KILL (R7) can end it.
  local token="$1" prefix=""
  [ "${2:-}" = "ignore-term" ] && prefix='trap "" TERM; '
  cat <<SUITE
#!/usr/bin/env bash
( ${prefix}exec -a '$token' sleep 987 ) &
wait
SUITE
}

# ---------------------------------------------------------------------------
# Case 1: discovery -- new *-test.sh (tracked and untracked-not-ignored),
# test.sh, test-*.sh are found; fixtures/, .worktrees/, node_modules/ and a
# non-matching name are not; sorted bytewise order.
# ---------------------------------------------------------------------------
R1=$(new_root)
ok_suite > "$R1/test.sh"
ok_suite > "$R1/test-foo.sh"
git -C "$R1" add test.sh test-foo.sh
ok_suite > "$R1/new-test.sh"          # untracked-not-ignored -- never `git add`ed
ok_suite > "$R1/mytest.sh"            # close but non-matching (no leading '-')
git -C "$R1" add mytest.sh

mkdir -p "$R1/fixtures" "$R1/.worktrees" "$R1/node_modules"
ok_suite > "$R1/fixtures/sub-test.sh"
ok_suite > "$R1/.worktrees/foo-test.sh"
ok_suite > "$R1/node_modules/bar-test.sh"
git -C "$R1" add -A

run_runner --root "$R1" --list
expect_exit 0 "case1 --list"
expect_out_line "new-test.sh" "case1 discovers untracked *-test.sh"
expect_out_line "test.sh" "case1 discovers test.sh"
expect_out_line "test-foo.sh" "case1 discovers test-*.sh"
expect_not_out "mytest.sh" "case1 excludes non-matching name"
expect_not_out "fixtures/sub-test.sh" "case1 excludes fixtures segment"
expect_not_out ".worktrees/foo-test.sh" "case1 excludes .worktrees segment"
expect_not_out "node_modules/bar-test.sh" "case1 excludes node_modules segment"

WANT_ORDER=$'new-test.sh\ntest-foo.sh\ntest.sh'
GOT_ORDER=$(printf '%s' "$OUT")
if [ "$GOT_ORDER" = "$WANT_ORDER" ]; then pass; else
  fail "case1 sorted order: got [$GOT_ORDER] want [$WANT_ORDER]"
fi

# ---------------------------------------------------------------------------
# Case 2: PASS-only run of the discovered set -> exit 0, all three counted.
# ---------------------------------------------------------------------------
run_runner --root "$R1"
expect_exit 0 "case2 PASS-only run"
expect_out "PASS new-test.sh" "case2 runs the untracked suite"
expect_out "PASS test.sh" "case2 runs test.sh"
expect_out "PASS test-foo.sh" "case2 runs test-foo.sh"
expect_out "3 suites: 3 passed, 0 failed, 0 timed out, 0 quarantined, 0 skipped" "case2 summary"

# ---------------------------------------------------------------------------
# Case 3: FAIL -> exit 1.
# ---------------------------------------------------------------------------
R3=$(new_root)
fail_suite > "$R3/test.sh"
git -C "$R3" add -A
run_runner --root "$R3"
expect_exit 1 "case3 FAIL"
expect_out "FAIL test.sh (exit 1)" "case3 FAIL line names exit code"
expect_out "1 suites: 0 passed, 1 failed, 0 timed out, 0 quarantined, 0 skipped" "case3 summary"

# ---------------------------------------------------------------------------
# Case 4: TIMEOUT with a small RUN_ALL_TESTS_TIMEOUT -> exit 1, fast, no
# surviving grandchild process.
# ---------------------------------------------------------------------------
R4=$(new_root)
TOK4="rat_case4_$$_marker"
gen_sleep_suite "$TOK4" > "$R4/test.sh"
git -C "$R4" add -A

START=$(date +%s)
RUN_ALL_TESTS_TIMEOUT=2 run_runner --root "$R4"
END=$(date +%s)
ELAPSED=$((END - START))

expect_exit 1 "case4 TIMEOUT"
expect_out "TIMEOUT test.sh (timed out after 2s)" "case4 TIMEOUT line"
if [ "$ELAPSED" -lt 15 ]; then pass; else
  fail "case4 elapsed: ${ELAPSED}s, want < 15s"
fi
expect_no_process "$TOK4" "case4 grandchild process survived"

# ---------------------------------------------------------------------------
# Case 4b: TIMEOUT with a TERM-ignoring grandchild -> the runner's watchdog
# MUST still escalate to KILL after the grace period (R7). The suite leader
# itself dies on TERM and returns from `wait "$pid"` before the
# TERM-ignoring grandchild does; the runner must not tear the watchdog down
# before its own KILL fires.
# ---------------------------------------------------------------------------
R4B=$(new_root)
TOK4B="rat_case4b_$$_marker"
gen_sleep_suite "$TOK4B" ignore-term > "$R4B/test.sh"
git -C "$R4B" add -A

RUN_ALL_TESTS_TIMEOUT=2 run_runner --root "$R4B"
expect_exit 1 "case4b TIMEOUT with TERM-ignoring grandchild"
expect_out "TIMEOUT test.sh (timed out after 2s)" "case4b TIMEOUT line"
expect_no_process "$TOK4B" "case4b TERM-ignoring grandchild survived"

# ---------------------------------------------------------------------------
# Case 5: exit 77 -> SKIP, exit 0.
# ---------------------------------------------------------------------------
R5=$(new_root)
skip_suite > "$R5/test.sh"
git -C "$R5" add -A
run_runner --root "$R5"
expect_exit 0 "case5 SKIP"
expect_out "SKIP test.sh" "case5 SKIP line"
expect_out "1 suites: 0 passed, 0 failed, 0 timed out, 0 quarantined, 1 skipped" "case5 summary"

# ---------------------------------------------------------------------------
# Case 6: quarantined FAIL -> QUARANTINED, does not affect exit code (0).
# ---------------------------------------------------------------------------
R6=$(new_root)
fail_suite > "$R6/test.sh"
git -C "$R6" add -A
mkdir -p "$R6/tools"
printf 'test.sh known-red: fixture reason\n' > "$R6/tools/test-quarantine.txt"
run_runner --root "$R6"
expect_exit 0 "case6 quarantined FAIL does not fail the run"
expect_out "QUARANTINED test.sh" "case6 QUARANTINED line"
expect_out "1 suites: 0 passed, 0 failed, 0 timed out, 1 quarantined, 0 skipped" "case6 summary"

# ---------------------------------------------------------------------------
# Case 7: quarantined PASS -> stderr warn:, still PASS, exit 0. Streams are
# captured separately to prove warn: actually goes to stderr, not just that
# the (merged) output happens to contain it.
# ---------------------------------------------------------------------------
R7=$(new_root)
ok_suite > "$R7/test.sh"
git -C "$R7" add -A
mkdir -p "$R7/tools"
printf 'test.sh stale entry: suite now passes\n' > "$R7/tools/test-quarantine.txt"
run_runner_split --root "$R7"
expect_exit 0 "case7 quarantined PASS"
expect_out "PASS test.sh" "case7 still reports PASS"
if echo "$ERR" | grep -qF "warn:"; then pass; else
  fail "case7 warn: line did not appear on stderr"
fi
if echo "$ERR" | grep -qF "is quarantined"; then pass; else
  fail "case7 warn: stderr line missing the stale-entry reason"
fi
if echo "$OUT" | grep -qF "warn:"; then
  fail "case7 warn: leaked onto stdout"
else pass; fi

# ---------------------------------------------------------------------------
# Case 8: R9 -- a suite that dirties the working tree -> FAIL, even though
# its own exit code is 0.
# ---------------------------------------------------------------------------
R8=$(new_root)
dirty_suite > "$R8/test.sh"
git -C "$R8" add -A
run_runner --root "$R8"
expect_exit 1 "case8 dirtying suite fails the run"
expect_out "FAIL test.sh (modified the working tree)" "case8 FAIL names the R9 reason"

# ---------------------------------------------------------------------------
# Case 9: each R11 malformed-quarantine shape -> exit 64, pre-run (no suite
# runs -- no PASS/FAIL/SKIP line for the one real suite in the tree).
# ---------------------------------------------------------------------------
# 9a. missing reason.
R9A=$(new_root)
ok_suite > "$R9A/test.sh"
git -C "$R9A" add -A
mkdir -p "$R9A/tools"
printf 'test.sh\n' > "$R9A/tools/test-quarantine.txt"
run_runner --root "$R9A"
expect_exit 64 "case9a missing reason"
expect_out "missing reason" "case9a names the defect"
expect_not_out "PASS test.sh" "case9a fails before running any suite"

# 9b. path not a discovered suite.
R9B=$(new_root)
ok_suite > "$R9B/test.sh"
git -C "$R9B" add -A
mkdir -p "$R9B/tools"
printf 'test-nope.sh some reason\n' > "$R9B/tools/test-quarantine.txt"
run_runner --root "$R9B"
expect_exit 64 "case9b stale entry"
expect_out "not a discovered suite" "case9b names the defect"

# 9c. path listed twice.
R9C=$(new_root)
ok_suite > "$R9C/test.sh"
git -C "$R9C" add -A
mkdir -p "$R9C/tools"
{ printf 'test.sh reason one\n'; printf 'test.sh reason two\n'; } > "$R9C/tools/test-quarantine.txt"
run_runner --root "$R9C"
expect_exit 64 "case9c duplicate entry"
expect_out "listed twice" "case9c names the defect"

# 9d. blank lines and # comments are ignored, not malformed (R11); the
# surviving real entry still quarantines its suite.
R9D=$(new_root)
fail_suite > "$R9D/test.sh"
git -C "$R9D" add -A
mkdir -p "$R9D/tools"
printf '# leading comment\n\ntest.sh fixture reason\n\n# trailing comment\n' > "$R9D/tools/test-quarantine.txt"
run_runner --root "$R9D"
expect_exit 0 "case9d blank lines and comments are ignored"
expect_out "QUARANTINED test.sh" "case9d real entry still quarantines"

# ---------------------------------------------------------------------------
# Case 10: each R3 usage-error shape -> exit 64.
# ---------------------------------------------------------------------------
R10=$(new_root)
ok_suite > "$R10/test.sh"
git -C "$R10" add -A

run_runner --bogus
expect_exit 64 "case10a unknown argument"

run_runner --root=
expect_exit 64 "case10g --root= (empty value)"

run_runner --root
expect_exit 64 "case10h --root (no value)"

run_runner --root "$TMP/does-not-exist-dir"
expect_exit 64 "case10b --root not a directory"

NOTGIT="$TMP/not-a-git-tree"
mkdir -p "$NOTGIT"
run_runner --root "$NOTGIT"
expect_exit 64 "case10c --root not a git work tree"

RUN_ALL_TESTS_TIMEOUT=abc run_runner --root "$R10"
expect_exit 64 "case10d non-numeric RUN_ALL_TESTS_TIMEOUT"

RUN_ALL_TESTS_TIMEOUT=0 run_runner --root "$R10"
expect_exit 64 "case10e zero RUN_ALL_TESTS_TIMEOUT"

RUN_ALL_TESTS_TIMEOUT=-5 run_runner --root "$R10"
expect_exit 64 "case10f negative RUN_ALL_TESTS_TIMEOUT"

# ---------------------------------------------------------------------------
# Case 11 (live, read-only): no `run: bash <path>` job in
# .github/workflows/smoke.yml names a tools/test-quarantine.txt entry. Static
# parse only -- never invokes the runner against the real repo (a full run
# there takes ~2 minutes, far over this suite's <30s budget).
# ---------------------------------------------------------------------------
SMOKE_YML="$REPO_ROOT/.github/workflows/smoke.yml"
QFILE="$REPO_ROOT/tools/test-quarantine.txt"

if [ -f "$SMOKE_YML" ]; then
  RUN_PATHS=$(grep -oE 'run: bash [^[:space:]]+' "$SMOKE_YML" | awk '{print $3}')
  Q_PATHS=""
  if [ -f "$QFILE" ]; then
    Q_PATHS=$(grep -v '^[[:space:]]*#' "$QFILE" | awk 'NF{print $1}')
  fi
  BAD=""
  while IFS= read -r rp; do
    [ -z "$rp" ] && continue
    if printf '%s\n' "$Q_PATHS" | grep -Fxq -- "$rp"; then
      BAD="$BAD $rp"
    fi
  done <<< "$RUN_PATHS"
  if [ -z "$BAD" ]; then pass; else
    fail "case11 live: smoke.yml runs a quarantined suite:$BAD"
  fi
else
  fail "case11 live: $SMOKE_YML not found"
fi

# ---------------------------------------------------------------------------
echo "---"
echo "run-all-tests bite-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
