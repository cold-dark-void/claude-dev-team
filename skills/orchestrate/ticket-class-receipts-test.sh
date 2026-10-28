#!/usr/bin/env bash
# ticket-class-receipts-test.sh — CDT-595 per-AC receipt meta-suite
# (SPEC-009 § CDT-595). Receipts about receipts: every case runs a labeled
# suite as a nested subprocess and asserts the shape the M14 per-AC
# investigator depends on.
#
#   AC2  force-fail hook: a planted failure gives a non-zero nested exit and
#        the `FAIL: AC<n>: <slug>: planted` shape on stderr
#   AC3  the `--ac` grammar on both suites: a subset run exits 0 with its
#        receipts, every malformed form exits 64 with one usage line
#   AC4  every technical C1 AC filter runs green on the suite that owns it,
#        and each C1 strike-list slug shows its own receipt
#   AC6  the uid-0 mode-000 skip: `skip AC7:`, never `SKIP:`, counted by
#        neither counter
#   AC8  the T1 spike (investigator <AC_LABEL> template, colon form) plus a
#        >=1-line filtered receipt per technical AC of a real full-suite log
#   AC9  the `### CDT-589-C1` Verify repoint, and spec-lint baseline equality
#
# Nested targets are ticket-class-test.sh, router-static-test.sh and
# tools/spec-lint.sh only. This suite never invokes itself, so a nested
# `--ac AC2` cannot recurse into its own case.
#
# AC9 is findings-set baseline equality, not rc 0: tools/spec-lint.sh exits 1
# on master, on the stack base fbbe657, and here, from two pre-existing
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
  NOUT=$(bash "$target" "$@" 2>"$WORK/err") || NRC=$?
  NERR=$(cat "$WORK/err" 2>/dev/null)
}

# run_nested_env <VAR=value> <target> [args...] — same, with one export.
run_nested_env() {
  local kv=$1 target=$2; shift 2
  NRC=0
  NOUT=$(env "$kv" bash "$target" "$@" 2>"$WORK/err") || NRC=$?
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
  if printf '%s\n' "$NERR" | grep -qF -- 'FAIL: AC14: base-auth: planted'; then
    ok fail-hook-stderr-shape
    # Replay the nested stderr onto this suite's stdout, so the AC2 Verify log
    # carries the FAIL: shape the investigator reads. A dead stdout is a dead
    # suite: nothing downstream can report.
    printf '%s\n' "$NERR" || exit 1
  else
    bad fail-hook-stderr-shape "nested stderr [$(_flat "$NERR")]"
  fi
  hasnt_exact "fail-hook-ok-suppressed" "$NOUT" 'ok AC14: base-auth'
  if printf '%s\n' "$NOUT" | tail -1 | grep -qE '^PASS=[0-9][0-9]* FAIL=1$'; then
    ok fail-hook-aggregate
  else
    bad fail-hook-aggregate "nested aggregate [$(printf '%s\n' "$NOUT" | tail -1)] want FAIL=1"
  fi
  ok labeled-failure
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
fi

# ---- AC4: the C1 strike list is covered, filter >=1 per id ----------------
set_ac AC4
if want_ac; then
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
  LRC=0
  LINT_OUT=$( (cd "$ROOT" && bash "$LINT") 2>&1 ) || LRC=$?
  if [ "$LRC" -eq 1 ]; then
    ok speclint-rc-baseline
  else
    bad speclint-rc-baseline "spec-lint rc=$LRC — the findings set moved off the fbbe657 baseline (expect 1: specs/OWNERS plus SPEC-038 [history])"
  fi
  if printf '%s\n' "$LINT_OUT" | grep -qF -- 'SPEC-009'; then
    bad speclint-no-spec009 "new finding touches the spec: [$(printf '%s\n' "$LINT_OUT" | grep -F -- 'SPEC-009' | head -1)]"
  else
    ok speclint-no-spec009
  fi
fi

ac_finish
