#!/usr/bin/env bash
# CDT-602 AC3/AC4/AC5 — skills/council/verify-judge-shape.sh
#
# The finalize-side shape self-heal repairs the three CDT-614 judge-output
# defect classes before the render block sees the file, and hands unhealable
# defects to the engine strike channel. This suite pins:
#   AC3 — the three heals from fixture reconstructions: duplicate top-level
#         "verdicts" key → LAST kept (string-aware scan: a quoted key inside
#         a blob is not a key; an unbalanced last block fails closed 7);
#         stray head line in evidence_blob → longest byte-exact line-boundary
#         suffix rebuilt against EXACTLY one bundle (zero/multi matches never
#         rewrite); dropped [AC-<id>] tag → re-attached from the plan claim
#   AC4 — unhealable defects (tagged claim matching no plan tail) surface as
#         engine strike reasons via --strikes-file merged into engine_strikes
#         and land in the finalize report's Audit Trail (sidecar struck_count
#         counts them)
#   AC5 — finalize end-to-end byte-identity: every existing finalize golden
#         triple (claim-ids x4, forward-claim M14 control, missing-tid
#         finding[] mixed) renders byte-identical report + sidecar after the
#         wiring; clean judge input is left byte-for-byte unchanged
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh), isolated temp git
# repo for the engine calls, no network, no live .claude/council writes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

fail=0
ok() { echo "OK: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-judge-shape-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

VJS="$ROOT/skills/council/verify-judge-shape.sh"
ENGINE="$ROOT/skills/council/engine.sh"
FIX="$ROOT/skills/council/fixtures/verify-judge-shape"
FIX_CI="$ROOT/skills/council/fixtures/finalize-claim-ids"
FIX_FC="$ROOT/skills/council/fixtures/forward-claim"
FIX_MT="$ROOT/skills/council/fixtures/finalize-missing-tid"

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"

if [ ! -f "$VJS" ]; then
  echo "FAIL: verify-judge-shape.sh is missing"
  exit 1
fi

# vjs <want-rc> <label> <judge-fixture> [flags...]
# — copy the fixture, run the verifier on the copy, assert rc, keep stderr
# and the strikes file for the assertions that follow (VJS_WORK/VJS_OUT/
# VJS_STRIKES).
vjs() {
  local want="$1" label="$2" src="$3"; shift 3
  VJS_WORK="$TMP/work.json"
  VJS_OUT="$TMP/vjs.err"
  VJS_STRIKES="$TMP/strikes.json"
  cp -- "$src" "$VJS_WORK"
  bash "$VJS" --judge-output "$VJS_WORK" \
    --evidence-file "$FIX/evidence.json" \
    --plan-file "$FIX/plan-m14.json" \
    --output-shape verdict[] \
    --strikes-file "$VJS_STRIKES" "$@" >"$VJS_OUT" 2>&1
  local rc=$?
  if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; return 0; fi
  fail_msg "$label (want rc=$want, got $rc)"
  sed 's/^/    /' "$VJS_OUT"
  return 0
}

# byte_same <label> — the work copy is byte-identical to its fixture.
byte_same() {
  local label="$1" src="$2"
  if cmp -s "$src" "$VJS_WORK"; then ok "$label"; else
    fail_msg "$label — verifier rewrote the file"
    diff "$src" "$VJS_WORK" | head -10 | sed 's/^/    /'
  fi
}

# no_strikes <label>
no_strikes() {
  if [ "$(jq 'length' "$VJS_STRIKES")" = "0" ]; then ok "$1"; else
    fail_msg "$1 — strikes: $(jq -c . "$VJS_STRIKES")"
  fi
}

# =============================================================================
# 1. Clean golden — S1–S3 all no-ops, output byte-unchanged
# =============================================================================
vjs 0 "1 clean judge output usable" "$FIX/judge-clean.json"
byte_same "1 clean output byte-unchanged" "$FIX/judge-clean.json"
no_strikes "1 clean output carries no strikes"
if [ -s "$VJS_OUT" ]; then
  fail_msg "1 clean output wrote stderr: $(cat "$VJS_OUT")"
else
  ok "1 clean output is silent"
fi

# =============================================================================
# 2. AC3 S1 — duplicate top-level key, kept LAST
# =============================================================================
vjs 0 "2 S1 duplicate-key file usable" "$FIX/judge-dup-key.json"
if grep -qF 'judge output carried 2 "verdicts" keys; kept the last (CDT-614)' "$VJS_OUT"; then
  ok "2 S1 stderr names the heal and the kept-Last rule"
else
  fail_msg "2 S1 stderr note missing"
  sed 's/^/    /' "$VJS_OUT"
fi
if [ "$(jq -r '.verdicts[0].verdict' "$VJS_WORK")" = "VERIFIED" ] \
  && [ "$(jq '.verdicts | length' "$VJS_WORK")" = "1" ]; then
  ok "2 S1 the LAST block's record is the kept one"
else
  fail_msg "2 S1 kept the wrong block: $(jq -c . "$VJS_WORK")"
fi
no_strikes "2 S1 heal adds no strikes"

# S1 scan is string-aware: the quoted `{"verdicts": ...}` template echo in a
# blob is NOT a key.
vjs 0 "2b S1 quoted template echo in a blob is not a key" "$FIX/judge-blob-quotes-key.json"
byte_same "2b S1 no heal fired (file byte-unchanged)" "$FIX/judge-blob-quotes-key.json"
if [ -s "$VJS_OUT" ]; then
  fail_msg "2b S1 stderr should be silent: $(cat "$VJS_OUT")"
else
  ok "2b S1 no stderr note for the quoted key"
fi

# S1 fail-closed: the last block unbalanced → exit 7, file untouched.
vjs 7 "2c S1 unbalanced last block fails closed" "$FIX/judge-unbalanced-dup.json"
byte_same "2c S1 fail-closed leaves the file untouched" "$FIX/judge-unbalanced-dup.json"
if grep -qF 'unbalanced — no heal (CDT-614)' "$VJS_OUT"; then
  ok "2c S1 stderr names the fail-closed reason"
else
  fail_msg "2c S1 fail-closed stderr missing"
fi

# =============================================================================
# 3. AC3 S2 — stray head line rebuilt as the longest bundle-exact suffix
# =============================================================================
vjs 0 "3 S2 stray-headed blob usable" "$FIX/judge-stray-head.json"
if grep -qF 'rebuilt verdict evidence_blob from its line-boundary suffix (bundle t2)' "$VJS_OUT"; then
  ok "3 S2 stderr names the rebuild and the bundle"
else
  fail_msg "3 S2 rebuild stderr note missing"
  sed 's/^/    /' "$VJS_OUT"
fi
if [ "$(jq -r '.verdicts[0].evidence_blob' "$VJS_WORK")" = "delta block
evidence for B" ]; then
  ok "3 S2 blob rebuilt to the byte-exact suffix of bundle t2"
else
  fail_msg "3 S2 blob not rebuilt: $(jq -c '.verdicts[0].evidence_blob' "$VJS_WORK")"
fi
no_strikes "3 S2 heal adds no strikes"

# S2 never guesses: "evidence" is a substring of BOTH bundles → no rewrite,
# no strike (the record is left for the existing CDT-574 layer).
vjs 0 "3b S2 ambiguous suffix leaves the record" "$FIX/judge-ambiguous-suffix.json"
byte_same "3b S2 multi-bundle suffix never rewrites" "$FIX/judge-ambiguous-suffix.json"
no_strikes "3b S2 multi-bundle suffix adds no strikes"

# =============================================================================
# 4. AC3 S3 — dropped [AC-<id>] tag re-attached from the plan
# =============================================================================
vjs 0 "4 S3 dropped-tag record usable" "$FIX/judge-dropped-tag.json"
if grep -qF 're-attached the [AC-<id>] claim tag from the plan (CDT-614)' "$VJS_OUT"; then
  ok "4 S3 stderr names the re-attach"
else
  fail_msg "4 S3 re-attach stderr note missing"
  sed 's/^/    /' "$VJS_OUT"
fi
if [ "$(jq -r '.verdicts[0].claim' "$VJS_WORK")" \
  = "[AC-B] For CDT-602, the verifier rebuilds a stray-headed blob." ]; then
  ok "4 S3 record claim is the full plan claim text"
else
  fail_msg "4 S3 claim not re-attached: $(jq -c '.verdicts[0].claim' "$VJS_WORK")"
fi
no_strikes "4 S3 heal adds no strikes"

# Untagged free-text claim that matches no plan tail is the pre-existing
# "Claim unmatched" report path — untouched, never a new strike.
cat > "$TMP/judge-untagged.json" <<'EOF'
{"verdicts":[{"claim":"a stray verdict with no matching claim text","verdict":"UNVERIFIED","confidence":50,"evidence_blob":"evidence beta","tool_use_id":"t1"}],"struck_lines":[]}
EOF
vjs 0 "4b S3 untagged unmatched claim stays on the report path" "$TMP/judge-untagged.json"
byte_same "4b S3 untagged unmatched claim byte-unchanged" "$TMP/judge-untagged.json"
no_strikes "4b S3 untagged unmatched claim adds no strikes"

# =============================================================================
# 5. finding[] shape — S2/S3 are verdict[] only; strikes file is []
# =============================================================================
VJS_MT="$TMP/work-findings.json"
cp -- "$FIX/judge-findings.json" "$VJS_MT"
bash "$VJS" --judge-output "$VJS_MT" \
  --evidence-file "$FIX/evidence.json" \
  --plan-file "$FIX/plan-m14.json" \
  --output-shape 'finding[]' \
  --strikes-file "$TMP/strikes-finding.json" >"$TMP/vjs-finding.err" 2>&1
if [ $? -eq 0 ]; then ok "5 finding[] shape exits 0"; else
  fail_msg "5 finding[] shape failed"; sed 's/^/    /' "$TMP/vjs-finding.err"
fi
if cmp -s "$FIX/judge-findings.json" "$VJS_MT"; then
  ok "5 finding[] file byte-unchanged"
else
  fail_msg "5 finding[] file rewritten"
fi
if [ "$(jq 'length' "$TMP/strikes-finding.json")" = "0" ]; then
  ok "5 finding[] strikes file is the empty array"
else
  fail_msg "5 finding[] strikes not empty: $(jq -c . "$TMP/strikes-finding.json")"
fi

# =============================================================================
# 6. Usage contract — exit 2, and the unusable-JSON 7 pre-check
# =============================================================================
bash "$VJS" --judge-output "$TMP/nope.json" \
  --evidence-file "$FIX/evidence.json" --plan-file "$FIX/plan-m14.json" \
  --output-shape verdict[] >"$TMP/vjs-missing.err" 2>&1
if [ $? -eq 2 ] && grep -qF 'missing file' "$TMP/vjs-missing.err"; then
  ok "6 missing input file exits 2 with a named path"
else
  fail_msg "6 missing-file contract (rc/stderr)"
fi
bash "$VJS" --judge-output "$FIX/judge-clean.json" \
  --evidence-file "$FIX/evidence.json" --plan-file "$FIX/plan-m14.json" \
  --output-shape verdicts >"$TMP/vjs-shape.err" 2>&1
if [ $? -eq 2 ] && grep -qF 'verdict[]|finding[]' "$TMP/vjs-shape.err"; then
  ok "6 bad --output-shape exits 2 with the usage line"
else
  fail_msg "6 bad-shape contract (rc/stderr)"
fi
printf '%s' '{"verdicts": [{"broken": ' > "$TMP/judge-garbage.json"
bash "$VJS" --judge-output "$TMP/judge-garbage.json" \
  --evidence-file "$FIX/evidence.json" --plan-file "$FIX/plan-m14.json" \
  --output-shape verdict[] --strikes-file "$TMP/strikes-g.json" \
  >"$TMP/vjs-garbage.err" 2>&1
if [ $? -eq 7 ] && grep -qF 'not valid JSON' "$TMP/vjs-garbage.err"; then
  ok "6 unparseable judge output exits 7 (the judge-failure code)"
else
  fail_msg "6 unparseable-input contract (rc/stderr)"
fi

# =============================================================================
# 7. AC4 — unhealable defect: strikes file + engine Audit Trail end-to-end
# =============================================================================
vjs 0 "7 tagged claim matching no plan tail usable" "$FIX/judge-bad-claim.json"
if [ "$(jq -r 'length' "$VJS_STRIKES")" = "1" ] \
  && jq -e '.[0] | startswith("verdict claim text matches no plan claim (claim=")' \
       "$VJS_STRIKES" >/dev/null; then
  ok "7 S3 strike reason is the validate_judge-shaped line"
else
  fail_msg "7 S3 strike reason missing: $(jq -c . "$VJS_STRIKES")"
fi
byte_same "7 the strike path never rewrites the judge file" "$FIX/judge-bad-claim.json"

BADJ="$TMP/judge-bad-claim-run.json"
cp -- "$FIX/judge-bad-claim.json" "$BADJ"
REPORT7="$TMP/bad-claim.md"
META7="$REPORT7.finalize-meta.json"
( cd "$REPO" && bash "$ENGINE" finalize \
    --plan-file "$FIX/plan-m14.json" \
    --evidence-file "$FIX/evidence.json" \
    --judge-output "$BADJ" \
    --report-out "$REPORT7" ) >"$TMP/bad-claim.stdout" 2>&1
if [ $? -eq 0 ] && [ -f "$REPORT7" ]; then
  ok "7 finalize completes on the strike path (exit 0, report written)"
else
  fail_msg "7 finalize on the strike path failed"
  sed 's/^/    /' "$TMP/bad-claim.stdout"
fi
if grep -qF 'verdict claim text matches no plan claim (claim=[AC-A] For CDT-602, the verifier keeps the LAST duplicate key and then drifts.)' "$REPORT7"; then
  ok "7 the strike reason renders in the report Audit Trail"
else
  fail_msg "7 strike reason absent from the report"
  grep -n 'Audit Trail' -A4 "$REPORT7" | sed 's/^/    /'
fi
if [ "$(jq -r '.struck_count' "$META7")" = "1" ]; then
  ok "7 sidecar struck_count counts the merged strike"
else
  fail_msg "7 sidecar struck_count: $(jq -r .struck_count "$META7" 2>/dev/null)"
fi

# =============================================================================
# 8. AC5 — finalize byte-identity on every existing golden triple
# =============================================================================
# The goldens were generated from the BASE engine (no wiring). The report
# holds the run clock; the sidecar holds none.
norm_ts() {
  sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TIMESTAMP>/g' "$1"
}
golden_fail=0
golden_case() {  # golden_case <name> <plan> <evidence> <judge>
  local name="$1" plan="$2" evidence="$3" judge="$4"
  local jcopy="$TMP/$name.judge.json" rc=0
  cp -- "$judge" "$jcopy"   # the engine finalizes the file in place
  ( cd "$REPO" && bash "$ENGINE" finalize \
      --plan-file "$plan" \
      --evidence-file "$evidence" \
      --judge-output "$jcopy" \
      --report-out "$TMP/$name.md" ) >"$TMP/$name.stdout" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_msg "8 $name finalize exit $rc"
    sed 's/^/    /' "$TMP/$name.stdout"
    golden_fail=1
    return 0
  fi
  if cmp -s <(norm_ts "$TMP/$name.md") "$FIX/goldens/$name.report.golden.md"; then
    ok "8 $name report byte-identical to the golden"
  else
    fail_msg "8 $name report differs from the golden"
    diff "$FIX/goldens/$name.report.golden.md" <(norm_ts "$TMP/$name.md") \
      | head -10 | sed 's/^/    /'
    golden_fail=1
  fi
  if cmp -s "$TMP/$name.md.finalize-meta.json" "$FIX/goldens/$name.finalize-meta.golden.json"; then
    ok "8 $name sidecar byte-identical to the golden"
  else
    fail_msg "8 $name sidecar differs from the golden"
    diff "$FIX/goldens/$name.finalize-meta.golden.json" "$TMP/$name.md.finalize-meta.json" \
      | head -10 | sed 's/^/    /'
    golden_fail=1
  fi
}
PLAN_MT="$TMP/plan-finding-nopath.json"
jq 'del(.report_path)' "$FIX_MT/plan-finding.json" > "$PLAN_MT"
golden_case claim-ids-m14-single "$FIX_CI/plan-m14-single.json" \
  "$FIX_CI/evidence-m14-single.json" "$FIX_CI/judge-m14-single.json"
golden_case claim-ids-m14-multi "$FIX_CI/plan-m14-multi.json" \
  "$FIX_CI/evidence-m14-multi.json" "$FIX_CI/judge-m14-multi-unmatched.json"
golden_case claim-ids-qmark "$FIX_CI/plan-m14-multi.json" \
  "$FIX_CI/evidence-m14-multi.json" "$FIX_CI/judge-claim-id-question-mark.json"
golden_case claim-ids-scope "$FIX_CI/plan-single-claim-scope.json" \
  "$FIX_CI/evidence-single-claim-scope.json" "$FIX_CI/judge-single-claim-scope.json"
golden_case fwd-m14-control "$FIX_FC/plan-m14-control.json" \
  "$FIX_FC/evidence-m14-control.json" "$FIX_FC/judge-m14-control.json"
golden_case missing-tid-finding "$PLAN_MT" \
  "$FIX_MT/evidence-mixed.json" "$FIX_MT/judge-mixed.json"
if [ "$golden_fail" -eq 0 ]; then
  ok "8 AC5 all six golden triples byte-identical"
fi

# Guard: never wrote into the real worktree .claude/council
if [ -f "$ROOT/.claude/council/index.json" ] \
  && grep -q 'cdt602-shape\|bad-claim' "$ROOT/.claude/council/index.json" 2>/dev/null; then
  fail_msg "guard: polluted $ROOT/.claude/council/index.json"
else
  ok "guard: no live-repo index pollution"
fi

# ---- Summary ----------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
  echo "PASS: test-verify-judge-shape.sh"
  exit 0
else
  echo "FAIL: test-verify-judge-shape.sh"
  exit 1
fi
