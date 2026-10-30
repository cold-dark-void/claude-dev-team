#!/usr/bin/env bash
# WP 1-15 AC H — finalize report shows claim id + text (SPEC-033 M14(g)).
# Fixtures: skills/council/fixtures/finalize-claim-ids/
# Hermetic: hermetic_init (private TMPDIR/HOME) + isolated temp git repo;
# no live .claude/ writes.
#
# CDT-589-C4 per-AC run receipts (SPEC-013 § CDT-589-C4, CDT-595 pattern):
# the WP 1-15 base cases keep their `OK:`/`FAIL:` prose and stay outside the
# receipt economy; AC5/AC7/AC8 run the Forward claim fixture matrix
# (test-forward-claim.sh) filtered to each AC and re-exhibit its non-ok lines
# verbatim. `--ac AC<n>` prints that AC's subset aggregate as the last stdout
# line (`PASS=<n> FAIL=<m>`, exit 0 iff m=0); the count of `^ok ` lines
# equals n.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/ac-receipt.sh
. "$ROOT/tests/lib/ac-receipt.sh"
hermetic_init
parse_ac_args "$@"
PASS=0
FAIL=0

ENGINE="$ROOT/skills/council/engine.sh"
FIX="$ROOT/skills/council/fixtures/finalize-claim-ids"
fail=0
pass=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/finalize-claim-ids.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"

# slugify <label> — receipt slug from a prose label ([a-z0-9-] only).
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9-]\{1,\}/-/g' -e 's/^-\{1,\}//' -e 's/-\{1,\}$//'
}
ok() {
  echo "OK: $1"
  # Receipt only for checks inside a set_ac block (the AC5/AC7/AC8 nested
  # exhibits); the WP 1-15 base cases stay prose-only.
  if [ -n "${CUR_AC:-}" ] && want_ac; then
    PASS=$(( PASS + 1 ))
    printf 'ok %s: %s\n' "$CUR_AC" "$(slugify "$1")"
  fi
}
fail_msg() {
  echo "FAIL: $1"
  fail=$(( fail + 1 ))
  if [ -n "${CUR_AC:-}" ] && want_ac; then
    FAIL=$(( FAIL + 1 ))
    printf 'FAIL: %s: %s: %s\n' "$CUR_AC" "$(slugify "$1")" failed >&2
  fi
}
grep_file() {  # grep_file <label> <pattern> <file>
  if grep -qF -- "$2" "$3"; then ok "$1"; else fail_msg "$1 (missing: $2)"; fi
}
ngrep_file() {  # ngrep_file <label> <pattern> <file>
  if grep -qF -- "$2" "$3"; then fail_msg "$1 (present: $2)"; else ok "$1"; fi
}

# ---- Case 1: M14 run, verdicts carry no claim_id, single claim ---------------
REPORT1="$TMP/m14-single.md"
META1="${REPORT1}.finalize-meta.json"
RC1=0
bash "$ENGINE" finalize \
  --plan-file "$FIX/plan-m14-single.json" \
  --evidence-file "$FIX/evidence-m14-single.json" \
  --judge-output "$FIX/judge-m14-single.json" \
  --report-out "$REPORT1" >"$TMP/m14-single.stdout" 2>&1 || RC1=$?
if [ "$RC1" -eq 0 ]; then ok "1 m14-single finalize exit 0"; else
  fail_msg "1 m14-single finalize exit $RC1"; cat "$TMP/m14-single.stdout"
fi
grep_file "1 heading shows c0 + AC-A text" \
  '### Claim c0: [AC-A] For CDT-FIX, the diff from the merge-base' "$REPORT1"
if grep -qF 'Claim ?' "$REPORT1"; then
  fail_msg "1 report has Claim ? placeholder"
else
  ok "1 no Claim ? placeholder"
fi
grep_file "1 Extracted Claims lists claim id + text" \
  '1. **factual** — c0: [AC-A] For CDT-FIX, the diff from the merge-base' "$REPORT1"

# ---- Case 2: single-claim scope; verdict lacks id; heading = scope_arg text --
REPORT2="$TMP/single-claim-scope.md"
RC2=0
bash "$ENGINE" finalize \
  --plan-file "$FIX/plan-single-claim-scope.json" \
  --evidence-file "$FIX/evidence-single-claim-scope.json" \
  --judge-output "$FIX/judge-single-claim-scope.json" \
  --report-out "$REPORT2" >"$TMP/single-claim-scope.stdout" 2>&1 || RC2=$?
if [ "$RC2" -eq 0 ]; then ok "2 single-claim-scope finalize exit 0"; else
  fail_msg "2 single-claim-scope finalize exit $RC2"; cat "$TMP/single-claim-scope.stdout"
fi
grep_file "2 heading shows plan.scope_arg text" \
  '### Claim c0: Fix the widget renderer to handle null input.' "$REPORT2"
ngrep_file "2 heading does not show evidence placeholder text" \
  '### Claim c0: (see plan.scope_arg)' "$REPORT2"
if grep -qF 'Claim ?' "$REPORT2"; then
  fail_msg "2 report has Claim ? placeholder"
else
  ok "2 no Claim ? placeholder"
fi

# ---- Case 3: multi-claim M14; one verdict unmatched --------------------------
REPORT3="$TMP/m14-multi.md"
META3="${REPORT3}.finalize-meta.json"
RC3=0
bash "$ENGINE" finalize \
  --plan-file "$FIX/plan-m14-multi.json" \
  --evidence-file "$FIX/evidence-m14-multi.json" \
  --judge-output "$FIX/judge-m14-multi-unmatched.json" \
  --report-out "$REPORT3" >"$TMP/m14-multi.stdout" 2>&1 || RC3=$?
if [ "$RC3" -eq 0 ]; then ok "3 m14-multi finalize exit 0"; else
  fail_msg "3 m14-multi finalize exit $RC3"; cat "$TMP/m14-multi.stdout"
fi
grep_file "3 matched verdict heading shows c0" \
  '### Claim c0: [AC-A] For CDT-FIX' "$REPORT3"
grep_file "3 unmatched verdict heading" \
  '### Claim unmatched: a stray verdict with no matching claim text' "$REPORT3"
if grep -qF 'Claim ?' "$REPORT3"; then
  fail_msg "3 report has Claim ? placeholder"
else
  ok "3 no Claim ? placeholder"
fi

# ---- Case 4: sidecar unstruck_verdicts byte-equal to pre-change shape --------
# The sidecar copies v.get("claim","") raw -- it must NOT gain the resolved
# claim_id/text engine.sh now renders into the report body (contract: the
# mapper input in ship-gate-verdict.sh is unchanged by this WP).
if jq -e '.unstruck_verdicts[0].claim == ""' "$META1" >/dev/null 2>&1; then
  ok "4 m14-single sidecar keeps raw (empty) claim text, not c0's resolved text"
else
  fail_msg "4 m14-single sidecar claim text changed"
  jq -c '.unstruck_verdicts' "$META1" 2>/dev/null || true
fi
if jq -e '.unstruck_verdicts[1].claim == "a stray verdict with no matching claim text"' "$META3" >/dev/null 2>&1; then
  ok "4 m14-multi sidecar keeps raw unmatched claim text, not relabeled"
else
  fail_msg "4 m14-multi sidecar claim text changed"
  jq -c '.unstruck_verdicts' "$META3" 2>/dev/null || true
fi

# ---- Case 5: verdict claim_id "?" is treated as absent (TL rework F5) -------
# workflow.js can emit claim_id '?' in a degraded brief, and a judge can
# echo it verbatim. It must never reach the report as "### Claim ?:".
REPORT5="$TMP/claim-id-question-mark.md"
RC5=0
bash "$ENGINE" finalize \
  --plan-file "$FIX/plan-m14-multi.json" \
  --evidence-file "$FIX/evidence-m14-multi.json" \
  --judge-output "$FIX/judge-claim-id-question-mark.json" \
  --report-out "$REPORT5" >"$TMP/claim-id-question-mark.stdout" 2>&1 || RC5=$?
if [ "$RC5" -eq 0 ]; then ok "5 claim-id-? finalize exit 0"; else
  fail_msg "5 claim-id-? finalize exit $RC5"; cat "$TMP/claim-id-question-mark.stdout"
fi
if grep -qF 'Claim ?' "$REPORT5"; then
  fail_msg "5 report has Claim ? placeholder"
else
  ok "5 no Claim ? placeholder (id '?' treated as absent)"
fi
grep_file "5 '?' id falls through to exact text match (c0)" \
  '### Claim c0: [AC-A] For CDT-FIX' "$REPORT5"
grep_file "5 '?' id with no text match falls to unmatched" \
  '### Claim unmatched: a degraded-brief verdict with no matching claim text' "$REPORT5"

# ---- Case 6: the CDT-589-C4 Forward claim matrix shares this finalize path ---
# SPEC-013 § CDT-589-C4 binds AC5/AC7/AC8 to `Verify: bash
# skills/council/test-finalize-claim-ids.sh`. The Forward claim fixture matrix
# (fixtures/forward-claim/) lives in test-forward-claim.sh; invoke it here so
# that binding stays true. It is hermetic, engine-side, deterministic, and
# never LLM-live (same contract as this suite).
#
# Receipt half: each bound AC runs the matrix filtered to itself. The nested
# suite's receipts are its own; this suite counts them and re-exhibits the
# nested run's non-ok lines verbatim (aggregate + exhibit:/CMD lines), so the
# `^ok ` count here stays this suite's own while the raw guard tokens
# (forward-claim-guard:, UNVERIFIED, scope==plan, ...) land in this run's
# output from real nested data.
FWD_SH="$ROOT/skills/council/test-forward-claim.sh"
if [ ! -f "$FWD_SH" ]; then
  fail_msg "6 test-forward-claim.sh is missing"
else
  fwd_out="$(bash "$FWD_SH" 2>&1)"
  fwd_rc=$?
  if [ "$fwd_rc" -eq 0 ]; then ok "6 test-forward-claim.sh exits 0"; else
    fail_msg "6 test-forward-claim.sh exited $fwd_rc"
  fi
  printf '%s\n' "$fwd_out" | grep -q '^FAIL:' \
    && fail_msg "6 test-forward-claim.sh printed a FAIL line"
  printf '%s\n' "$fwd_out" | grep -q '^PASS=[0-9]* FAIL=0$' \
    && ok "6 test-forward-claim.sh reports FAIL=0 ($(printf '%s\n' "$fwd_out" | grep '^PASS=' | tail -1))" \
    || fail_msg "6 test-forward-claim.sh summary is not FAIL=0: $(printf '%s\n' "$fwd_out" | grep '^PASS=' | tail -1)"
  printf '%s\n' "$fwd_out" | grep -E '^(FAIL:|PASS=)' | sed 's/^/    /'
  for ac in AC5 AC7 AC8; do
    set_ac "$ac"
    fwd_rc=0
    printf 'CMD: bash skills/council/test-forward-claim.sh --ac %s\n' "$ac"
    fwd_ac_out="$(bash "$FWD_SH" --ac "$ac" 2>&1)" || fwd_rc=$?
    printf 'CMD exit=%s\n' "$fwd_rc"
    fwd_n="$(printf '%s\n' "$fwd_ac_out" | grep -c "^ok $ac: ")"
    printf 'nested ok %s receipts: %s\n' "$ac" "$fwd_n"
    if [ "$fwd_rc" -eq 0 ] && [ "$fwd_n" -ge 1 ]; then
      ok "nested forward-claim --ac $ac exits 0 with $fwd_n receipts"
    else
      fail_msg "nested forward-claim --ac $ac failed: rc=$fwd_rc receipts=$fwd_n"
    fi
    printf '%s\n' "$fwd_ac_out" | grep -E '^(PASS=|exhibit:|CMD exit=)' | sed 's/^/nested: /'
  done
  CUR_AC=""
fi

# Guard: never wrote into the real worktree .claude/council
if [ -f "$ROOT/.claude/council/index.json" ] && grep -q 'wp115-m14-single\|wp115-single-claim-scope\|wp115-m14-multi' "$ROOT/.claude/council/index.json" 2>/dev/null; then
  fail_msg "guard: polluted $ROOT/.claude/council/index.json"
else
  ok "guard: no live-repo index pollution"
fi

# ---- Summary -----------------------------------------------------------------
echo
# A legacy base-case failure gates the exit even though it carries no receipt;
# ac_finish still owns the last stdout line and the 64-on-zero-match rule.
if [ "${fail:-0}" -ne 0 ]; then
  FAIL=$(( FAIL + 1 ))
fi
ac_finish
