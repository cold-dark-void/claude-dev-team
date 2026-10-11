#!/usr/bin/env bash
# SPEC-030 R17: tools/run-all-tests.sh bite-test. CDT-502 (R11/R12/R32):
# quarantine scope column and the --platform flag.
#
# Builds disposable mktemp git trees (git init -q + git add; no commit --
# ls-files --cached reads the index, which avoids identity/signing config on
# CI) and drives the runner against them via --root. Never touches or
# recurses into the real repo tree except to statically read
# .github/workflows/smoke.yml and tools/test-quarantine.txt (Live case,
# read-only, no runner invocation -- that run takes ~2 minutes and would
# blow the <30s budget for this suite). All temp material lives under
# mktemp -d / $TMPDIR and is removed on EXIT.
# CDT-534 Task 5 (Q6) — self-concurrency audit. Under --jobs 8 every suite
# temp path sits inside a per-worker clone nested in the runner scratch, so
# suites were fixed for hermetic-path hygiene (runner untouched). Fix classes
# — per-suite causes live in the suites' own headers:
#   ceiling at $HERMETIC_ROOT (now via hermetic_init): lib/git-safety-test.sh,
#     handoff/resolve-root-test.sh, release/test{,-bump-class,-ship-history,
#     -ship-steps,-step0}.sh, fence-exec/test-later-fences.sh; ceiling at $TMP
#     on one run: plugin-dir-test.sh, smoke/test.sh (root9), run-all-tests-test.sh
#     (the NOTGIT case must keep rejecting via ascent); ceiling on a negative
#     call: fix-ticket/test-ticket-guard.sh
#   (the wrap-ticket/smoke/blind-file-list patches were REVERTED in T11: T10
#   moved the per-suite HOME/TMPDIR outside the clone, so those patches were
#   dead weight; hermetic_init keeps its ceiling — tests/lib/test.sh asserts
#   it and it still guards a caller who points TMPDIR inside a repo)
#   fixture or harness at a .git-free temp root: init-orchestration/
#     escalation-gate-test.sh, check-traceability-test.sh; allow the runner's
#     .run-all-tests/ area: intercom/test.sh; match fence-exec/test.sh's form
#
# The two planted same-`/tmp`-lock collision cases below still prove per-worker
# TMPDIR isolation at `--jobs 2`.
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

# pass/fail/run_runner/expect_*/expect_no_process/new_root and the suite
# generators live in the shared R17 harness (write OUT/ERR/RC/PASS/FAIL here;
# read RUNNER/TMP).
HARNESS="$REPO_ROOT/tests/lib/run-all-tests-harness.sh"
. "$HARNESS"

# Case 1: discovery -- new *-test.sh (tracked and untracked-not-ignored),
# test.sh, test-*.sh are found; fixtures/, .worktrees/, node_modules/ and a
# non-matching name are not; sorted bytewise order.
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

# Case 2: PASS-only run of the discovered set -> exit 0, all three counted.
run_runner --root "$R1"
expect_exit 0 "case2 PASS-only run"
expect_out "PASS new-test.sh" "case2 runs the untracked suite"
expect_out "PASS test.sh" "case2 runs test.sh"
expect_out "PASS test-foo.sh" "case2 runs test-foo.sh"
expect_out "3 suites: 3 passed, 0 failed, 0 timed out, 0 quarantined, 0 skipped" "case2 summary"

# Case 3: FAIL -> exit 1.
R3=$(new_root)
fail_suite > "$R3/test.sh"
git -C "$R3" add -A
run_runner --root "$R3"
expect_exit 1 "case3 FAIL"
expect_out "FAIL test.sh (exit 1)" "case3 FAIL line names exit code"
expect_out "1 suites: 0 passed, 1 failed, 0 timed out, 0 quarantined, 0 skipped" "case3 summary"

# Case 4: TIMEOUT with a small RUN_ALL_TESTS_TIMEOUT -> exit 1, fast, no
# surviving grandchild process.
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

# Case 4b: TIMEOUT with a TERM-ignoring grandchild -> the runner's watchdog
# MUST still escalate to KILL after the grace period (R7). The suite leader
# itself dies on TERM and returns from `wait "$pid"` before the
# TERM-ignoring grandchild does; the runner must not tear the watchdog down
# before its own KILL fires.
R4B=$(new_root)
TOK4B="rat_case4b_$$_marker"
gen_sleep_suite "$TOK4B" ignore-term > "$R4B/test.sh"
git -C "$R4B" add -A

RUN_ALL_TESTS_TIMEOUT=2 run_runner --root "$R4B"
expect_exit 1 "case4b TIMEOUT with TERM-ignoring grandchild"
expect_out "TIMEOUT test.sh (timed out after 2s)" "case4b TIMEOUT line"
expect_no_process "$TOK4B" "case4b TERM-ignoring grandchild survived"

# Case 5: exit 77 -> SKIP, exit 0.
R5=$(new_root)
skip_suite > "$R5/test.sh"
git -C "$R5" add -A
run_runner --root "$R5"
expect_exit 0 "case5 SKIP"
expect_out "SKIP test.sh" "case5 SKIP line"
expect_out "1 suites: 0 passed, 0 failed, 0 timed out, 0 quarantined, 1 skipped" "case5 summary"

# Case 6: quarantined FAIL -> QUARANTINED, does not affect exit code (0).
R6=$(new_root)
fail_suite > "$R6/test.sh"
git -C "$R6" add -A
mkdir -p "$R6/tools"
printf 'test.sh all known-red: fixture reason\n' > "$R6/tools/test-quarantine.txt"
run_runner --root "$R6"
expect_exit 0 "case6 quarantined FAIL does not fail the run"
expect_out "QUARANTINED test.sh" "case6 QUARANTINED line"
expect_out "1 suites: 0 passed, 0 failed, 0 timed out, 1 quarantined, 0 skipped" "case6 summary"

# Case 7: quarantined PASS -> stderr warn:, still PASS, exit 0. Streams are
# captured separately to prove warn: actually goes to stderr, not just that
# the (merged) output happens to contain it.
R7=$(new_root)
ok_suite > "$R7/test.sh"
git -C "$R7" add -A
mkdir -p "$R7/tools"
printf 'test.sh all stale entry: suite now passes\n' > "$R7/tools/test-quarantine.txt"
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

# Case 8: R9 -- a suite that dirties the working tree -> FAIL, even though
# its own exit code is 0.
R8=$(new_root)
dirty_suite > "$R8/test.sh"
git -C "$R8" add -A
run_runner --root "$R8"
expect_exit 1 "case8 dirtying suite fails the run"
expect_out "FAIL test.sh (modified the working tree)" "case8 FAIL names the R9 reason"

# Case 9: each R11 malformed-quarantine shape -> exit 64, pre-run (no suite
# runs -- no PASS/FAIL/SKIP line for the one real suite in the tree).
# 9a. missing reason.
R9A=$(new_root)
ok_suite > "$R9A/test.sh"
git -C "$R9A" add -A
mkdir -p "$R9A/tools"
printf 'test.sh all\n' > "$R9A/tools/test-quarantine.txt"
run_runner --root "$R9A"
expect_exit 64 "case9a missing reason"
expect_out "missing reason" "case9a names the defect"
expect_out "test-quarantine.txt:1" "case9a names file and line"
expect_not_out "PASS test.sh" "case9a fails before running any suite"

# 9a2. missing scope: a path-only line has no scope field.
R9A2=$(new_root)
ok_suite > "$R9A2/test.sh"
git -C "$R9A2" add -A
mkdir -p "$R9A2/tools"
printf 'test.sh\n' > "$R9A2/tools/test-quarantine.txt"
run_runner --root "$R9A2"
expect_exit 64 "case9a2 missing scope"
expect_out "missing scope" "case9a2 names the defect"
expect_out "test-quarantine.txt:1" "case9a2 names file and line"
expect_not_out "PASS test.sh" "case9a2 fails before running any suite"

# 9b. path not a discovered suite.
R9B=$(new_root)
ok_suite > "$R9B/test.sh"
git -C "$R9B" add -A
mkdir -p "$R9B/tools"
printf 'test-nope.sh all some reason\n' > "$R9B/tools/test-quarantine.txt"
run_runner --root "$R9B"
expect_exit 64 "case9b stale entry"
expect_out "not a discovered suite" "case9b names the defect"

# 9c. path listed twice.
R9C=$(new_root)
ok_suite > "$R9C/test.sh"
git -C "$R9C" add -A
mkdir -p "$R9C/tools"
{ printf 'test.sh all reason one\n'; printf 'test.sh all reason two\n'; } > "$R9C/tools/test-quarantine.txt"
run_runner --root "$R9C"
expect_exit 64 "case9c duplicate entry"
expect_out "listed twice" "case9c names the defect"

# 9d. blank lines and # comments are ignored, not malformed (R11); the
# surviving real entry still quarantines its suite.
R9D=$(new_root)
fail_suite > "$R9D/test.sh"
git -C "$R9D" add -A
mkdir -p "$R9D/tools"
printf '# leading comment\n\ntest.sh all fixture reason\n\n# trailing comment\n' > "$R9D/tools/test-quarantine.txt"
run_runner --root "$R9D"
expect_exit 0 "case9d blank lines and comments are ignored"
expect_out "QUARANTINED test.sh" "case9d real entry still quarantines"

# Case 10: each R3 usage-error shape -> exit 64.
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
# CDT-534 Q6: under the parallel runner $TMP nests inside the worker repo, so
# the runner's `git -C $ROOT rev-parse --show-toplevel` validation would ascend
# out of NOTGIT, accept it, and scan the whole worker tree; ceiling the ascent
# to keep the not-a-work-tree rejection (usage 64).
GIT_CEILING_DIRECTORIES="$TMP" run_runner --root "$NOTGIT"
expect_exit 64 "case10c --root not a git work tree"

RUN_ALL_TESTS_TIMEOUT=abc run_runner --root "$R10"
expect_exit 64 "case10d non-numeric RUN_ALL_TESTS_TIMEOUT"

RUN_ALL_TESTS_TIMEOUT=0 run_runner --root "$R10"
expect_exit 64 "case10e zero RUN_ALL_TESTS_TIMEOUT"

RUN_ALL_TESTS_TIMEOUT=-5 run_runner --root "$R10"
expect_exit 64 "case10f negative RUN_ALL_TESTS_TIMEOUT"

# Case 11 (live, read-only): no `run: bash <path>` job in
# .github/workflows/smoke.yml names a tools/test-quarantine.txt entry. Static
# parse only -- never invokes the runner against the real repo (a full run
# there takes ~2 minutes, far over this suite's <30s budget).
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

# Case 12: --portable drops GNU/bash4 code and keeps a comment-only mention.
R12=$(new_root)
ok_suite > "$R12/test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'mapfile -t xs < /dev/null' 'exit 1' > "$R12/gnu-test.sh"
printf '%s\n' '#!/usr/bin/env bash' '# mapfile is named only in this comment' 'exit 0' > "$R12/note-test.sh"
git -C "$R12" add -A

run_runner --root "$R12" --list
expect_exit 0 "case12 full list"
expect_out_line "gnu-test.sh" "case12 full list includes the mapfile suite"
expect_out_line "test.sh" "case12 full list includes the clean suite"

run_runner_split --root "$R12" --portable --list
expect_exit 0 "case12 --portable --list"
expect_out_line "test.sh" "case12 portable keeps the clean suite"
expect_out_line "note-test.sh" "case12 portable keeps a comment mention"
expect_not_out "gnu-test.sh" "case12 portable drops the mapfile suite"
if printf '%s\n' "$ERR" | grep -q 'warn: portable: skipped 1 non-portable suite'; then
  pass
else
  fail "case12 portable warn names the skip count"
fi

R12B=$(new_root)
fail_suite > "$R12B/test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sha256sum /dev/null' 'exit 0' > "$R12B/hash-test.sh"
git -C "$R12B" add -A
run_runner --root "$R12B" --portable
expect_exit 1 "case12 portable still fails a portable suite"
expect_out "FAIL test.sh" "case12 portable reports the portable failure"
expect_not_out "hash-test.sh" "case12 portable does not run sha256sum"

# Planted control for the timeout hazard: the same scanner drops a suite whose
# meaningful line calls timeout (CDT-271 — stock macOS has no timeout(1)).
R12C=$(new_root)
ok_suite > "$R12C/test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'timeout 5 true' 'exit 0' > "$R12C/timeout-test.sh"
git -C "$R12C" add -A
run_runner_split --root "$R12C" --portable --list
expect_exit 0 "case12 --portable --list (timeout)"
expect_out_line "test.sh" "case12 portable keeps the clean suite (timeout)"
expect_not_out "timeout-test.sh" "case12 portable drops the timeout suite"

# Case 13 (CDT-502 R32): --platform accepts exactly linux|macos; anything
# else -- bad value, missing value, trailing flag, empty --platform= -- exits
# 64 with a usage line to stderr BEFORE any suite runs, including --list.
R13=$(new_root)
ok_suite > "$R13/test.sh"
git -C "$R13" add -A

run_runner --root "$R13" --platform bogus
expect_exit 64 "case13a --platform bogus"
expect_not_out "PASS" "case13a zero suites executed"
expect_not_out "suites:" "case13a no summary printed"

run_runner --root "$R13" --platform bogus --list
expect_exit 64 "case13b --platform bogus --list"
expect_not_out "test.sh" "case13b zero suites listed"

run_runner --root "$R13" --platform
expect_exit 64 "case13c trailing --platform does not hang, exits 64"

run_runner --root "$R13" --platform=
expect_exit 64 "case13d --platform= (empty value)"

run_runner_split --root "$R13" --platform bogus
expect_exit 64 "case13e --platform bogus (split)"
if echo "$ERR" | grep -qF "Usage:"; then pass; else
  fail "case13e usage line did not appear on stderr"
fi

# Case 14 (CDT-502 R32/AC1): --platform linux behaves identically to no flag.
# A macos-scoped entry on a default/linux lane is ignored, so both runs show
# the red suite as a real FAIL and the byte streams match.
R14=$(new_root)
ok_suite > "$R14/test.sh"
fail_suite > "$R14/zred-test.sh"
git -C "$R14" add -A
mkdir -p "$R14/tools"
printf 'zred-test.sh macos red on the macos lane\n' > "$R14/tools/test-quarantine.txt"

run_runner --root "$R14"
NOFLAG_RC=$RC
NOFLAG_OUT=$OUT
run_runner --root "$R14" --platform linux
expect_exit 1 "case14 --platform linux exits 1"
if [ "$RC" -eq "$NOFLAG_RC" ] && [ "$OUT" = "$NOFLAG_OUT" ]; then pass; else
  fail "case14 --platform linux output differs from no-flag run"
fi
expect_out "FAIL zred-test.sh (exit 1)" "case14 macos entry ignored: real FAIL"
expect_not_out "QUARANTINED" "case14 macos entry ignored: no QUARANTINED"

# Case 15 (CDT-502 R17/AC3/AC4): a macos-scoped entry with --platform macos
# reports a red suite QUARANTINED, exit 0.
R15=$(new_root)
fail_suite > "$R15/test.sh"
git -C "$R15" add -A
mkdir -p "$R15/tools"
printf 'test.sh macos red on the macos lane\n' > "$R15/tools/test-quarantine.txt"
run_runner --root "$R15" --platform macos
expect_exit 0 "case15 macos lane quarantined red"
expect_out "QUARANTINED test.sh" "case15 QUARANTINED line"
expect_out "1 suites: 0 passed, 0 failed, 0 timed out, 1 quarantined, 0 skipped" "case15 summary"

# Case 16 (CDT-502 R17/AC4): a macos-scoped entry with --platform macos on a
# passing suite reports PASS plus a stderr warn: (stale entry).
R16=$(new_root)
ok_suite > "$R16/test.sh"
git -C "$R16" add -A
mkdir -p "$R16/tools"
printf 'test.sh macos stale macos entry\n' > "$R16/tools/test-quarantine.txt"
run_runner_split --root "$R16" --platform macos
expect_exit 0 "case16 macos lane quarantined PASS"
expect_out "PASS test.sh" "case16 still reports PASS"
if echo "$ERR" | grep -qF "warn:"; then pass; else
  fail "case16 warn: line did not appear on stderr"
fi
if echo "$OUT" | grep -qF "warn:"; then
  fail "case16 warn: leaked onto stdout"
else pass; fi

# Case 17 (CDT-502 R17/AC3): the same macos-scoped entry WITHOUT --platform
# macos does not quarantine: a red suite exits 1 with no warn:.
R17=$(new_root)
fail_suite > "$R17/test.sh"
git -C "$R17" add -A
mkdir -p "$R17/tools"
printf 'test.sh macos red on the macos lane\n' > "$R17/tools/test-quarantine.txt"
run_runner_split --root "$R17"
expect_exit 1 "case17 default lane red suite fails"
expect_out "FAIL test.sh (exit 1)" "case17 FAIL line"
expect_not_out "QUARANTINED" "case17 no QUARANTINED on default lane"
if echo "$ERR" | grep -qF "warn:"; then
  fail "case17 warn: printed on the default lane"
else pass; fi

# Case 18 (CDT-502 R17/AC3): a passing suite with a macos-scoped entry on the
# default lane prints no warn:.
R18=$(new_root)
ok_suite > "$R18/test.sh"
git -C "$R18" add -A
mkdir -p "$R18/tools"
printf 'test.sh macos stale macos entry\n' > "$R18/tools/test-quarantine.txt"
run_runner_split --root "$R18"
expect_exit 0 "case18 default lane passing suite"
expect_out "PASS test.sh" "case18 PASS line"
if echo "$ERR" | grep -qF "warn:"; then
  fail "case18 warn: printed on the default lane"
else pass; fi

# Case 19 (CDT-502 R12/AC3): an all-scoped entry quarantines on every lane.
R19=$(new_root)
fail_suite > "$R19/test.sh"
git -C "$R19" add -A
mkdir -p "$R19/tools"
printf 'test.sh all red everywhere\n' > "$R19/tools/test-quarantine.txt"
run_runner --root "$R19" --platform macos
expect_exit 0 "case19 all scope on macos lane"
expect_out "QUARANTINED test.sh" "case19 QUARANTINED on macos lane"
run_runner --root "$R19" --platform linux
expect_exit 0 "case19 all scope on linux lane"
expect_out "QUARANTINED test.sh" "case19 QUARANTINED on linux lane"

# Case 20 (CDT-502 R12/AC4): exit 77 stays SKIP and is never QUARANTINED,
# even on a lane where the entry applies.
R20=$(new_root)
skip_suite > "$R20/test.sh"
git -C "$R20" add -A
mkdir -p "$R20/tools"
printf 'test.sh all skipped suites stay skip\n' > "$R20/tools/test-quarantine.txt"
run_runner --root "$R20" --platform macos
expect_exit 0 "case20 SKIP under quarantine"
expect_out "SKIP test.sh" "case20 SKIP line"
expect_not_out "QUARANTINED" "case20 exit 77 never QUARANTINED"
expect_out "1 suites: 0 passed, 0 failed, 0 timed out, 0 quarantined, 1 skipped" "case20 summary"

# Case 21 (CDT-502 AC2): a quarantine entry for an R4-discovered suite that
# --portable excludes validates OK and never applies (the suite is not run).
R21=$(new_root)
ok_suite > "$R21/test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'mapfile -t xs < /dev/null' 'exit 1' > "$R21/gnu-test.sh"
git -C "$R21" add -A
mkdir -p "$R21/tools"
printf 'gnu-test.sh macos red on the macos lane\n' > "$R21/tools/test-quarantine.txt"
run_runner --root "$R21" --portable --platform macos
expect_exit 0 "case21 portable-excluded entry validates OK"
expect_out "PASS test.sh" "case21 the portable suite still runs"
expect_not_out "gnu-test.sh" "case21 excluded suite is not run"
expect_not_out "not a discovered suite" "case21 entry validated against the full list"
expect_not_out "QUARANTINED" "case21 excluded suite can never apply"

# Case 22 (CDT-502 R11/AC2): an unknown scope exits 64 naming file:line --
# both a three-field line and an old-format two-field line (whose middle
# token lands in the scope position).
R22=$(new_root)
ok_suite > "$R22/test.sh"
git -C "$R22" add -A
mkdir -p "$R22/tools"
printf 'test.sh everywhere reason\n' > "$R22/tools/test-quarantine.txt"
run_runner --root "$R22"
expect_exit 64 "case22a unknown scope"
expect_out "scope must be all or macos" "case22a names the defect"
expect_out "test-quarantine.txt:1" "case22a names file and line"
expect_not_out "PASS test.sh" "case22a fails before running any suite"

R22B=$(new_root)
ok_suite > "$R22B/test.sh"
git -C "$R22B" add -A
mkdir -p "$R22B/tools"
printf 'test.sh old-format reason\n' > "$R22B/tools/test-quarantine.txt"
run_runner --root "$R22B"
expect_exit 64 "case22b two-field line has no valid scope"
expect_out "scope must be all or macos" "case22b names the defect"
expect_out "test-quarantine.txt:1" "case22b names file and line"

# Case 23 (CDT-534 R36): --jobs usage-error shapes -> exit 64; the valid
# parse shapes still reach --list with exit 0. Full R36-R38 matrix is
# case 24+ (Task 6); this covers the parse bites only.
run_runner --root "$R10" --jobs
expect_exit 64 "case23a trailing --jobs"
expect_out "requires an argument" "case23a names the defect"

run_runner --root "$R10" --jobs=
expect_exit 64 "case23b --jobs= (empty value)"

run_runner --root "$R10" --jobs 0
expect_exit 64 "case23c --jobs 0"

run_runner --root "$R10" --jobs 2fast
expect_exit 64 "case23d --jobs junk"

RUN_ALL_TESTS_JOBS=junk run_runner --root "$R10" --list
expect_exit 64 "case23e junk RUN_ALL_TESTS_JOBS"

RUN_ALL_TESTS_JOBS=0 run_runner --root "$R10" --list
expect_exit 64 "case23f zero RUN_ALL_TESTS_JOBS"

# Flag wins over a bad env: --jobs 1 is a valid parse even with junk env.
RUN_ALL_TESTS_JOBS=junk run_runner --root "$R10" --jobs 1 --list
expect_exit 0 "case23g flag wins over env"

run_runner --root "$R10" --jobs 1 --list
expect_exit 0 "case23h --jobs 1 reaches --list"

run_runner --root "$R10" --jobs=auto --list
expect_exit 0 "case23i --jobs=auto reaches --list"

# Case 24 (CDT-534 R37/AC8): the release-state overlay. A --root planted with
# HEAD = merge-base, index+worktree = tip and one untracked ?? must be
# reproduced in the worker clone: same porcelain shape, git show HEAD: vs
# git show :<path> vs worktree bytes all match the source, the untracked
# file stays ?? (not staged), git-common-dir inside the worker is the
# worker's own .git, and the scratch tree is gone on exit.
R24=$(new_root)
printf 'merge-base\n' > "$R24/tracked.txt"
git -C "$R24" add tracked.txt
git -C "$R24" -c user.name=T -c user.email=t@t commit -qm merge-base
printf 'tip\n' > "$R24/tracked.txt"
git -C "$R24" add tracked.txt
printf 'untracked\n' > "$R24/untracked.txt"

EVID24="$TMP/worker-evidence-24.txt"
cat > "$R24/worker-probe-test.sh" <<EOF
#!/usr/bin/env bash
{
  echo "PWD=\$PWD"
  echo "GCD=\$(git rev-parse --git-common-dir)"
  echo "PORCELAIN_BEGIN"
  git status --porcelain --untracked-files=all
  echo "PORCELAIN_END"
  echo "HEAD_TRACKED=\$(git show HEAD:tracked.txt)"
  echo "INDEX_TRACKED=\$(git show :tracked.txt)"
  echo "WT_TRACKED=\$(cat tracked.txt)"
  echo "OTHERS=\$(git ls-files --others --exclude-standard)"
} > "$EVID24"
exit 0
EOF
git -C "$R24" add worker-probe-test.sh

ROOT_PORCELAIN_24=$(git -C "$R24" status --porcelain -uall)

run_runner --root "$R24" --jobs 2
expect_exit 0 "case24 probe passes in the worker"
expect_out "PASS worker-probe-test.sh" "case24 probe runs"

if [ -f "$EVID24" ]; then pass; else
  fail "case24 no worker evidence written"
fi
EV_PWD=$(sed -n 's/^PWD=//p' "$EVID24")
EV_GCD=$(sed -n 's/^GCD=//p' "$EVID24")
EV_PORCELAIN=$(sed -n '/^PORCELAIN_BEGIN$/,/^PORCELAIN_END$/p' "$EVID24" | sed '1d;$d')
EV_HEAD=$(sed -n 's/^HEAD_TRACKED=//p' "$EVID24")
EV_INDEX=$(sed -n 's/^INDEX_TRACKED=//p' "$EVID24")
EV_WT=$(sed -n 's/^WT_TRACKED=//p' "$EVID24")
EV_OTHERS=$(sed -n 's/^OTHERS=//p' "$EVID24")

case "$EV_PWD" in
  */run-all-tests.*/worker.*) pass ;;
  *) fail "case24 suite cwd is not a worker scratch: '$EV_PWD'" ;;
esac
if [ "$EV_GCD" = ".git" ]; then pass; else
  fail "case24 worker git-common-dir: got '$EV_GCD', want .git"
fi
if [ "$EV_PORCELAIN" = "$ROOT_PORCELAIN_24" ]; then pass; else
  fail "case24 worker porcelain differs from --root: got [$EV_PORCELAIN] want [$ROOT_PORCELAIN_24]"
fi
if [ "$EV_HEAD" = "merge-base" ]; then pass; else
  fail "case24 git show HEAD:tracked.txt: got '$EV_HEAD', want merge-base"
fi
if [ "$EV_INDEX" = "tip" ]; then pass; else
  fail "case24 git show :tracked.txt: got '$EV_INDEX', want tip"
fi
if [ "$EV_WT" = "tip" ]; then pass; else
  fail "case24 worktree bytes: got '$EV_WT', want tip"
fi
if [ "$EV_OTHERS" = "untracked.txt" ]; then pass; else
  fail "case24 untracked-not-ignored: got '$EV_OTHERS', want untracked.txt"
fi
if echo "$EV_PORCELAIN" | grep -q '^?? untracked.txt$'; then pass; else
  fail "case24 untracked.txt is not ?? in the worker"
fi

AFTER_PORCELAIN_24=$(git -C "$R24" status --porcelain -uall)
if [ "$AFTER_PORCELAIN_24" = "$ROOT_PORCELAIN_24" ]; then pass; else
  fail "case24 --root porcelain changed"
fi
if ls "$R24/.git"/run-all-tests.* >/dev/null 2>&1; then
  fail "case24 scratch tree survived the run"
else pass; fi

# Case 25 (CDT-534 R37): worker isolation and per-suite restore. Two dirtying
# suites plus one probe: each dirty suite FAILs with "modified the working
# tree" inside its own scratch, --root porcelain is unchanged, and the probe
# suite -- which lands in a worker an earlier dirty suite already used --
# observes the seed state, proving the restore ran.
R25=$(new_root)
dirty_suite > "$R25/a-dirty-one-test.sh"
dirty_suite > "$R25/b-dirty-two-test.sh"
EVID25="$TMP/worker-evidence-25.txt"
cat > "$R25/z-probe-test.sh" <<EOF
#!/usr/bin/env bash
{
  echo "PORCELAIN_BEGIN"
  git status --porcelain --untracked-files=all
  echo "PORCELAIN_END"
} > "$EVID25"
exit 0
EOF
git -C "$R25" add a-dirty-one-test.sh b-dirty-two-test.sh z-probe-test.sh

ROOT_PORCELAIN_25=$(git -C "$R25" status --porcelain -uall)

run_runner --root "$R25" --jobs 2
expect_exit 1 "case25 run fails on the dirty suites"
expect_out "FAIL a-dirty-one-test.sh (modified the working tree)" "case25 dirty suite 1 fails on R9"
expect_out "FAIL b-dirty-two-test.sh (modified the working tree)" "case25 dirty suite 2 fails on R9"
expect_out "PASS z-probe-test.sh" "case25 probe suite passes"

AFTER_PORCELAIN_25=$(git -C "$R25" status --porcelain -uall)
if [ "$AFTER_PORCELAIN_25" = "$ROOT_PORCELAIN_25" ]; then pass; else
  fail "case25 --root porcelain changed"
fi

if [ -f "$EVID25" ]; then pass; else
  fail "case25 no probe evidence written"
fi
EV_PORCELAIN_25=$(sed -n '/^PORCELAIN_BEGIN$/,/^PORCELAIN_END$/p' "$EVID25" | sed '1d;$d')
if [ "$EV_PORCELAIN_25" = "$ROOT_PORCELAIN_25" ]; then pass; else
  fail "case25 probe saw a non-seed worker state: [$EV_PORCELAIN_25]"
fi
if echo "$EV_PORCELAIN_25" | grep -q 'dirty-file'; then
  fail "case25 worker was not restored (dirty-file.txt visible to the probe)"
else pass; fi

# Case 26 (CDT-534 R36/R37): --jobs 1 takes the identity path -- output is
# byte-identical to the no-flag run (status words, FAIL tail, exit code),
# and no scratch tree is created: a probe suite running at jobs=1 checks
# --root/.git from inside the run.
R26=$(new_root)
printf '#!/usr/bin/env bash\necho "boom stdout"\necho "boom stderr" >&2\nexit 3\n' > "$R26/a-fail-test.sh"
EVID26="$TMP/scratch-evidence-26.txt"
cat > "$R26/z-probe-test.sh" <<EOF
#!/usr/bin/env bash
ls -d "\$PWD"/.git/run-all-tests.* > "$EVID26" 2>/dev/null
exit 0
EOF
git -C "$R26" add a-fail-test.sh z-probe-test.sh

run_runner --root "$R26"
NOFLAG_RC_26=$RC
NOFLAG_OUT_26=$OUT
run_runner --root "$R26" --jobs 1
expect_exit 1 "case26 --jobs 1 fails the failing suite"
if [ "$RC" -eq "$NOFLAG_RC_26" ] && [ "$OUT" = "$NOFLAG_OUT_26" ]; then pass; else
  fail "case26 --jobs 1 output differs from the no-flag run"
fi
if [ -s "$EVID26" ]; then
  fail "case26 scratch tree created at jobs=1: $(cat "$EVID26")"
else pass; fi
if ls "$R26/.git"/run-all-tests.* >/dev/null 2>&1; then
  fail "case26 scratch survived at jobs=1"
else pass; fi

# Case 27 (CDT-534 R38/AC3): bounded concurrency. Eight slow suites at
# --jobs 2: each records its start/end second into one evidence file the
# workers share (outside any git tree), so the test can compute the max
# number of simultaneously in-flight suites. Expect >= 2 (the pool actually
# overlaps) and <= 2 (never more than N).
R27=$(new_root)
EVID27="$TMP/concurrency-evidence-27.txt"
: > "$EVID27"
i=0
while [ "$i" -lt 8 ]; do
  cat > "$R27/slow-$i-test.sh" <<EOF
#!/usr/bin/env bash
printf 'start %s %s\n' "\$(date +%s)" "s$i" >> "$EVID27"
sleep 2
printf 'end %s %s\n' "\$(date +%s)" "s$i" >> "$EVID27"
EOF
  i=$((i + 1))
done
git -C "$R27" add -A

run_runner --root "$R27" --jobs 2
expect_exit 0 "case27 all slow suites pass"
expect_out "8 suites: 8 passed, 0 failed, 0 timed out, 0 quarantined, 0 skipped" "case27 summary"

MAX27=0
while read -r _word ts _name; do
  CONC=0
  while read -r word2 ts2 _name2; do
    [ "$word2" = "start" ] || continue
    if [ "$ts2" -le "$ts" ] && [ "$ts" -lt "$((ts2 + 2))" ]; then
      CONC=$((CONC + 1))
    fi
  done < "$EVID27"
  if [ "$CONC" -gt "$MAX27" ]; then MAX27=$CONC; fi
done < "$EVID27"
if [ "$MAX27" -le 2 ]; then pass; else
  fail "case27 max in flight $MAX27 exceeds --jobs 2"
fi
if [ "$MAX27" -ge 2 ]; then pass; else
  fail "case27 pool never overlapped two suites (max in flight $MAX27)"
fi

# Case 28 (CDT-534 R10/AC2): --jobs 2 emits in R4 order when the R4-first
# suite is slower. a-slow sleeps 2s, b-fast exits immediately; the b-fast
# line must still print after the a-slow line.
R28=$(new_root)
cat > "$R28/a-slow-test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
exit 0
EOF
ok_suite > "$R28/b-fast-test.sh"
git -C "$R28" add -A

run_runner --root "$R28" --jobs 2
expect_exit 0 "case28 slow-first run passes"
WANT28=$'PASS a-slow-test.sh\nPASS b-fast-test.sh'
GOT28=$(printf '%s\n' "$OUT" | grep -F 'PASS ' )
if [ "$GOT28" = "$WANT28" ]; then pass; else
  fail "case28 R4 order violated at --jobs 2: got [$GOT28] want [$WANT28]"
fi

# Case 29 (CDT-534 R10/AC2): FAIL tails are byte-identical to jobs=1 for the
# same failing suite. One failing suite emits known lines; both runs must
# print the same status line and the same '    | ' tail.
R29=$(new_root)
printf '%s\n' '#!/usr/bin/env bash' 'echo "out line one"' 'echo "err line two" >&2' 'echo "out line three"' 'exit 4' > "$R29/a-fail-test.sh"
ok_suite > "$R29/z-slow-test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 2' 'exit 0' > "$R29/z-slow-test.sh"
git -C "$R29" add -A

run_runner --root "$R29" --jobs 1
J1_RC_29=$RC
J1_OUT_29=$OUT
run_runner --root "$R29" --jobs 2
J2_RC_29=$RC
J2_OUT_29=$OUT
expect_exit 1 "case29 --jobs 2 fails the failing suite"
if [ "$J1_RC_29" = "$J2_RC_29" ] && [ "$J1_OUT_29" = "$J2_OUT_29" ]; then pass; else
  fail "case29 --jobs 2 output differs from --jobs 1: [$J2_OUT_29] vs [$J1_OUT_29]"
fi
if printf '%s\n' "$J2_OUT_29" | grep -qF 'FAIL a-fail-test.sh (exit 4)'; then pass; else
  fail "case29 FAIL line missing"
fi
if printf '%s\n' "$J2_OUT_29" | grep -qxF '    | out line three'; then pass; else
  fail "case29 tail not byte-verbatim (missing '    | out line three')"
fi

# Case 30 (CDT-534 R7/AC5): TIMEOUT grandchild kill still holds at --jobs 2.
# The timed-out suite's TERM-ignoring grandchild must not survive the run,
# and the other in-flight suite must still be reported.
R30=$(new_root)
TOK30="rat_case30_$$_marker"
gen_sleep_suite "$TOK30" ignore-term > "$R30/a-hang-test.sh"
ok_suite > "$R30/b-ok-test.sh"
git -C "$R30" add -A

RUN_ALL_TESTS_TIMEOUT=2 run_runner --root "$R30" --jobs 2
expect_exit 1 "case30 TIMEOUT at --jobs 2"
expect_out "TIMEOUT a-hang-test.sh (timed out after 2s)" "case30 TIMEOUT line at --jobs 2"
expect_out "PASS b-ok-test.sh" "case30 the concurrent suite still reported"
expect_no_process "$TOK30" "case30 grandchild process survived at --jobs 2"

# Case 31 (CDT-534 R11/R12/AC6): quarantine unchanged at --jobs 2 — an
# all-scoped entry turns a red suite QUARANTINED with exit 0, and an
# exit-77 suite stays SKIP.
R31=$(new_root)
fail_suite > "$R31/a-red-test.sh"
skip_suite > "$R31/b-skip-test.sh"
git -C "$R31" add -A
mkdir -p "$R31/tools"
printf 'a-red-test.sh all red at jobs 2\n' > "$R31/tools/test-quarantine.txt"
run_runner --root "$R31" --jobs 2
expect_exit 0 "case31 quarantined FAIL does not fail --jobs 2"
expect_out "QUARANTINED a-red-test.sh (exit 1)" "case31 QUARANTINED line at --jobs 2"
expect_out "SKIP b-skip-test.sh" "case31 SKIP unchanged at --jobs 2"
expect_out "2 suites: 0 passed, 0 failed, 0 timed out, 1 quarantined, 1 skipped" "case31 summary"

# Case 32 (CDT-534 Q6): per-worker TMPDIR. Two suites mkdir the same path
# under the DEFAULT TMPDIR; at --jobs 2 each runs in its own worker, so both
# succeed -- the second never sees the first's directory.
R32C=$(new_root)
COLLIDE="${TMPDIR:-/tmp}/cdt534-case32-collide.$$"
# The suites resolve TMPDIR at RUN time, not generation time: the point is
# that the pool points $TMPDIR into the worker scratch, so the same relative
# path lands in two different directories.
cat > "$R32C/a-mkdir-test.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "\${TMPDIR:-/tmp}/cdt534-case32-collide.$$/sub"
EOF
cat > "$R32C/b-mkdir-test.sh" <<EOF
#!/usr/bin/env bash
test -e "\${TMPDIR:-/tmp}/cdt534-case32-collide.$$/sub" && exit 1
mkdir -p "\${TMPDIR:-/tmp}/cdt534-case32-collide.$$/sub"
EOF
git -C "$R32C" add -A

rm -rf "$COLLIDE"
run_runner --root "$R32C" --jobs 2
expect_exit 0 "case32 per-worker TMPDIR keeps both suites green"
expect_out "PASS a-mkdir-test.sh" "case32 mkdir suite 1 passes"
expect_out "PASS b-mkdir-test.sh" "case32 mkdir suite 2 passes (saw no leftover dir)"
rm -rf "$COLLIDE"

# Negative control: the same pair with the flag omitted shares the default
# TMPDIR, so the second suite sees the first's directory and fails.
run_runner --root "$R32C" --jobs 1
expect_exit 1 "case32 control: shared TMPDIR fails serially"
expect_out "FAIL b-mkdir-test.sh (exit 1)" "case32 control names the collision"

# Case 33 (CDT-534 R36/AC1): RUN_ALL_TESTS_JOBS=1 is outcome-identical to the
# omitted-flag run on the same tree (the flag path and the env path must land
# on the same identity branch), and an empty env value counts as omitted.
run_runner --root "$R26"
NOFLAG_RC_33=$RC
NOFLAG_OUT_33=$OUT
RUN_ALL_TESTS_JOBS=1 run_runner --root "$R26"
expect_exit 1 "case33 env jobs=1 fails the failing suite"
if [ "$RC" -eq "$NOFLAG_RC_33" ] && [ "$OUT" = "$NOFLAG_OUT_33" ]; then pass; else
  fail "case33 env jobs=1 output differs from the omitted-flag run"
fi
RUN_ALL_TESTS_JOBS= run_runner --root "$R26" --list
expect_exit 0 "case33 empty env counts as omitted (R36)"

# Case 34 (CDT-534 AC11, live read-only): the ship-gate call sites invoke the
# runner with --jobs 8. smoke.yml and the light-tier QA step carry the
# literal line; /release Step 4.13 resolves the runner path into $X first,
# so there it is the pair `tools/run-all-tests.sh` + `--jobs 8`. The macos
# line's no---jobs negative is owned by tools/ci-workflow-test.sh rule B8 --
# not duplicated here.
QA_STEP_MD="$REPO_ROOT/skills/orchestrate/steps/10-qa.md"
RELEASE_SKILL_MD="$REPO_ROOT/skills/release/SKILL.md"
if grep -qF 'bash tools/run-all-tests.sh --jobs 8' "$SMOKE_YML"; then pass; else
  fail "case34 smoke.yml all-tests does not run --jobs 8"
fi
if grep -qF 'bash tools/run-all-tests.sh --jobs 8' "$QA_STEP_MD"; then pass; else
  fail "case34 10-qa.md does not run --jobs 8"
fi
if grep -qF 'tools/run-all-tests.sh' "$RELEASE_SKILL_MD" && grep -qF -- '--jobs 8' "$RELEASE_SKILL_MD"; then pass; else
  fail "case34 release SKILL.md Step 4.13 does not run the runner with --jobs 8"
fi

# Case 35 (CDT-534 R38/AC10): static text scan -- the runner contains no
# `wait -n`, no `xargs -P` and no `nproc`. The planted control proves the
# scan bites (red) before the real runner must come back clean (green).
PLANT35="$TMP/banned-constructs.sh"
printf '#!/usr/bin/env bash\nwait -n\nxargs -P 4\nnproc\n' > "$PLANT35"
PLANT35_HITS=$(grep -nE 'wait -n|xargs -P|nproc' "$PLANT35")
if [ -n "$PLANT35_HITS" ]; then pass; else
  fail "case35 scan does not detect the planted banned constructs"
fi
RUNNER_HITS=$(grep -nE 'wait -n|xargs -P|nproc' "$RUNNER")
if [ -z "$RUNNER_HITS" ]; then pass; else
  fail "case35 runner text contains a banned construct: $RUNNER_HITS"
fi

# Case 36 (CDT-534 rework): a failed dispatch must return its worker to the
# free list. Plant: GIT_CONFIG_GLOBAL with an invalid status.showUntrackedFiles
# — only the dispatch probe `git status --porcelain` exits 128; at --jobs 2
# with 3 suites a leaked pool dies on "no free worker" (returned: 3 reported).
R36=$(new_root)
for s in a b c; do ok_suite > "$R36/$s-w-leak-test.sh"; done
git -C "$R36" add -A
BADCFG36="$TMP/bad-status-config.gitconfig"
printf '[status]\n\tshowUntrackedFiles = bogus\n' > "$BADCFG36"

GIT_CONFIG_GLOBAL="$BADCFG36" run_runner --root "$R36" --jobs 2
expect_exit 1 "case36 dispatch failures fail the run"
expect_out "FAIL a-w-leak-test.sh (could not prepare worker)" "case36 dispatch failure reported"
expect_out "FAIL c-w-leak-test.sh (could not prepare worker)" "case36 third suite still got a worker"
expect_out "3 suites: 0 passed, 3 failed, 0 timed out, 0 quarantined, 0 skipped" "case36 all three suites dispatched"
expect_not_out "no free worker" "case36 free list not drained by dispatch failures"

# Case 37 (CDT-534 R36): --jobs auto is min(processors, 8) via the
# getconf -> sysctl -> 1 chain. The runner has no override hook, so pin the
# probe with stubbed binaries on PATH. All N workers are created up front,
# so a probe suite counting sibling worker.N dirs sees the pool size (0 = jobs=1).
R37=$(new_root)
EVID37="$TMP/auto-evidence-37.txt"
cat > "$R37/z-auto-probe-test.sh" <<EOF
#!/usr/bin/env bash
n=0
for d in ../worker.*; do
  if [ -d "\$d" ]; then n=\$((n + 1)); fi
done
printf '%s\n' "\$n" > "$EVID37"
exit 0
EOF
git -C "$R37" add -A
STUB37="$TMP/auto-stub-bin"
mkdir -p "$STUB37"
: > "$STUB37/getconf"
: > "$STUB37/sysctl"
chmod +x "$STUB37/getconf" "$STUB37/sysctl"

expect_pool37() { # expect_pool37 <want> <label>
  if [ "$(cat "$EVID37")" = "$1" ]; then pass; else
    fail "$2: resolved pool $(cat "$EVID37"), want $1"
  fi
}

# Scenario: <getconf body> | <sysctl body, - keeps the previous> | <want> | <label>
while IFS='|' read -r gc sc want label; do
  printf '#!/usr/bin/env bash\n%s\n' "$gc" > "$STUB37/getconf"
  if [ "$sc" != "-" ]; then printf '#!/usr/bin/env bash\n%s\n' "$sc" > "$STUB37/sysctl"; fi
  PATH="$STUB37:$PATH" run_runner --root "$R37" --jobs auto
  expect_pool37 "$want" "case37 $label"
done <<'SPECS'
echo 3|-|3|getconf=3
echo 99|-|8|getconf=99 capped at 8
exit 1|echo 5|5|getconf-less sysctl=5 fallback
exit 1|exit 1|0|both probes failing falls back to jobs=1 (no scratch)
SPECS

# Case 38 (CDT-534 AC3, the literal shape): --jobs 4 on 8 slow suites never
# has 5 process groups in flight; the pool must reach exactly 4 (case 27's
# start/end timestamp technique).
R38=$(new_root)
EVID38="$TMP/concurrency-evidence-38.txt"
: > "$EVID38"
i=0
while [ "$i" -lt 8 ]; do
  cat > "$R38/slow-$i-test.sh" <<EOF
#!/usr/bin/env bash
printf 'start %s %s\n' "\$(date +%s)" "s$i" >> "$EVID38"
sleep 2
printf 'end %s %s\n' "\$(date +%s)" "s$i" >> "$EVID38"
EOF
  i=$((i + 1))
done
git -C "$R38" add -A

run_runner --root "$R38" --jobs 4
expect_exit 0 "case38 all slow suites pass at --jobs 4"
expect_out "8 suites: 8 passed, 0 failed, 0 timed out, 0 quarantined, 0 skipped" "case38 summary"

MAX38=$(awk '$1 == "start" { s[++n] = $2 }
  END { max = 0
        for (i = 1; i <= n; i++) {
          c = 0
          for (j = 1; j <= n; j++) if (s[j] <= s[i] && s[i] < s[j] + 2) c++
          if (c > max) max = c
        }
        print max }' "$EVID38")
if [ "$MAX38" -eq 4 ]; then pass; else
  fail "case38 max suites in flight $MAX38, want exactly 4 (never 5)"
fi

echo "---"
echo "run-all-tests bite-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
