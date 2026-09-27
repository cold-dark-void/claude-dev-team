#!/usr/bin/env bash
# WP 1-15 AC H — finalize report shows claim id + text (SPEC-033 M14(g)).
# Fixtures: skills/council/fixtures/finalize-claim-ids/
# Hermetic: hermetic_init (private TMPDIR/HOME) + isolated temp git repo;
# no live .claude/ writes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

ENGINE="$ROOT/skills/council/engine.sh"
FIX="$ROOT/skills/council/fixtures/finalize-claim-ids"
fail=0
pass=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/finalize-claim-ids.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"

ok() {
  echo "OK: $1"
  pass=$((pass + 1))
}
fail_msg() {
  echo "FAIL: $1"
  fail=$((fail + 1))
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

# Guard: never wrote into the real worktree .claude/council
if [ -f "$ROOT/.claude/council/index.json" ] && grep -q 'wp115-m14-single\|wp115-single-claim-scope\|wp115-m14-multi' "$ROOT/.claude/council/index.json" 2>/dev/null; then
  fail_msg "guard: polluted $ROOT/.claude/council/index.json"
else
  ok "guard: no live-repo index pollution"
fi

# ---- Summary -----------------------------------------------------------------
echo
echo "PASS=$pass FAIL=$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
