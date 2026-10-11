#!/usr/bin/env bash
# SPEC-030 R17 (CDT-534 round 2): pool-era bites that tools/run-all-tests-test.sh
# (at its 1000-line cap) cannot hold — R37 `git rm` / `git mv` overlay, R39
# worker hygiene on a reused worker, and the AC14 shapes (macos-scope,
# --portable, PATH git shim) at --jobs 2. Same harness contract as the sibling
# bite test: RUNNER + TMP set before sourcing the shared R17 harness; owns
# PASS/FAIL/OUT/ERR/RC; never touches the real repo tree; all temp material
# under mktemp -d / $TMPDIR, removed on EXIT.
#
# The final case is the AC12 red-then-green receipt: the rm/mv/leak trees are
# re-run against the round-1 runner (git show 9a61f6b:tools/run-all-tests.sh
# extracted to a temp CLI -- it has --jobs, but neither the rm/mv overlay nor
# the full worker restore) and must FAIL there for the probes' recorded
# reasons, then PASS against this tree (the green runs above). Skipped with a
# NOTE when the round-1 object is not present.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
RUNNER="$REPO_ROOT/tools/run-all-tests.sh"
# Round-1 runner (pre-pool-fix): has --jobs, but not the rm/mv overlay and
# not the full R39 restore -- the caseP7 reds must fail for exactly those.
RED_SHA=9a61f6b341dbd92095df8c69f010a720c60f7c2e

PASS=0
FAIL=0
OUT=""
ERR=""
RC=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/run-all-tests-pool-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

. "$REPO_ROOT/tests/lib/run-all-tests-harness.sh"

# Case P1 (CDT-534 R37/AC8): a planted staged `git rm` of a tracked file is
# absent from every worker — index and worktree. The probe self-asserts (exit
# 1 on violation), so a runner that drops the deletion FAILs the probe.
P1=$(new_root)
printf 'doomed\n' > "$P1/doomed.txt"
git -C "$P1" add doomed.txt
git -C "$P1" -c user.name=T -c user.email=t@t commit -qm base
git -C "$P1" rm -q doomed.txt
EVID1="$TMP/evid-rm.txt"
cat > "$P1/z-probe-test.sh" <<EOF
#!/usr/bin/env bash
rc=0
if [ -e doomed.txt ]; then printf 'WT_PRESENT\n' >> "$EVID1"; rc=1; fi
if git ls-files --error-unmatch doomed.txt >/dev/null 2>&1; then printf 'IX_PRESENT\n' >> "$EVID1"; rc=1; fi
exit \$rc
EOF
git -C "$P1" add z-probe-test.sh

run_runner --root "$P1" --jobs 2
expect_exit 0 "caseP1 staged git rm run passes at --jobs 2"
expect_out "PASS z-probe-test.sh" "caseP1 probe passes in the worker"
[ -s "$EVID1" ] && fail "caseP1 worker saw the removed file: $(cat "$EVID1")" || pass

# Case P2 (CDT-534 R37/AC8): a planted staged `git mv` shows the new path
# cached (with the moved bytes) and the old path gone, in the worker.
P2=$(new_root)
printf 'moved-bytes\n' > "$P2/old.txt"
git -C "$P2" add old.txt
git -C "$P2" -c user.name=T -c user.email=t@t commit -qm base
git -C "$P2" mv old.txt new.txt
EVID2="$TMP/evid-mv.txt"
cat > "$P2/z-probe-test.sh" <<EOF
#!/usr/bin/env bash
rc=0
if [ -e old.txt ]; then printf 'OLD_WT_PRESENT\n' >> "$EVID2"; rc=1; fi
if git ls-files --error-unmatch old.txt >/dev/null 2>&1; then printf 'OLD_IX_PRESENT\n' >> "$EVID2"; rc=1; fi
[ "\$(git show :new.txt 2>/dev/null)" = "moved-bytes" ] || { printf 'IX_NEW=%s\n' "\$(git show :new.txt 2>/dev/null)" >> "$EVID2"; rc=1; }
[ "\$(cat new.txt 2>/dev/null)" = "moved-bytes" ] || { printf 'WT_NEW=%s\n' "\$(cat new.txt 2>/dev/null)" >> "$EVID2"; rc=1; }
exit \$rc
EOF
git -C "$P2" add z-probe-test.sh

run_runner --root "$P2" --jobs 2
expect_exit 0 "caseP2 staged git mv run passes at --jobs 2"
expect_out "PASS z-probe-test.sh" "caseP2 probe passes in the worker"
[ -s "$EVID2" ] && fail "caseP2 worker lost the rename state: $(cat "$EVID2")" || pass

# Case P3 (CDT-534 R39/AC13): worker hygiene on a REUSED worker. a-leak is
# dispatched first and slow (holds worker 1 for ~2s): it writes an ignored
# .claude/ file, a stray ref and a dummy commit. b-hold is dispatched second
# and holds worker 2 for ~5s — longer than a-leak — so when a-leak leaks at
# ~2s, worker 1 is the only free slot: y-mid then z-probe recycle worker 1,
# and worker 2 stays pinned until b-hold returns. z-probe therefore observes
# the worker a-leak used: seed HEAD, no stray ref, no leftover ignored file,
# clean porcelain. (With an instant second dispatch the probe could land on
# worker 2 while worker 1 is still leaking, so a no-op restore_worker would
# pass — the hold pins the probe onto the leaked worker.) The probe
# self-asserts, so the round-1 runner's incomplete restore FAILs it (that
# red is case P7's receipt).
# Everything but the probe is committed at setup: a staged entry would be
# consumed by a-leak's dummy commit and look like dirt. The probe stays
# untracked (??) — present before and after a-leak, so R9 stays quiet and
# restore recopies it from the seed's others list.
P3=$(new_root)
printf '.claude/\n' > "$P3/.gitignore"
printf 'seed\n' > "$P3/seed.txt"
cat > "$P3/a-leak-test.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p .claude && printf 'leak\n' > .claude/leftover.txt
git update-ref refs/heads/leaked-branch HEAD
git -c user.name=T -c user.email=t@t commit -qm dummy --allow-empty
sleep 2
exit 0
EOF
printf '#!/usr/bin/env bash\nsleep 5\nexit 0\n' > "$P3/b-hold-test.sh"
ok_suite > "$P3/y-mid-test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P3/z-probe-test.sh"
git -C "$P3" add .gitignore seed.txt a-leak-test.sh b-hold-test.sh y-mid-test.sh
git -C "$P3" -c user.name=T -c user.email=t@t commit -qm seed
SEED_SHA_P3=$(git -C "$P3" rev-parse HEAD)
EVID3="$TMP/evid-leak.txt"
cat > "$P3/z-probe-test.sh" <<EOF
#!/usr/bin/env bash
{
  echo "HEAD=\$(git rev-parse HEAD)"
  git show-ref --verify --quiet refs/heads/leaked-branch && echo REF_PRESENT || echo REF_ABSENT
  [ -e .claude/leftover.txt ] && echo LEAK_PRESENT || echo LEAK_ABSENT
  git status --porcelain --untracked-files=all
  git status --porcelain --untracked-files=all | grep -v '^?? z-probe-test.sh\$' | grep -q . && echo DIRTY || echo CLEAN
} > "$EVID3"
rc=0
[ "\$(git rev-parse HEAD)" = "$SEED_SHA_P3" ] || rc=1
git show-ref --verify --quiet refs/heads/leaked-branch && rc=1
[ -e .claude/leftover.txt ] && rc=1
git status --porcelain --untracked-files=all | grep -v '^?? z-probe-test.sh\$' | grep -q . && rc=1
exit \$rc
EOF

run_runner --root "$P3" --jobs 2
expect_exit 0 "caseP3 leak run passes at --jobs 2 (restore_worker held)"
expect_out "4 suites: 4 passed, 0 failed, 0 timed out, 0 quarantined, 0 skipped" "caseP3 all four suites counted"
expect_out "PASS z-probe-test.sh" "caseP3 probe saw seed state on the reused worker"
if grep -q "^HEAD=$SEED_SHA_P3\$" "$EVID3" && grep -q REF_ABSENT "$EVID3" \
   && grep -q LEAK_ABSENT "$EVID3" && grep -q CLEAN "$EVID3"; then pass; else
  fail "caseP3 reused worker evidence is not seed state: $(cat "$EVID3")"
fi

# Case P4 (CDT-534 AC14): a macos-scoped quarantine entry still turns a red
# suite QUARANTINED (exit 0, counted) at --jobs 2 --platform macos.
P4=$(new_root)
fail_suite > "$P4/a-red-test.sh"
git -C "$P4" add -A
mkdir -p "$P4/tools"
printf 'a-red-test.sh macos red at jobs 2\n' > "$P4/tools/test-quarantine.txt"
run_runner --root "$P4" --jobs 2 --platform macos
expect_exit 0 "caseP4 macos-scope quarantine does not fail --jobs 2"
expect_out "QUARANTINED a-red-test.sh (exit 1)" "caseP4 QUARANTINED line at --jobs 2"
expect_out "1 suites: 0 passed, 0 failed, 0 timed out, 1 quarantined, 0 skipped" "caseP4 quarantined suite counted in the summary"

# Case P5 (CDT-534 AC14/R38): --portable composes with --jobs 2 — the filter
# still applies, the pool engages, output stays in R4 order, and a portable
# failure still exits 1.
P5=$(new_root)
ok_suite > "$P5/a-ok-test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'mapfile -t xs < /dev/null' 'exit 1' > "$P5/m-gnu-test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$P5/z-pfail-test.sh"
git -C "$P5" add -A

run_runner_split --root "$P5" --portable --jobs 2
expect_exit 1 "caseP5 --portable --jobs 2 fails the portable red suite"
expect_out "PASS a-ok-test.sh" "caseP5 portable suite ran through the pool"
expect_out "FAIL z-pfail-test.sh (exit 1)" "caseP5 portable red suite reported"
expect_not_out "m-gnu-test.sh" "caseP5 non-portable suite still excluded"
if echo "$ERR" | grep -qF "warn: portable: skipped 1 non-portable suite"; then pass; else
  fail "caseP5 portable warn missing at --jobs 2"
fi
P5_ORDER=$(printf '%s\n' "$OUT" | grep -nE '^(PASS|FAIL) ' | head -2 | cut -d: -f2 | tr '\n' ' ')
if [ "$P5_ORDER" = "PASS a-ok-test.sh FAIL z-pfail-test.sh (exit 1) " ]; then pass; else
  fail "caseP5 R4 order violated at --portable --jobs 2: [$P5_ORDER]"
fi

# Case P6 (CDT-534 AC14): a PATH git shim that logs every `git -C <root>`
# invocation records NOTHING after the first suite starts (the runner never
# runs git against --root while a jobs>1 suite is in flight). a-shim-slow is
# dispatched first: it sleeps 1s (aging out the runner's pre-pool git calls),
# stamps its start into the shared log, then holds the slot. The shim forwards
# to the real git and logs only `-C $SHIM_ROOT` calls.
P6=$(new_root)
cat > "$P6/a-shim-slow-test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 1
printf 'SUITE %s\n' "$(date +%s)" >> "$SHIM_LOG"
sleep 2
exit 0
EOF
ok_suite > "$P6/z-shim-probe-test.sh"
git -C "$P6" add -A

SHIM_BIN="$TMP/shim-bin"
mkdir -p "$SHIM_BIN"
SHIM_LOG="$TMP/shim.log"
: > "$SHIM_LOG"
SHIM_REAL_GIT=$(command -v git)
export SHIM_LOG SHIM_REAL_GIT
cat > "$SHIM_BIN/git" <<'SHIMEOF'
#!/usr/bin/env bash
if [ "${SHIM_LOG:-}" ] && [ "$1" = "-C" ] && [ "${2:-}" = "$SHIM_ROOT" ]; then
  printf 'GIT %s\n' "$(date +%s)" >> "$SHIM_LOG" || true
fi
exec "$SHIM_REAL_GIT" "$@"
SHIMEOF
chmod +x "$SHIM_BIN/git"

shim_red_after_suite() { # 0 when a GIT line follows the first SUITE line
  awk '$1 == "SUITE" { seen = 1 } $1 == "GIT" && seen { found = 1 } END { exit found ? 0 : 1 }' "$SHIM_LOG"
}

# Negative control first: a suite that itself calls `git -C <root>` MUST show
# up in the log — proves the shim intercepts and the marker works. Without it
# an empty log would also mean a broken shim.
P6B=$(new_root)
cat > "$P6B/a-shim-violator-test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 1
printf 'SUITE %s\n' "$(date +%s)" >> "$SHIM_LOG"
git -C "$SHIM_ROOT" rev-parse --show-toplevel >/dev/null
exit 0
EOF
ok_suite > "$P6B/z-shim-probe-test.sh"
git -C "$P6B" add -A
SHIM_ROOT=$(git -C "$P6B" rev-parse --show-toplevel)
export SHIM_ROOT
PATH="$SHIM_BIN:$PATH" run_runner --root "$P6B" --jobs 2
expect_exit 0 "caseP6b control run passes"
if grep -q '^SUITE ' "$SHIM_LOG" && shim_red_after_suite; then pass; else
  fail "caseP6b control: the shim did not record a suite-time git -C root call"
fi

# The real bite: no GIT line may follow the first SUITE line.
P6_ROOT=$(git -C "$P6" rev-parse --show-toplevel)
: > "$SHIM_LOG"
SHIM_ROOT="$P6_ROOT"
export SHIM_ROOT
PATH="$SHIM_BIN:$PATH" run_runner --root "$P6" --jobs 2
expect_exit 0 "caseP6 pool run under the git shim passes"
if grep -q '^SUITE ' "$SHIM_LOG"; then pass; else
  fail "caseP6 suite start marker missing from the shim log"
fi
if shim_red_after_suite; then
  fail "caseP6 the runner ran git against --root while suites were in flight: $(grep '^GIT' "$SHIM_LOG" | head -3)"
else pass; fi

# Case P8 (CDT-534 AC14): a macos-scoped entry on a PASSING suite at
# --jobs 2 keeps the PASS and prints the stale-entry warn: on stderr only
# (the sibling's case 16, in the pool era).
P8=$(new_root)
ok_suite > "$P8/test.sh"
git -C "$P8" add -A
mkdir -p "$P8/tools"
printf 'test.sh macos stale macos entry\n' > "$P8/tools/test-quarantine.txt"
run_runner_split --root "$P8" --jobs 2 --platform macos
expect_exit 0 "caseP8 stale macos entry passes at --jobs 2"
expect_out "PASS test.sh" "caseP8 still reports PASS at --jobs 2"
if echo "$ERR" | grep -qF "warn:"; then pass; else
  fail "caseP8 warn: line did not appear on stderr"
fi
if echo "$OUT" | grep -qF "warn:"; then
  fail "caseP8 warn: leaked onto stdout"
else pass; fi

# Case P9 (CDT-534 R7/AC5): the KILL grace at --jobs 2. The suite leader and
# its grandchild both survive the deadline TERM (caught / exec-inherited
# ignore), so only the watchdog's later KILL can end them: the run must not
# return before the 2s deadline, the suite must still be heartbeating
# at/after it (alive through the TERM), and the grandchild must be gone once
# the run returns (the KILL ran). No hard upper bound on elapsed: under load
# reaping may stretch, so dead-by-expect_no_process is the ceiling assertion.
P9=$(new_root)
TOK9="rat_caseP9_$$_marker"
HEART9="$TMP/heart9.txt"
: > "$HEART9"
export HEART9
cat > "$P9/a-tenacity-test.sh" <<EOF
#!/usr/bin/env bash
trap : TERM
( trap '' TERM; exec -a '$TOK9' sleep 987 ) &
while :; do
  printf '%s\n' "\$(date +%s)" >> "\$HEART9"
  sleep 1
done
EOF
ok_suite > "$P9/b-fast-test.sh"
git -C "$P9" add -A
T0=$(date +%s)
RUN_ALL_TESTS_TIMEOUT=2 run_runner --root "$P9" --jobs 2
T1=$(date +%s)
expect_exit 1 "caseP9 TERM-trapping suite times out at --jobs 2"
expect_out "TIMEOUT a-tenacity-test.sh (timed out after 2s)" "caseP9 TIMEOUT line at --jobs 2"
expect_out "PASS b-fast-test.sh" "caseP9 the concurrent suite still reported"
if awk -v t0="$T0" '$1 >= t0 + 2 { ok = 1 } END { exit ok ? 0 : 1 }' "$HEART9"; then pass; else
  fail "caseP9 no heartbeat at/after the 2s deadline (the TERM ended the suite)"
fi
if [ "$T1" -ge "$((T0 + 2))" ]; then pass; else
  fail "caseP9 run returned before the 2s deadline (T0=$T0 T1=$T1)"
fi
expect_no_process "$TOK9" "caseP9 grandchild survived the KILL grace"

# Case P10 (CDT-534 unstaged-deletion restore): a path deleted on disk but
# still in --root's index must stay deleted on a REUSED worker (restore's
# checkout-index -a -f would otherwise put it back -- results would depend on
# worker assignment). Same pinning shape as case P3 (b-pin sleep 5 > a-hold
# sleep 2): y-mid and z-probe recycle worker 1 after a-hold, so z-probe
# observes a restored worker. The probe self-asserts: gone.txt absent from
# the worktree, still tracked in the index.
P10=$(new_root)
printf 'gone\n' > "$P10/gone.txt"
git -C "$P10" add gone.txt
git -C "$P10" -c user.name=T -c user.email=t@t commit -qm base
rm "$P10/gone.txt"
printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$P10/a-hold-test.sh"
printf '#!/usr/bin/env bash\nsleep 5\nexit 0\n' > "$P10/b-pin-test.sh"
ok_suite > "$P10/y-mid-test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P10/z-probe-test.sh"
git -C "$P10" add a-hold-test.sh b-pin-test.sh y-mid-test.sh
git -C "$P10" -c user.name=T -c user.email=t@t commit -qm seed
EVID10="$TMP/evid-restore.txt"
cat > "$P10/z-probe-test.sh" <<EOF
#!/usr/bin/env bash
{
  [ -e gone.txt ] && echo GONE_WT_PRESENT || echo GONE_WT_ABSENT
  git ls-files --error-unmatch gone.txt >/dev/null 2>&1 && echo GONE_IX_PRESENT || echo GONE_IX_ABSENT
} > "$EVID10"
[ -e gone.txt ] && exit 1
git ls-files --error-unmatch gone.txt >/dev/null 2>&1 || exit 1
exit 0
EOF
run_runner --root "$P10" --jobs 2
expect_exit 0 "caseP10 unstaged-deletion tree passes at --jobs 2"
expect_out "4 suites: 4 passed, 0 failed, 0 timed out, 0 quarantined, 0 skipped" "caseP10 all four suites counted"
expect_out "PASS z-probe-test.sh" "caseP10 probe saw the deletion on the reused worker"
if grep -q GONE_WT_ABSENT "$EVID10" && grep -q GONE_IX_PRESENT "$EVID10"; then pass; else
  fail "caseP10 reused worker lost the unstaged deletion: $(cat "$EVID10")"
fi

# Case P7 (CDT-534 AC12): red-then-green receipt. The rm/mv/leak/restore
# trees are re-run against the round-1 runner (9a61f6b -- has --jobs, but
# neither the rm/mv overlay nor the full R39 restore) and must FAIL there
# for the probes' recorded reasons (the leak tree serially -- see below);
# green is the same trees above against this tree's runner. Skipped with a
# NOTE when the round-1 object is not available (shallow clone); the
# printed lines are the receipt.
RED_RUNNER="$TMP/red-run-all-tests.sh"
if git -C "$REPO_ROOT" cat-file -e "$RED_SHA:tools/run-all-tests.sh" 2>/dev/null \
   && git -C "$REPO_ROOT" show "$RED_SHA:tools/run-all-tests.sh" > "$RED_RUNNER" 2>/dev/null; then
  SAVED_RUNNER="$RUNNER"
  RUNNER="$RED_RUNNER"

  : > "$EVID1"
  run_runner --root "$P1" --jobs 2
  expect_exit 1 "caseP7 red: round-1 runner fails the staged-rm tree at --jobs 2"
  expect_out "FAIL z-probe-test.sh" "caseP7 red receipt: the rm probe fails (deletion not applied)"
  if grep -qE 'WT_PRESENT|IX_PRESENT' "$EVID1"; then pass; else
    fail "caseP1 red evidence missing WT_PRESENT/IX_PRESENT: $(cat "$EVID1")"
  fi
  echo "red-artifact: $RED_SHA --jobs 2 rm tree -> exit $RC: $(grep -hE 'WT_PRESENT|IX_PRESENT' "$EVID1" | sort -u | head -2 | tr '\n' ';')"

  : > "$EVID2"
  run_runner --root "$P2" --jobs 2
  expect_exit 1 "caseP7 red: round-1 runner fails the staged-mv tree at --jobs 2"
  expect_out "FAIL z-probe-test.sh" "caseP7 red receipt: the mv probe fails (rename state lost)"
  if grep -qE 'OLD_WT_PRESENT|OLD_IX_PRESENT|IX_NEW=' "$EVID2"; then pass; else
    fail "caseP2 red evidence missing rename-loss markers: $(cat "$EVID2")"
  fi
  echo "red-artifact: $RED_SHA --jobs 2 mv tree -> exit $RC: $(grep -hE 'OLD_WT_PRESENT|OLD_IX_PRESENT|IX_NEW=' "$EVID2" | sort -u | head -2 | tr '\n' ';')"

  : > "$EVID3"
  # Serial, not --jobs 2: the round-1 reap loop blocks in runlist order, so
  # at --jobs 2 the probe lands on the fresh worker 2 and misses the leak.
  # Serially the round-1 runner has no restore at all: the probe observes
  # a-leak's ignored file and stray ref in --root itself.
  run_runner --root "$P3"
  expect_exit 1 "caseP7 red: round-1 runner fails the leak tree serially"
  expect_out "FAIL z-probe-test.sh" "caseP7 red receipt: the leak probe fails without any restore"
  if grep -qE 'LEAK_PRESENT|REF_PRESENT|DIRTY' "$EVID3"; then pass; else
    fail "caseP3 red evidence missing leak markers: $(cat "$EVID3")"
  fi
  echo "red-artifact: $RED_SHA serial leak tree -> exit $RC: $(grep -hE 'LEAK_PRESENT|REF_PRESENT|DIRTY' "$EVID3" | sort -u | head -2 | tr '\n' ';')"

  : > "$EVID10"
  run_runner --root "$P10" --jobs 2
  expect_exit 1 "caseP7 red: round-1 runner fails the restore tree at --jobs 2"
  expect_out "FAIL z-probe-test.sh" "caseP7 red receipt: the restore probe fails (deletion put back)"
  if grep -q GONE_WT_PRESENT "$EVID10"; then pass; else
    fail "caseP10 red evidence missing GONE_WT_PRESENT: $(cat "$EVID10")"
  fi
  echo "red-artifact: $RED_SHA --jobs 2 restore tree -> exit $RC: $(grep -h GONE_WT_PRESENT "$EVID10" | head -1)"

  RUNNER="$SAVED_RUNNER"
else
  pass
  echo "NOTE: the round-1 runner ($RED_SHA:tools/run-all-tests.sh) not present; caseP7 red-then-green skipped"
fi

echo "---"
echo "run-all-tests pool bite-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
