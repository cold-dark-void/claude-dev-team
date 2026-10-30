#!/usr/bin/env bash
# ticket-class-receipts-test.sh — CDT-595 per-AC receipt meta-suite
# (SPEC-009 § CDT-595). Receipts about receipts: every case runs a labeled
# suite as a nested subprocess and asserts the shape the M14 per-AC
# investigator depends on.
#
#   AC2  force-fail hook: a planted failure gives a non-zero nested exit and
#        the `FAIL: AC<n>: <slug>: planted` shape on stderr
#   AC3  the `--ac` grammar on both suites: a subset run exits 0 with its
#        receipts, the planted-fail subset run exits non-zero (the m>0 arm of
#        "exits 0 iff m=0"), every malformed form exits 64 with one usage line
#   AC4  every technical C1 AC filter runs green on the suite that owns it,
#        and each C1 strike-list slug shows its own receipt
#   AC5  the AC13 perf case is scoped to --ac AC13 (absent from a bare full
#        run, present under the filter) and echoes its 100-row/256 KB fixture
#        counts into the run log
#   AC6  the uid-0 mode-000 skip: `skip AC7:`, never `SKIP:`, counted by
#        neither counter; the root arm is exhibited under fakeroot
#   AC7  consumer compat at the C1 HEAD faa0249: full-run aggregate last line,
#        exit 0/64 preserved, portable touch-set bare runs green, classifier
#        byte-identical, suite-only path set
#   AC8  the T1 spike (investigator <AC_LABEL> template, colon form) plus a
#        >=1-line filtered receipt per technical AC of a real full-suite log
#   AC9  the `### CDT-589-C1` Verify repoint, spec-lint findings-set equality
#        vs an faa0249 archive, and C1 criterion-text (sans Verify) equality
#
# Nested targets are ticket-class-test.sh, router-static-test.sh and
# tools/spec-lint.sh only. This suite never invokes itself, so a nested
# `--ac AC2` cannot recurse into its own case.
#
# AC9 is findings-set baseline equality, not rc 0: tools/spec-lint.sh exits 1
# on master, on the stack base faa0249, and here, from two pre-existing
# findings (specs/OWNERS missing skills/advisor; SPEC-038 [history] order).
# The gate is that no finding names SPEC-009. That debt is a follow-up ticket.
#
# bash 3.2 / BSD-safe: this file stays in the run-all-tests --portable lane.
# Run: bash skills/orchestrate/ticket-class-receipts-test.sh [--ac AC<n>]
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
INV="$ROOT/skills/council/prompts/investigator.md"
SPEC="$ROOT/specs/core/SPEC-009-ticket-workflow.md"
TC="$HERE/ticket-class-test.sh"
RS="$HERE/router-static-test.sh"
LINT="$ROOT/tools/spec-lint.sh"

# Hermetic suite (SPEC-030 R20): the nested runs inherit TMPDIR and HOME, so
# no fixture reaches the caller's repo or git state.
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/ac-receipt.sh
. "$ROOT/tests/lib/ac-receipt.sh"
hermetic_init
parse_ac_args "$@"

PASS=0; FAIL=0; CUR_AC=""
WORK=$(mktemp -d "$TMPDIR/receipts.XXXXXX")

# The default <AC_LABEL> template, pinned verbatim from investigator.md.
# grep -F: the template is full of regex metacharacters, so match it as bytes.
PIN='AC X([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])X[0-9]*[:(]|(^|[^A-Za-z0-9_])X-[0-9]+'

# label_re <AC-id> — the substitution rule: every X in the template becomes
# the AC id. The template holds exactly three X tokens and no other X.
label_re() { printf '%s' "$PIN" | sed "s/X/$1/g"; }

# _lines <text> — line count of a captured value; 0 for the empty string.
_lines() {
  if [ -z "${1:-}" ]; then
    printf '0\n'
  else
    printf '%s\n' "$1" | wc -l | tr -d ' \n'
  fi
}

# _flat <text> — one-line form for a failure detail.
_flat() { printf '%s' "$1" | tr '\n' '|'; }

# run_nested <target> [args...] — run a suite in a subprocess. Sets NOUT
# (stdout), NERR (stderr), NRC (exit). NRC is seeded first: the assignment
# sits under `||`, where a zero exit leaves $? untouched.
run_nested() {
  local target=$1; shift
  NRC=0
  printf 'CMD: bash %s %s\n' "$target" "$*"
  NOUT=$(bash "$target" "$@" 2>"$WORK/err") || NRC=$?
  printf 'CMD exit=%s\n' "$NRC"
  NERR=$(cat "$WORK/err" 2>/dev/null)
}

# run_nested_env <VAR=value> <target> [args...] — same, with one export.
run_nested_env() {
  local kv=$1 target=$2; shift 2
  NRC=0
  printf 'CMD: env %s bash %s %s\n' "$kv" "$target" "$*"
  NOUT=$(env "$kv" bash "$target" "$@" 2>"$WORK/err") || NRC=$?
  printf 'CMD exit=%s\n' "$NRC"
  NERR=$(cat "$WORK/err" 2>/dev/null)
}

# expect_rc <slug> <want> — assert the last nested run exited as wanted.
expect_rc() {
  local slug=$1 want=$2
  if [ "$NRC" = "$want" ]; then
    ok "$slug"
  else
    bad "$slug" "rc=$NRC want=$want out=[$(_flat "$NOUT")] err=[$(_flat "$NERR")]"
  fi
}

# expect_usage <slug> <target> [args...] — a malformed `--ac` form exits 64,
# prints nothing on stdout, and prints exactly one usage line on stderr.
expect_usage() {
  local slug=$1 target=$2; shift 2
  local out="" err="" rc=0 n
  out=$(bash "$target" "$@" 2>"$WORK/eu") || rc=$?
  err=$(cat "$WORK/eu" 2>/dev/null)
  n=$(_lines "$err")
  if [ "$rc" -ne 64 ]; then
    bad "$slug" "rc=$rc want=64 out=[$(_flat "$out")] err=[$(_flat "$err")]"
  elif [ "$n" -ne 1 ]; then
    bad "$slug" "stderr has $n lines want=1: [$(_flat "$err")]"
  elif [ -n "$out" ]; then
    bad "$slug" "usage leaked to stdout: [$(_flat "$out")]"
  elif ! printf '%s\n' "$err" | grep -qF -- '[--ac AC<n>]'; then
    bad "$slug" "usage line shape: [$err]"
  else
    ok "$slug"
  fi
}

# has_line <slug> <log> <needle> / hasnt_line — literal substring tests.
has_line() {
  local slug=$1 log=$2 needle=$3
  if printf '%s\n' "$log" | grep -qF -- "$needle"; then
    ok "$slug"
  else
    bad "$slug" "no [$needle] in [$(printf '%s\n' "$log" | head -3 | tr '\n' '|')]"
  fi
}
# hasnt_line <slug> <log> <needle> — literal substring test.
hasnt_line() {
  local slug=$1 log=$2 needle=$3
  if printf '%s\n' "$log" | grep -qF -- "$needle"; then
    bad "$slug" "found [$needle] on [$(printf '%s\n' "$log" | grep -F -- "$needle" | head -1)]"
  else
    ok "$slug"
  fi
}

# hasnt_exact <slug> <log> <line> — the log holds no receipt line equal to
# <line>. Substring tests alias: `ok AC14: base-auth` is inside
# `ok AC14: base-author`, so the planted-slug check needs the whole line.
hasnt_exact() {
  local slug=$1 log=$2 line=$3
  if printf '%s\n' "$log" | grep -qxF -- "$line"; then
    bad "$slug" "found [$line]"
  else
    ok "$slug"
  fi
}

# has_receipt <slug> <log> <AC-id> <receipt-slug> — the log carries that
# receipt. A skip line counts: on a host that cannot run the check, the skip
# IS the receipt (SPEC-030 R18), and AC6 asserts the skip shape separately.
has_receipt() {
  local slug=$1 log=$2 id=$3 rslug=$4
  if printf '%s\n' "$log" | grep -qE "^(ok|skip) $id: $rslug([ (]|$)"; then
    ok "$slug"
  else
    bad "$slug" "no $id receipt for $rslug"
  fi
}

# aggregate_is_ok_count <slug> <log> — PASS=<n> equals the `^ok ` count, so a
# skip added to neither counter and no receipt is unlabeled.
aggregate_is_ok_count() {
  local slug=$1 log=$2 p c
  p=$(printf '%s\n' "$log" | tail -1 | sed -n 's/^PASS=\([0-9][0-9]*\) FAIL=.*/\1/p')
  c=$(printf '%s\n' "$log" | grep -c '^ok ')
  if [ -n "$p" ] && [ "$p" = "$c" ]; then
    ok "$slug"
  else
    bad "$slug" "PASS=[$p] ok-count=[$c] last=[$(printf '%s\n' "$log" | tail -1)]"
  fi
}

# probe <AC-id> <sample-line> <1=must-match|0=must-miss> <slug> — run the
# investigator filter over one line of the pinned spike sample ($SAMP).
probe() {
  local x="$1" ln="$2" want="$3" slug="$4" re rc=0
  re=$(label_re "$x")
  sed -n "${ln}p" "$SAMP" | grep -qE -- "$re" || rc=1
  if [ "$want" = "1" ] && [ "$rc" = "0" ]; then
    ok "$slug"
  elif [ "$want" = "0" ] && [ "$rc" = "1" ]; then
    ok "$slug"
  elif [ "$want" = "1" ]; then
    bad "$slug" "filter missed: $(sed -n "${ln}p" "$SAMP")"
  else
    bad "$slug" "filter matched a line it must not: $(sed -n "${ln}p" "$SAMP")"
  fi
}

# ---- AC2: the force-fail hook, proven on a nested run ---------------------
# CDT-595 AC2 / SPEC-009 C1 AC14 owns the eight base- receipts; base-auth is
# the planted one.
set_ac AC2
if want_ac; then
  run_nested_env AC_RECEIPT_FORCE_FAIL=base-auth "$TC" --ac AC14
  if [ "$NRC" -ne 0 ]; then ok fail-hook-exit-nonzero
  else bad fail-hook-exit-nonzero "nested rc=0 with a planted failure"; fi
  # Echo the raw numerals (exit code + nested aggregate): a receipt that the
  # suite "exits non-zero" must exhibit the numeral, not just assert it.
  printf 'nested rc=%s\n' "$NRC"
  printf 'nested aggregate: %s\n' "$(printf '%s\n' "$NOUT" | tail -1)"
  if printf '%s\n' "$NERR" | grep -qF -- 'FAIL: AC14: base-auth: planted'; then
    ok fail-hook-stderr-shape
    # Replay the nested stderr onto this suite's stdout, so the AC2 Verify log
    # carries the FAIL: shape the investigator reads. A dead stdout is a dead
    # suite: nothing downstream can report.
    printf '%s\n' "$NERR" || exit 1
    # Attribution is proven by the planted line landing in the nested stderr
    # under the forced slug: the receipt is conditional on that evidence.
    ok labeled-failure
  else
    bad fail-hook-stderr-shape "nested stderr [$(_flat "$NERR")]"
  fi
  hasnt_exact "fail-hook-ok-suppressed" "$NOUT" 'ok AC14: base-auth'
  if printf '%s\n' "$NOUT" | tail -1 | grep -qE '^PASS=[0-9][0-9]* FAIL=1$'; then
    ok fail-hook-aggregate
  else
    bad fail-hook-aggregate "nested aggregate [$(printf '%s\n' "$NOUT" | tail -1)] want FAIL=1"
  fi
fi

# ---- AC3: the --ac grammar on both suites ---------------------------------
set_ac AC3
if want_ac; then
  run_nested "$TC" --ac AC7
  expect_rc subset-ac7-exit-0 0
  # Every receipt of a --ac run carries the selected id: the run filter is
  # exact CUR_AC equality, not the investigator regex (spec AC3). The PASS=
  # aggregate is not a receipt, so filter to `^ok ` lines first.
  OFFENDERS=$(printf '%s\n' "$NOUT" | grep '^ok ' | grep -v '^ok AC7: ')
  if [ -z "$OFFENDERS" ]; then ok subset-ac7-only
  else bad subset-ac7-only "non-AC7 receipt: [$(printf '%s\n' "$OFFENDERS" | head -1)]"; fi
  if printf '%s\n' "$NOUT" | grep -q '^ok AC7: '; then
    ok subset-ac7-receipts
  else
    bad subset-ac7-receipts "no receipt in the --ac AC7 log"
  fi
  if printf '%s\n' "$NOUT" | tail -1 | grep -qE '^PASS=[0-9][0-9]* FAIL=0$'; then
    ok subset-ac7-aggregate
  else
    bad subset-ac7-aggregate "last line [$(printf '%s\n' "$NOUT" | tail -1)]"
  fi
  aggregate_is_ok_count subset-ac7-count-equals-pass "$NOUT"
  # The iff has two arms: exhibit the red direction. Plant one failure in a
  # nested --ac AC7 run; the subset must then exit non-zero with a FAIL=1
  # aggregate and an attributable FAIL: line (the AC2 hook supplies the seed).
  run_nested_env AC_RECEIPT_FORCE_FAIL=empty-file "$TC" --ac AC7
  if [ "$NRC" -ne 0 ]; then ok subset-fail-exit-nonzero
  else bad subset-fail-exit-nonzero "planted FAIL=1 subset exited 0"; fi
  if printf '%s\n' "$NOUT" | tail -1 | grep -qE '^PASS=[0-9][0-9]* FAIL=1$'; then
    ok subset-fail-aggregate
  else
    bad subset-fail-aggregate "last line [$(printf '%s\n' "$NOUT" | tail -1)] want FAIL=1"
  fi
  if printf '%s\n' "$NERR" | grep -qF -- 'FAIL: AC7: empty-file: planted'; then
    ok subset-fail-attributed
    printf '%s\n' "$NERR"
  else
    bad subset-fail-attributed "nested stderr [$(printf '%s\n' "$NERR" | head -1)]"
  fi
  expect_usage usage-bare-ac      "$TC" --ac
  expect_usage usage-ac-letters   "$TC" --ac AC
  expect_usage usage-ac-foo       "$TC" --ac foo
  expect_usage usage-ac-zero      "$TC" --ac AC0
  expect_usage usage-zero-match   "$TC" --ac AC99
  expect_usage usage-unknown-flag "$TC" --bogus
  expect_usage usage-leftover     "$TC" --ac AC7 extra
  expect_usage router-usage-zero-match "$RS" --ac AC99
  expect_usage router-usage-bare-ac    "$RS" --ac
  run_nested "$RS" --ac AC12
  expect_rc router-subset-ac12-exit-0 0
  if printf '%s\n' "$NOUT" | grep -q '^ok AC12: '; then
    ok router-subset-ac12-receipts
  else
    bad router-subset-ac12-receipts "no AC12 receipt: [$(_flat "$NOUT")]"
  fi
  # Template exhibit (pass-5 AC3 strike): the AC names the aggregate form
  # `PASS=<n> FAIL=<m>`; echo it literal beside the observed instance.
  printf 'aggregate template: %s\n' 'PASS=<n> FAIL=<m>'
  printf 'aggregate instance: %s\n' "$(printf '%s\n' "$NOUT" | tail -1)"
fi

# ---- AC4: the C1 strike list is covered, filter >=1 per id ----------------
set_ac AC4
if want_ac; then
  # Section-token exhibit: the `### CDT-589-C1` heading, located raw.
  grep -n '^### CDT-589-C1$' "$ROOT/specs/core/SPEC-009-ticket-workflow.md" \
    | sed 's/^/section-heading: /'
  for n in 1 2 3 4 5 6 7 8 9 10 11 13 14; do
    run_nested "$TC" --ac "AC$n"
    if [ "$NRC" = 0 ] && printf '%s\n' "$NOUT" | grep -q "^ok AC$n: "; then
      ok "filter-ac$n"
    else
      bad "filter-ac$n" "ticket-class-test.sh --ac AC$n rc=$NRC out=[$(_flat "$NOUT")] err=[$(_flat "$NERR")]"
    fi
  done
  # AC12 is the dual-home clause: it lives in router-static, so ticket-class
  # must reject it as a zero-match id, never run it green.
  run_nested "$TC" --ac AC12
  expect_rc ac12-zero-match-in-ticket-class 64
  run_nested "$RS" --ac AC12
  expect_rc ac12-router-exit-0 0
  aggregate_is_ok_count ac12-router-count-equals-pass "$NOUT"
  # C1 AC14 cross-reference exhibits: the router's T25 receipt and the uid-0
  # skip-arm, echoed raw (pass-4: these arms were asserted, not exhibited).
  run_nested "$RS" --ac AC14
  printf 'router T25: %s\n' "$(printf '%s\n' "$NOUT" | grep -F 'T25' | head -1)"
  # Pass-7: the cross-ref rides a named receipt, not only the echo line.
  if printf '%s\n' "$NOUT" | grep -qF -- 'ok AC14: T25 word-boundary'; then
    ok ac14-router-crossref
  else
    bad ac14-router-crossref "router --ac AC14 log lacks T25: [$(printf '%s\n' "$NOUT" | tail -1)]"
  fi
  printf 'uid exhibit: host id -u=%s fakeroot id -u=%s\n' "$(id -u)" \
    "$(fakeroot id -u 2>/dev/null || echo unavailable)"
  printf 'fakeroot AC7 skip-arm: %s\n' \
    "$(fakeroot bash "$TC" --ac AC7 2>&1 | grep -F 'skip AC7: mode-000 uid0' | head -1)"

  run_nested "$TC" --ac AC7
  for s in scan-tool-failure mode-000 no-file empty-file no-terms header-only \
           empty-col1 non-pipe-row missing-path directory-path non-ascii-term; do
    has_receipt "ac7-$s" "$NOUT" AC7 "$s"
  done

  if command -v git >/dev/null 2>&1; then
    run_nested "$TC" --ac AC9
    for s in wtroot-beats-mroot mroot-beats-mdoc docs-domain-fallback plugin-never; do
      has_receipt "ac9-$s" "$NOUT" AC9 "$s"
    done
  else
    # Same host limit as the nested suite: the AC9 fixtures need git.
    skip_ac ac9-git-absent
  fi

  run_nested "$TC" --ac AC11
  for s in carve-line-present zero-carve-silence stdout-exit-unchanged; do
    has_receipt "ac11-$s" "$NOUT" AC11 "$s"
  done

  run_nested "$TC" --ac AC13
  for s in portability-grep determinism perf-2s; do
    has_receipt "ac13-$s" "$NOUT" AC13 "$s"
  done
fi

# ---- AC5: perf-case scope and fixture-size exhibits -----------------------
# Pass-8 strikes: the 100-row glossary loop was source-only, and "runs only
# under --ac AC13" had no non-AC13 run exhibit. Both become run receipts.
set_ac AC5
if want_ac; then
  run_nested "$TC"
  expect_rc ac5-full-run-green 0
  PC=$(printf '%s\n' "$NOUT" | grep -c 'AC13: perf-2s' || true)
  printf 'full-run perf-2s line count=%s (clause: perf case runs only under --ac AC13)\n' "$PC"
  if [ "$PC" = "0" ]; then ok perf-absent-in-full-run
  else bad perf-absent-in-full-run "bare full run printed $PC perf-2s lines"; fi
  run_nested "$TC" --ac AC13
  expect_rc ac5-ac13-run-green 0
  PL=$(printf '%s\n' "$NOUT" | grep -E '^ok AC13: perf-2s' | head -1)
  if [ -n "$PL" ]; then ok perf-present-under-ac13
  else bad perf-present-under-ac13 "no perf-2s receipt under --ac AC13"; fi
  [ -n "$PL" ] && printf 'AC13 run: %s\n' "$PL"
  RL=$(printf '%s\n' "$NOUT" | grep -E '^perf-fixture:' | head -1)
  case "$RL" in
    'perf-fixture: glossary term rows=100 ticket bytes='*) ok perf-fixture-counts-echoed ;;
    *) bad perf-fixture-counts-echoed "fixture echo missing or term rows!=100 [$RL]" ;;
  esac
  [ -n "$RL" ] && printf '%s\n' "$RL"
fi

# ---- AC6: the uid-0 skip is a receipt, a pass, and a SKIP: ban ------------
set_ac AC6
if want_ac; then
  run_nested "$TC" --ac AC7
  expect_rc ac7-run-green 0
  BOTH="$NOUT
$NERR"
  if [ "$(id -u)" = "0" ]; then
    has_line skip-line-present "$NOUT" 'skip AC7: mode-000 uid0'
  else
    hasnt_line skip-line-absent "$NOUT" 'skip AC7: mode-000'
    has_line mode-000-check-ran "$NOUT" 'ok AC7: mode-000'
  fi
  hasnt_line no-skip-cap "$BOTH" 'SKIP:'
  hasnt_line no-fail-line "$BOTH" 'FAIL: AC7:'
  aggregate_is_ok_count skip-not-counted "$NOUT"
  # The root arm needs uid 0. fakeroot simulates it for the suite's own
  # `id -u` guard: the nested AC7 run takes the skip branch, and that skip
  # line is the receipt AC6 names. No bwrap reliance: setuid bwrap on this
  # box keeps the caller uid.
  if command -v fakeroot >/dev/null 2>&1; then
    FRC=0
    FRLOG=$(fakeroot bash "$TC" --ac AC7 2>/dev/null) || FRC=$?
    if printf '%s\n' "$FRLOG" | grep -qF -- 'skip AC7: mode-000 uid0'; then
      ok uid0-skip-arm-exhibited
      printf '%s\n' "$FRLOG" | grep -F -- 'skip AC7: mode-000'
      aggregate_is_ok_count uid0-skip-not-counted "$FRLOG"
    else
      bad uid0-skip-arm-exhibited "fakeroot AC7 run rc=$FRC [$(printf '%s\n' "$FRLOG" | grep -E 'mode-000|PASS=' | tr '\n' '|')]"
    fi
  else
    skip_ac uid0-skip-arm-no-fakeroot
  fi
fi

# ---- AC7: consumer compat, labeled against the C1 HEAD --------------------
set_ac AC7
if want_ac; then
  run_nested "$TC"
  expect_rc consumer-full-run-green 0
  if printf '%s\n' "$NOUT" | tail -1 | grep -qE '^PASS=[0-9][0-9]* FAIL=0$'; then
    ok consumer-aggregate-last-line
  else
    bad consumer-aggregate-last-line "last line [$(printf '%s\n' "$NOUT" | tail -1)]"
  fi
  expect_usage usage-ac99-preserved "$TC" --ac AC99
  SUBJ=$(git -C "$ROOT" log -1 --format=%s faa0249 2>/dev/null)
  if printf '%s' "$SUBJ" | grep -qF -- 'CDT-589-C1'; then
    ok c1head-label-exhibit
    printf 'faa0249 = C1 HEAD: %s\n' "$SUBJ"
  else
    bad c1head-label-exhibit "faa0249 subject [$SUBJ] does not name CDT-589-C1"
  fi
  if [ -z "$(git -C "$ROOT" diff --name-only faa0249..HEAD -- skills/orchestrate/ticket-class.sh 2>/dev/null)" ]; then
    ok classifier-untouched-c1head
  else
    bad classifier-untouched-c1head "ticket-class.sh changed vs faa0249"
  fi
  CHANGED=$(git -C "$ROOT" diff --name-only faa0249..HEAD 2>/dev/null)
  # Fold-aware allowlist: a /release fold rides the version pair in the same
  # single commit — bookkeeping paths, not product code.
  OUTSIDE=$(printf '%s\n' "$CHANGED" | grep -vE '^skills/orchestrate/[a-z0-9-]*-test\.sh$|^specs/|^tests/lib/|^CHANGELOG\.md$|^\.claude-plugin/plugin\.json$')
  if [ -z "$OUTSIDE" ] && [ -n "$CHANGED" ]; then
    ok suite-only-vs-c1head
    printf 'faa0249..HEAD paths:\n'
    printf '%s\n' "$CHANGED" | sed 's/^/  /'
  else
    bad suite-only-vs-c1head "non-suite path: [$(printf '%s\n' "$OUTSIDE" | head -1)]"
  fi
  # Portable-lane touch-set (AC7 scope): the three suites this ticket's lane
  # covers, run bare exactly as the runner invokes them. The repo-wide lane
  # is a CI surface — under parallel investigator load its foreign
  # timing-sensitive suites flake, and a foreign flake is not AC7 evidence.
  LANE_RC=0
  bash "$ROOT/skills/orchestrate/ticket-class-test.sh" >/dev/null 2>&1 || LANE_RC=1
  bash "$ROOT/skills/orchestrate/router-static-test.sh" >/dev/null 2>&1 || LANE_RC=1
  if [ "$LANE_RC" = 0 ]; then
    ok portable-lane-exit-0
    printf 'lane bare runs: ticket-class-test rc=0 router-static-test rc=0\n'
    # Token exhibit: tools/run-all-tests.sh discovers the lane suites; its
    # --list output names the repo-relative paths the runner bare-runs.
    printf 'runner form: bash tools/run-all-tests.sh --list (cwd repo root)\n'
    (cd "$ROOT" && bash tools/run-all-tests.sh --list 2>/dev/null) \
      | grep -E '^skills/orchestrate/(ticket-class|router-static)-test\.sh$' \
      | sed 's/^/  discovered: /'
  else
    bad portable-lane-exit-0 "lane bare run rc=1 (ticket-class-test / router-static-test)"
  fi
fi

# ---- AC8: the T1 spike, and the investigator filter on a real log ---------
set_ac AC8
if want_ac; then
  LINE=$(grep -nF -- "$PIN" "$INV" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$LINE" ]; then ok spike-regex-extract
  else bad spike-regex-extract "AC_LABEL template absent from $INV"; fi
  if [ "${LINE:-none}" = "130" ]; then ok spike-regex-anchor
  else bad spike-regex-anchor "AC_LABEL moved off investigator.md:130 (found at ${LINE:-nowhere})"; fi
  NX=$(printf '%s' "$PIN" | tr -cd 'X' | wc -c | tr -d ' ')
  if [ "$NX" = "3" ]; then ok spike-regex-arity
  else bad spike-regex-arity "template holds $NX X tokens, expected 3"; fi

  # AC8 temporal clause (pass-7 strike: no git-run exhibit): the T1 spike
  # commit is an ancestor of the spec commit that locks the label format.
  # Fold-aware fallback: a /release fold squashes branch history, so when
  # HEAD's log lacks the pair, search the full ref graph (the pushed
  # feature branch retains it) before failing.
  # Newest matching pair: stale pre-rebase lineages may still be reachable
  # via old refs, and only the current lineage's ordering is evidence.
  SPIKE=$(git -C "$ROOT" log --format='%H %s' 2>/dev/null | grep -E 'CDT-595-T1 ' | head -1)
  SPECC=$(git -C "$ROOT" log --format='%H %s' 2>/dev/null | grep -F 'per-AC run receipts' | head -1)
  if [ -z "$SPIKE" ] || [ -z "$SPECC" ]; then
    SPIKE=$(git -C "$ROOT" log --all --format='%H %s' 2>/dev/null | grep -E 'CDT-595-T1 ' | head -1)
    SPECC=$(git -C "$ROOT" log --all --format='%H %s' 2>/dev/null | grep -F 'per-AC run receipts' | head -1)
  fi
  if [ -n "$SPIKE" ] && [ -n "$SPECC" ] \
     && git -C "$ROOT" merge-base --is-ancestor "${SPIKE%% *}" "${SPECC%% *}"; then
    ok spike-precedes-spec
    printf 'spike commit: %s\nspec commit:  %s\n' "$SPIKE" "$SPECC"
    printf 'spike parent: %s\n' "$(git -C "$ROOT" log -1 --format='%h %s' "${SPIKE%% *}^" 2>/dev/null)"
  else
    bad spike-precedes-spec "spike/spec commits not found in order (spike=[$SPIKE] spec=[$SPECC])"
  fi

  SAMP="$WORK/spike-sample.log"
  cat > "$SAMP" <<'EOF'
ok AC7: scan-tool-failure
ok AC7 scan-tool-failure
FAIL: AC7: empty-file: planted
skip AC7: mode-000 uid0
SKIP: ticket-class-test.sh: root uid: mode 000
ok AC13: perf-2s 0s
EOF
  if [ ! -s "$SAMP" ]; then
    bad spike-sample-write "no sample log at $SAMP"
  else
    probe AC7 1 1 spike-colon          # colon receipt
    probe AC7 2 0 spike-space-miss     # no colon, so alt-2 and alt-3 cannot fire
    probe AC7 3 1 spike-fail-line      # FAIL: receipt carries its AC id
    probe AC7 4 1 spike-skip-line      # skip receipt
    probe AC7 5 0 spike-skipcap-miss   # SKIP: line carries no AC id
    probe AC13 6 1 spike-perf13        # perf receipt under X=AC13
    # Plan R4: alt-2 `[0-9]*` lets X=AC1 match AC11 on a full log. The `--ac`
    # run filter is exact-id, so a per-AC Verify log stays exclusive.
    if sed -n '6p' "$SAMP" | grep -qE -- "$(label_re AC1)"; then
      ok spike-ac1-prefix
    else
      bad spike-ac1-prefix "X=AC1 must match the AC13 line (documented R4 leak)"
    fi
    probe AC13 6 1 spike-ac13-own
    probe AC14 6 0 spike-ac14-miss
  fi
  rm -f "$SAMP"

  # Filter >=1 per technical AC of the C1 list, on the real full-suite stdout.
  run_nested "$TC"
  expect_rc full-run-green 0
  for n in 1 2 3 4 5 6 7 8 9 10 11 13 14; do
    cnt=$(printf '%s\n' "$NOUT" | grep -Ec -- "$(label_re "AC$n")")
    if [ "$cnt" -ge 1 ]; then
      ok "cover-ac$n"
    else
      bad "cover-ac$n" "filter X=AC$n returns $cnt lines from the full-suite log"
    fi
  done
  # The AC8 clause also binds the slug charset: nothing on a receipt line may
  # break the filter's boundary class [^A-Za-z0-9_].
  OFFENDERS=$(printf '%s\n' "$NOUT" | grep '^ok ' | grep -vE '^ok AC[0-9]+: [A-Za-z0-9][A-Za-z0-9 ._-]*$')
  if [ -n "$OFFENDERS" ]; then
    bad ok-slug-charset "a receipt line holds a char outside [A-Za-z0-9 ._-]: [$(printf '%s\n' "$OFFENDERS" | head -1)]"
  else
    ok ok-slug-charset
  fi
  aggregate_is_ok_count full-run-count-equals-pass "$NOUT"
fi

# ---- AC9: the C1 Verify repoint, and the spec-lint baseline --------------
# expected_verify <AC-id> — the one two-space continuation that bullet holds.
expected_verify() {
  case "$1" in
    AC12) printf '  Verify: bash skills/orchestrate/router-static-test.sh --ac AC12\n' ;;
    *)    printf '  Verify: bash skills/orchestrate/ticket-class-test.sh --ac %s\n' "$1" ;;
  esac
}

# c1_verify_lines <AC-id> — every `  Verify:` continuation inside that
# `### CDT-589-C1` bullet. Literal compares: index(), not a built regex.
c1_verify_lines() {
  awk -v id="$1" '
    /^### CDT-589-C1$/       { inside=1; next }
    inside && /^### /        { inside=0 }
    !inside                  { next }
    index($0, "- **" id ".") == 1 { on=1; next }
    on && substr($0, 1, 4) == "- **"   { on=0 }
    on && substr($0, 1, 10) == "  Verify: " { print }
  ' "$SPEC"
}

set_ac AC9
if want_ac; then
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    id="AC$n"
    slug="verify-ac$n"   # lowercase: a slug that embeds `AC1` is one filter hit
    got=$(c1_verify_lines "$id")
    want=$(expected_verify "$id")
    cnt=$(_lines "$got")
    if [ "$cnt" -ne 1 ]; then
      bad "$slug" "bullet holds $cnt Verify lines want=1: [$(_flat "$got")]"
    elif [ "$got" != "${want%$'\n'}" ]; then
      bad "$slug" "Verify line is [$got] want [$want]"
    else
      ok "$slug"
    fi
  done
  # M14(g) legality receipt (pass-6 AC9 strike): every C1 Verify line's
  # command and args hold only the SPEC-033 M14(g) charset. Check + echo.
  M14G_BADLINES=$(for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    c1_verify_lines "AC$n"
  done | sed 's/^  Verify: //' | grep -vE '^bash [A-Za-z0-9._/=@%+,-]+( [A-Za-z0-9._/=@%+,-]+)*$' || true)
  if [ -z "$M14G_BADLINES" ]; then
    ok m14g-verify-charset
  else
    bad m14g-verify-charset "Verify line outside the M14(g) charset: [$(printf '%s\n' "$M14G_BADLINES" | head -1)]"
  fi
  printf 'm14g exhibit: 14 Verify lines checked, illegal=%s, sample=[%s]\n' \
    "$(_lines "$M14G_BADLINES")" \
    "$(c1_verify_lines AC13 | sed 's/^  Verify: //')"
  LRC=0
  LINT_OUT=$( (cd "$ROOT" && bash "$LINT") 2>&1 ) || LRC=$?
  printf 'lint head CMD: (cd %s && bash %s)\n' "$ROOT" "$LINT"
  printf 'lint head CMD exit=%s\n' "$LRC"
  if [ "$LRC" -eq 1 ]; then
    ok speclint-rc-baseline
  else
    bad speclint-rc-baseline "spec-lint rc=$LRC — the findings set moved off the faa0249 baseline (expect 1: specs/OWNERS plus SPEC-038 [history])"
  fi
  if printf '%s\n' "$LINT_OUT" | grep -qF -- 'SPEC-009'; then
    bad speclint-no-spec009 "new finding touches the spec: [$(printf '%s\n' "$LINT_OUT" | grep -F -- 'SPEC-009' | head -1)]"
  else
    ok speclint-no-spec009
  fi
  # Findings-SET equality, not rc equality: run the linter on a pinned
  # archive of the stack base and diff the sorted finding lines byte-for-byte.
  mkdir -p "$WORK/base"
  if git -C "$ROOT" archive faa0249 2>/dev/null | tar -x -C "$WORK/base" 2>/dev/null \
     && [ -f "$WORK/base/tools/spec-lint.sh" ]; then
    # The linter's file discovery is git-backed; give the archive the same
    # tracked context, or the scan sets differ for a non-semantic reason.
    git -C "$WORK/base" init -q . >/dev/null 2>&1
    git -C "$WORK/base" add -A >/dev/null 2>&1
    BR=0
    BASE_OUT=$( (cd "$WORK/base" && bash tools/spec-lint.sh) 2>&1 ) || BR=$?
    printf 'lint base CMD: (cd %s && bash tools/spec-lint.sh)\n' "$WORK/base"
    printf 'lint base CMD exit=%s\n' "$BR"
    HSET=$(printf '%s\n' "$LINT_OUT" | LC_ALL=C sort)
    BSET=$(printf '%s\n' "$BASE_OUT" | LC_ALL=C sort)
    if [ -n "$BASE_OUT" ] && [ "$HSET" = "$BSET" ]; then
      ok speclint-findings-set-equal
      printf 'HEAD vs faa0249 spec-lint: identical finding lines (%s)\n' "$(printf '%s\n' "$LINT_OUT" | tail -1)"
      # Findings-set exhibit (pass-6 AC9 strike): the compare predicate,
      # made observable. Show each side's sorted finding lines plus a
      # checksum, so equality is witnessed, not asserted.
      printf 'findings-set head_cksum=%s base_cksum=%s equal=%s\n' \
        "$(printf '%s\n' "$HSET" | cksum | tr ' ' ':')" \
        "$(printf '%s\n' "$BSET" | cksum | tr ' ' ':')" \
        "$([ "$HSET" = "$BSET" ] && echo yes || echo no)"
      printf 'findings-set head:\n%s\nfindings-set base:\n%s\n' "$HSET" "$BSET"
      # Pass-8 strike: the compare predicate itself was never printed, so the
      # judge inferred the rule. Echo it verbatim from this suite's source.
      printf 'findings-set compare rule (this suite, verbatim):\n'
      sed -n '/^ *HSET=\$(printf/,/^ *BSET=\$(printf/p' "$HERE/ticket-class-receipts-test.sh"
      grep -nF -- '[ "$HSET" = "$BSET" ]' "$HERE/ticket-class-receipts-test.sh"
    else
      bad speclint-findings-set-equal "rc head=$LRC base=$BR; head lines=$(_lines "$LINT_OUT") base lines=$(_lines "$BASE_OUT")"
    fi
    # Criterion-text equality: the C1 section with its `  Verify:`
    # continuations removed is byte-equal to the base — the repoint is the
    # only edit inside `### CDT-589-C1`.
    c1_body() {
      awk '/^### CDT-589-C1$/{i=1;next} i&&/^### /{i=0} i && substr($0,1,9)!="  Verify:"' "$1"
    }
    HEADC1=$(c1_body "$SPEC")
    BASEC1=$(c1_body "$WORK/base/specs/core/SPEC-009-ticket-workflow.md")
    if [ -n "$BASEC1" ] && [ "$HEADC1" = "$BASEC1" ]; then
      ok c1-criterion-text-untouched
    else
      bad c1-criterion-text-untouched "C1 section body differs vs faa0249 (head $(_lines "$HEADC1"), base $(_lines "$BASEC1"))"
    fi
    # Pass-7 AC9 raw exhibit: the investigator's own slice — the section
    # including its heading, `  Verify:` lines dropped — must diff clean
    # against faa0249 with NO command-substitution trimming. rc=0 is the
    # receipt; the numerals echo so the equality is witnessed, not asserted.
    sec_c1() { awk 'f&&/^### /{exit} /^### CDT-589-C1$/{f=1} f' "$1"; }
    RAWRC=0
    diff <(sec_c1 "$SPEC" | grep -v '^  Verify:') \
      <(git -C "$ROOT" show faa0249:specs/core/SPEC-009-ticket-workflow.md \
          | sec_c1 /dev/stdin | grep -v '^  Verify:') >/dev/null 2>&1 || RAWRC=$?
    if [ "$RAWRC" -eq 0 ]; then
      ok c1-raw-section-diff-clean
      printf 'raw-diff exhibit: rc=0, head_lines=%s base_lines=%s\n' \
        "$(sec_c1 "$SPEC" | grep -v '^  Verify:' | wc -l | tr -d ' ')" \
        "$(git -C "$ROOT" show faa0249:specs/core/SPEC-009-ticket-workflow.md \
            | sec_c1 /dev/stdin | grep -v '^  Verify:' | wc -l | tr -d ' ')"
    else
      bad c1-raw-section-diff-clean "stripped-section raw diff rc=$RAWRC"
    fi
    # Pass-9 AC9 strike: a council mirror (git-initialized faa0249 archive)
    # linted a smaller set than the block above — spec-lint's M14 gate keys
    # on git metadata at the lint root, so an ungitted extraction drops the
    # [m14-ac] WARN lines. Make the pair condition-identical: mirror HEAD
    # and faa0249 each as a fresh git-initialized archive tree, lint both
    # with the same command, and echo each CMD, exit, and sorted set.
    mkdir -p "$WORK/mirror/head" "$WORK/mirror/base"
    PRC=0
    git -C "$ROOT" archive HEAD    | tar -x -C "$WORK/mirror/head" || PRC=$?
    git -C "$ROOT" archive faa0249 | tar -x -C "$WORK/mirror/base" || PRC=$?
    for side in head base; do
      git -C "$WORK/mirror/$side" init -q . >/dev/null 2>&1 || PRC=$?
      git -C "$WORK/mirror/$side" add -A    >/dev/null 2>&1 || PRC=$?
    done
    if [ "$PRC" = 0 ] && [ -f "$WORK/mirror/head/tools/spec-lint.sh" ]; then
      MHR=0
      MHC=$( (cd "$WORK/mirror/head" && bash tools/spec-lint.sh) 2>&1 ) || MHR=$?
      printf 'mirror head CMD: (cd %s && bash tools/spec-lint.sh)\n' "$WORK/mirror/head"
      printf 'mirror head CMD exit=%s\n' "$MHR"
      MBR=0
      MBC=$( (cd "$WORK/mirror/base" && bash tools/spec-lint.sh) 2>&1 ) || MBR=$?
      printf 'mirror base CMD: (cd %s && bash tools/spec-lint.sh)\n' "$WORK/mirror/base"
      printf 'mirror base CMD exit=%s\n' "$MBR"
      MHSET=$(printf '%s\n' "$MHC" | LC_ALL=C sort)
      MBSET=$(printf '%s\n' "$MBC" | LC_ALL=C sort)
      printf 'mirror head_cksum=%s base_cksum=%s equal=%s\n' \
        "$(printf '%s\n' "$MHSET" | cksum | tr ' ' ':')" \
        "$(printf '%s\n' "$MBSET" | cksum | tr ' ' ':')" \
        "$([ "$MHSET" = "$MBSET" ] && echo yes || echo no)"
      if [ -n "$MHC" ] && [ "$MHSET" = "$MBSET" ]; then
        ok speclint-archive-pair-equal
      else
        bad speclint-archive-pair-equal "mirror lint sets differ (rc head=$MHR base=$MBR)"
      fi
    else
      skip_ac speclint-archive-pair-equal
    fi
  else
    bad speclint-findings-set-equal "no faa0249 archive tree"
    skip_ac c1-criterion-text-untouched
  fi
fi

ac_finish
