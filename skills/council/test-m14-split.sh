#!/usr/bin/env bash
#
# skills/council/test-m14-split.sh — WP 1-14/1-15 T3 (AC C, E, G; SPEC-013 Test 24;
# SPEC-033 M14(g)/(j)). Covers the engine-side half of the M14 per-AC split:
#
#   - the trigger (scope==claim AND scope_arg prefix AND >=1 ac-source= token)
#   - the plan.claims[]/ac_source/process_acs/claim_budget shape (C2), exact
#     claim template, source_locator, document order
#   - every engine-side exit-8 path: >=2 ac-source= tokens (case 1), an
#     uncommitted/missing AC source (m14-ac-split.sh's own case 1), a missing
#     "## Acceptance criteria" heading (case 2), a technical AC count over
#     M14_AC_BUDGET (case 9), and M14_AC_BUDGET > M14_AC_BUDGET_CEILING
#     (M14(j), via a sed-patched COPY of engine.sh -- never the live file)
#   - the zero-token envelope: no split, no `claims` key (AC G boundary)
#   - the split fires ONLY for scope==claim (a non-claim scope never splits)
#   - finalize-meta sidecar C3 keys: min_verdict_confidence, verdict_counts,
#     verification_mode, unstruck_verdicts, and (M14 runs only) ac_source,
#     ac_claims, process_acs -- including self-verified mode and the
#     finding[]-shape null cases
#   - end-to-end: preflight split -> synthetic judge output tagged [AC-<id>]
#     -> finalize -> sidecar -> skills/autopilot/ship-gate-verdict.sh gives
#     the expected decision
#   - WP 1-15 C2: claims[].verify (the AC's Verify command or null) and
#     .tool_budget (8 with a command, else 5); the claim text template is
#     unaffected; case 10 (a second Verify line) propagates fail-closed
#
# Fixtures: skills/council/fixtures/m14-split/*.md (committed into a private
# temp git repo below; never the live worktree).
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh); every engine.sh call
# runs with cwd inside its own temp git repo, so .claude/council/ writes land
# there, never under the real MROOT.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
MAPPER="$ROOT/skills/autopilot/ship-gate-verdict.sh"
FIX="$ROOT/skills/council/fixtures/m14-split"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

fail=0
pass=0
ok() { echo "OK: $1"; pass=$((pass + 1)); }
fail_msg() { echo "FAIL: $1"; fail=$((fail + 1)); }
ok_eq() {  # ok_eq <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else fail_msg "$1 (got: $2 | want: $3)"; fi
}

REPO="$HERMETIC_ROOT/repo"
mkdir -p "$REPO"
git init -q "$REPO"
cp "$FIX"/*.md "$REPO"/
cp "$FIX"/test-stub.sh "$REPO"/   # WP 1-15 T3: Verify-line target, cp preserves the 755 mode
git -C "$REPO" add -A
git -C "$REPO" commit -q -m fixtures

preflight() {  # preflight <scope-arg> [engine-flags...] -> stdout on fd1, stderr on fd2
  local scope_arg="$1"; shift
  ( cd "$REPO" && bash "$ENGINE" preflight --scope claim --scope-arg "$scope_arg" "$@" )
}

# expected_claim <id> <ticket_id> <path> <line> -- SPEC-013 Phase 1 / C2 exact template
expected_claim() {
  local id="$1" ticket="$2" path="$3" line="$4"
  printf '[AC-%s] For %s, the diff from the merge-base of the origin default branch and HEAD to HEAD satisfies acceptance criterion %s as written at %s:%s. Read the criterion at that locator and judge this criterion only.' \
    "$id" "$ticket" "$id" "$path" "$line"
}

A_LINE="$(grep -n '^- \*\*A\.\*\*' "$FIX/valid-spec.md" | head -1 | cut -d: -f1)"
B_LINE="$(grep -n '^- \*\*B\.\*\*' "$FIX/valid-spec.md" | head -1 | cut -d: -f1)"

TRIGGER_ARG="Ship-gate audit for wp-e2e-split. This ships under the ACs at ac-source=valid-spec.md (section '## Acceptance criteria', subsection '### wp-e2e-split'). Claim under audit: the change ships correctly."

# ==============================================================================
# 1. Valid trigger: shape, exact template, source_locator, process_acs,
#    document order, Phase 1 skip, claim_budget == M14_AC_BUDGET (SPEC-013
#    Test 24 item 1)
# ==============================================================================
OUT1="$(preflight "$TRIGGER_ARG")"; RC1=$?
ok_eq "1 valid trigger: exit 0" "$RC1" "0"
ok_eq "1 claims length == 2 (A, B technical only)" \
  "$(printf '%s' "$OUT1" | jq '.claims | length')" "2"
ok_eq "1 ac_source" "$(printf '%s' "$OUT1" | jq -r '.ac_source')" "valid-spec.md"
ok_eq "1 process_acs == [C]" "$(printf '%s' "$OUT1" | jq -c '.process_acs')" '["C"]'
ok_eq "1 claim_budget == 16 (M14_AC_BUDGET)" "$(printf '%s' "$OUT1" | jq '.claim_budget')" "16"
ok_eq "1 Phase 1 stays skipped" \
  "$(printf '%s' "$OUT1" | jq '.phases."1_claim_extraction".skip')" "true"
ok_eq "1 claims[0].claim_id" "$(printf '%s' "$OUT1" | jq -r '.claims[0].claim_id')" "c0"
ok_eq "1 claims[0].ac_id" "$(printf '%s' "$OUT1" | jq -r '.claims[0].ac_id')" "A"
ok_eq "1 claims[0].claim_type" "$(printf '%s' "$OUT1" | jq -r '.claims[0].claim_type')" "factual"
ok_eq "1 claims[0].source_locator" "$(printf '%s' "$OUT1" | jq -r '.claims[0].source_locator')" "valid-spec.md:$A_LINE"
ok_eq "1 claims[1].claim_id" "$(printf '%s' "$OUT1" | jq -r '.claims[1].claim_id')" "c1"
ok_eq "1 claims[1].ac_id" "$(printf '%s' "$OUT1" | jq -r '.claims[1].ac_id')" "B"
ok_eq "1 claims[1].source_locator" "$(printf '%s' "$OUT1" | jq -r '.claims[1].source_locator')" "valid-spec.md:$B_LINE"
EXPECT_CLAIM_A="$(expected_claim A wp-e2e-split valid-spec.md "$A_LINE")"
ok_eq "1 claims[0].claim exact template" "$(printf '%s' "$OUT1" | jq -r '.claims[0].claim')" "$EXPECT_CLAIM_A"
EXPECT_CLAIM_B="$(expected_claim B wp-e2e-split valid-spec.md "$B_LINE")"
ok_eq "1 claims[1].claim exact template" "$(printf '%s' "$OUT1" | jq -r '.claims[1].claim')" "$EXPECT_CLAIM_B"

# ==============================================================================
# 2. Trigger requires scope==claim: the identical text at scope==session never
#    splits (no claims key, exit 0)
# ==============================================================================
OUT2="$( cd "$REPO" && bash "$ENGINE" preflight --scope session --scope-arg "$TRIGGER_ARG" )"; RC2=$?
ok_eq "2 non-claim scope: exit 0" "$RC2" "0"
if printf '%s' "$OUT2" | jq -e 'has("claims")' >/dev/null 2>&1; then
  fail_msg "2 non-claim scope: unexpected claims key present"
else
  ok "2 non-claim scope: no claims key (trigger is claim-scope only)"
fi

# ==============================================================================
# 3. Zero-token envelope: matches the "Ship-gate audit for X." prefix but
#    holds no ac-source= token -- does NOT split (AC G boundary; the mapper
#    halts this later, SPEC-033 M14(g))
# ==============================================================================
OUT3="$(preflight "Ship-gate audit for wp-e2e-split. Claim under audit: no ac-source token here.")"; RC3=$?
ok_eq "3 zero-token envelope: exit 0" "$RC3" "0"
if printf '%s' "$OUT3" | jq -e '(has("claims") or has("ac_source") or has("process_acs"))' >/dev/null 2>&1; then
  fail_msg "3 zero-token envelope: unexpected M14 key present"
else
  ok "3 zero-token envelope: no M14 keys"
fi
ok_eq "3 zero-token envelope: claim_budget stays 10" "$(printf '%s' "$OUT3" | jq '.claim_budget')" "10"

# ==============================================================================
# 4. Case 1 (engine-side): two or more ac-source= tokens -> exit 8, empty
#    stdout, one stderr line naming case 1 (SPEC-013 Test 24 item 2)
# ==============================================================================
OUT4="$(preflight "Ship-gate audit for wp-e2e-split. ac-source=valid-spec.md ac-source=other.md" 2>"$HERMETIC_ROOT/err4")"; RC4=$?
ok_eq "4 two ac-source tokens: exit 8" "$RC4" "8"
ok_eq "4 two ac-source tokens: empty stdout" "$OUT4" ""
if [ "$(wc -l <"$HERMETIC_ROOT/err4")" -eq 1 ] && grep -q '^m14-ac-split: case 1:' "$HERMETIC_ROOT/err4"; then
  ok "4 two ac-source tokens: one stderr line, case 1"
else
  fail_msg "4 two ac-source tokens: stderr ($(cat "$HERMETIC_ROOT/err4"))"
fi

# ==============================================================================
# 5. m14-ac-split.sh's own case 1: an uncommitted AC source -> exit 8, empty
#    stdout, propagated stderr (SPEC-013 Test 24 item 2: "uncommitted AC
#    source")
# ==============================================================================
cat "$FIX/valid-spec.md" > "$REPO/uncommitted.md"   # working-tree only, never committed
OUT5="$(preflight "Ship-gate audit for wp-e2e-split. ac-source=uncommitted.md" 2>"$HERMETIC_ROOT/err5")"; RC5=$?
ok_eq "5 uncommitted AC source: exit 8" "$RC5" "8"
ok_eq "5 uncommitted AC source: empty stdout" "$OUT5" ""
if [ "$(wc -l <"$HERMETIC_ROOT/err5")" -eq 1 ] && grep -q '^m14-ac-split: case 1:' "$HERMETIC_ROOT/err5"; then
  ok "5 uncommitted AC source: one stderr line, case 1"
else
  fail_msg "5 uncommitted AC source: stderr ($(cat "$HERMETIC_ROOT/err5"))"
fi

# ==============================================================================
# 6. m14-ac-split.sh's own case 2: missing "## Acceptance criteria" heading
#    -> exit 8, empty stdout (SPEC-013 Test 24 item 2: "heading missing")
# ==============================================================================
OUT6="$(preflight "Ship-gate audit for wp-no-heading. ac-source=no-heading.md" 2>"$HERMETIC_ROOT/err6")"; RC6=$?
ok_eq "6 heading missing: exit 8" "$RC6" "8"
ok_eq "6 heading missing: empty stdout" "$OUT6" ""
if [ "$(wc -l <"$HERMETIC_ROOT/err6")" -eq 1 ] && grep -q '^m14-ac-split: case 2:' "$HERMETIC_ROOT/err6"; then
  ok "6 heading missing: one stderr line, case 2"
else
  fail_msg "6 heading missing: stderr ($(cat "$HERMETIC_ROOT/err6"))"
fi

# ==============================================================================
# 7. Case 9 (engine-side): 17 technical ACs over the M14_AC_BUDGET=16 budget
#    -> exit 8, empty stdout, stderr names the ids beyond budget (SPEC-013
#    Test 24 item 2: "17 technical ACs over budget with ids named")
# ==============================================================================
OUT7="$(preflight "Ship-gate audit for wp-over-budget. ac-source=over-budget.md" 2>"$HERMETIC_ROOT/err7")"; RC7=$?
ok_eq "7 over-budget: exit 8" "$RC7" "8"
ok_eq "7 over-budget: empty stdout" "$OUT7" ""
if [ "$(wc -l <"$HERMETIC_ROOT/err7")" -eq 1 ] && grep -q '^m14-ac-split: case 9:' "$HERMETIC_ROOT/err7" \
   && grep -qF 'Q' "$HERMETIC_ROOT/err7"; then
  ok "7 over-budget: one stderr line, case 9, names id Q"
else
  fail_msg "7 over-budget: stderr ($(cat "$HERMETIC_ROOT/err7"))"
fi

# ==============================================================================
# 8. M14(j): M14_AC_BUDGET > M14_AC_BUDGET_CEILING fails every M14 split
#    closed, independent of the actual technical AC count. Tested via a
#    sed-patched COPY of engine.sh (never the live file, never an
#    env/flag override -- the product code takes neither).
# ==============================================================================
CEILING_ENGINE="$HERMETIC_ROOT/engine-ceiling.sh"
sed 's/^readonly M14_AC_BUDGET=16$/readonly M14_AC_BUDGET=25/' "$ENGINE" > "$CEILING_ENGINE"
chmod +x "$CEILING_ENGINE"
# L-10: engine.sh sources its helpers from its own directory — copy them next
# to the patched copy so the hermetic engine behaves like the installed one.
for _eh in engine-util.sh engine-report-path.sh engine-preflight.sh engine-finalize.sh; do
  cp "$ROOT/skills/council/$_eh" "$HERMETIC_ROOT/$_eh"
done
unset _eh
if ! grep -q '^readonly M14_AC_BUDGET=25$' "$CEILING_ENGINE"; then
  fail_msg "8 sed patch did not take (test setup bug)"
fi
OUT8="$( cd "$REPO" && bash "$CEILING_ENGINE" preflight --scope claim --scope-arg "$TRIGGER_ARG" 2>"$HERMETIC_ROOT/err8" )"; RC8=$?
ok_eq "8 budget above ceiling: exit 8" "$RC8" "8"
ok_eq "8 budget above ceiling: empty stdout" "$OUT8" ""
if [ "$(wc -l <"$HERMETIC_ROOT/err8")" -eq 1 ] \
   && grep -q '^m14-ac-split: M14_AC_BUDGET (25) exceeds M14_AC_BUDGET_CEILING (20)' "$HERMETIC_ROOT/err8"; then
  ok "8 budget above ceiling: one stderr line naming both constants"
else
  fail_msg "8 budget above ceiling: stderr ($(cat "$HERMETIC_ROOT/err8"))"
fi

# ==============================================================================
# 9. Usage documents exit 8
# ==============================================================================
USAGE_OUT="$(bash "$ENGINE" 2>&1 1>/dev/null || true)"
if printf '%s' "$USAGE_OUT" | grep -q '8 M14 per-AC split'; then
  ok "9 usage documents exit 8"
else
  fail_msg "9 usage documents exit 8 (got: $USAGE_OUT)"
fi

# ==============================================================================
# 10. Finalize-meta sidecar (C3): end-to-end preflight split -> synthetic
#     judge output tagged [AC-<id>] -> finalize -> sidecar keys. Also feeds
#     the sidecar to ship-gate-verdict.sh for the expected decision.
# ==============================================================================
PLAN10="$HERMETIC_ROOT/plan10.json"
( cd "$REPO" && bash "$ENGINE" preflight --scope claim --scope-arg "$TRIGGER_ARG" ) > "$PLAN10"

EVIDENCE10="$HERMETIC_ROOT/evidence10.json"
cat > "$EVIDENCE10" <<'EOF'
[
  {"tool_use_id": "t1", "raw_blob": "field renders", "file_line": "widget.js:10", "reproducible_command": "true"},
  {"tool_use_id": "t2", "raw_blob": "field persists", "file_line": "store.js:20", "reproducible_command": "true"}
]
EOF

JUDGE10="$HERMETIC_ROOT/judge10.json"
CLAIM_A="$(jq -r '.claims[0].claim' "$PLAN10")"
CLAIM_B="$(jq -r '.claims[1].claim' "$PLAN10")"
jq -n --arg ca "$CLAIM_A" --arg cb "$CLAIM_B" '{
  verdicts: [
    {claim_id: "c0", claim: $ca, verdict: "VERIFIED", confidence: 90, evidence_blob: "field renders"},
    {claim_id: "c1", claim: $cb, verdict: "PARTIALLY_VERIFIED", confidence: 85, evidence_blob: "field persists"}
  ],
  struck_lines: []
}' > "$JUDGE10"

( cd "$REPO" && bash "$ENGINE" finalize --plan-file "$PLAN10" --evidence-file "$EVIDENCE10" \
    --judge-output "$JUDGE10" > "$HERMETIC_ROOT/finalize10.out" 2>"$HERMETIC_ROOT/finalize10.err" )
RC10=$?
ok_eq "10 finalize: exit 0" "$RC10" "0"

REPORT10=$(jq -r '.report_path' "$PLAN10")
META10="${REPORT10}.finalize-meta.json"
if [ -f "$META10" ]; then
  ok "10 sidecar exists"
else
  fail_msg "10 sidecar exists (not found: $META10)"
fi
ok_eq "10 sidecar.ac_source" "$(jq -r '.ac_source' "$META10")" "valid-spec.md"
ok_eq "10 sidecar.ac_claims" "$(jq -c '.ac_claims' "$META10")" '[{"claim_id":"c0","ac_id":"A"},{"claim_id":"c1","ac_id":"B"}]'
ok_eq "10 sidecar.process_acs" "$(jq -c '.process_acs' "$META10")" '["C"]'
ok_eq "10 sidecar.verification_mode" "$(jq -r '.verification_mode' "$META10")" "full"
ok_eq "10 sidecar.min_verdict_confidence" "$(jq '.min_verdict_confidence' "$META10")" "85"
ok_eq "10 sidecar.verdict_counts" \
  "$(jq -c '.verdict_counts' "$META10")" \
  '{"VERIFIED":1,"PARTIALLY_VERIFIED":1,"UNVERIFIED":0,"CONTRADICTED":0,"FABRICATED":0}'
ok_eq "10 sidecar.unstruck_verdicts length" "$(jq '.unstruck_verdicts | length' "$META10")" "2"
ok_eq "10 sidecar.unstruck_verdicts[0].confidence" "$(jq '.unstruck_verdicts[0].confidence' "$META10")" "90"

# ---- 10b. End-to-end: feed the sidecar to ship-gate-verdict.sh ------------
CARD1_AGREE="$HERMETIC_ROOT/card1-agree.json"
cat > "$CARD1_AGREE" <<'EOF'
{"gate":"ship-choice","decision":"merge","bump":"patch","decided_by":"auto",
 "blocking_condition":null,"council_tier":null,"grading_reason":null}
EOF
VERDICT10="$(bash "$MAPPER" --meta "$META10" --card1 "$CARD1_AGREE" --tier full)"; RCV10=$?
ok_eq "10b mapper: exit 0" "$RCV10" "0"
ok_eq "10b mapper: decision agree->merge" "$(printf '%s' "$VERDICT10" | jq -r '.decision')" "merge"
ok_eq "10b mapper: blocking_condition null" "$(printf '%s' "$VERDICT10" | jq -c '.blocking_condition')" "null"
ok_eq "10b mapper: confidence == min(90,85) == 85" "$(printf '%s' "$VERDICT10" | jq '.confidence')" "85"
ok_eq "10b mapper: bump copied from card1" "$(printf '%s' "$VERDICT10" | jq -r '.bump')" "patch"

# ==============================================================================
# 11. Self-verified mode: same plan/evidence/judge, finalize with
#     --verification-mode self-verified -> sidecar records it, and the
#     mapper treats it as a degraded run (M14(d): halt, confidence 0)
#     regardless of how high the verdict confidences are.
# ==============================================================================
REPORT11="$HERMETIC_ROOT/report11.md"
( cd "$REPO" && bash "$ENGINE" finalize --plan-file "$PLAN10" --evidence-file "$EVIDENCE10" \
    --judge-output "$JUDGE10" --verification-mode self-verified --report-out "$REPORT11" \
    > "$HERMETIC_ROOT/finalize11.out" 2>"$HERMETIC_ROOT/finalize11.err" )
RC11=$?
ok_eq "11 self-verified finalize: exit 0" "$RC11" "0"
META11="${REPORT11}.finalize-meta.json"
ok_eq "11 sidecar.verification_mode == self-verified" "$(jq -r '.verification_mode' "$META11")" "self-verified"
VERDICT11="$(bash "$MAPPER" --meta "$META11" --card1 "$CARD1_AGREE" --tier full)"
ok_eq "11 mapper: self-verified -> halt" "$(printf '%s' "$VERDICT11" | jq -r '.decision')" "halt"
ok_eq "11 mapper: self-verified -> confidence 0" "$(printf '%s' "$VERDICT11" | jq '.confidence')" "0"

# ==============================================================================
# 12. finding[]-shape run: min_verdict_confidence / verdict_counts /
#     unstruck_verdicts are null; verification_mode is still set; no
#     ac_source/ac_claims/process_acs (plan carries no AC-bound claims).
# ==============================================================================
PLAN12="$HERMETIC_ROOT/plan12.json"
( cd "$REPO" && bash "$ENGINE" preflight --scope diff ) > "$PLAN12"
EVIDENCE12="$HERMETIC_ROOT/evidence12.json"
cat > "$EVIDENCE12" <<'EOF'
[{"tool_use_id": "t1", "raw_blob": "b", "file_line": "f.py:1", "reproducible_command": "true"}]
EOF
JUDGE12="$HERMETIC_ROOT/judge12.json"
cat > "$JUDGE12" <<'EOF'
{"findings": [{"tool_use_id": "t1", "file": "f.py", "line": 1, "severity": "warning",
               "category": "logic", "description": "d", "confidence": 60}],
 "struck_lines": []}
EOF
( cd "$REPO" && bash "$ENGINE" finalize --plan-file "$PLAN12" --evidence-file "$EVIDENCE12" \
    --judge-output "$JUDGE12" > "$HERMETIC_ROOT/finalize12.out" 2>"$HERMETIC_ROOT/finalize12.err" )
RC12=$?
ok_eq "12 finding[] finalize: exit 0" "$RC12" "0"
REPORT12=$(jq -r '.report_path' "$PLAN12")
META12="${REPORT12}.finalize-meta.json"
ok_eq "12 sidecar.min_verdict_confidence == null" "$(jq -c '.min_verdict_confidence' "$META12")" "null"
ok_eq "12 sidecar.verdict_counts == null" "$(jq -c '.verdict_counts' "$META12")" "null"
ok_eq "12 sidecar.unstruck_verdicts == null" "$(jq -c '.unstruck_verdicts' "$META12")" "null"
ok_eq "12 sidecar.verification_mode == full" "$(jq -r '.verification_mode' "$META12")" "full"
if jq -e '(has("ac_source") or has("ac_claims") or has("process_acs"))' "$META12" >/dev/null 2>&1; then
  fail_msg "12 sidecar unexpectedly carries an M14 key for a non-M14 plan"
else
  ok "12 sidecar carries no M14 keys (non-M14 plan)"
fi

# ==============================================================================
# 13. "engine.sh m14-check" subcommand (WP 1-14 review round 2, B-2): the
#     ceiling check, the split, and the case-9 budget check live in ONE
#     function (m14_check) shared by cmd_preflight and this subcommand. This
#     covers the subcommand directly -- cases 1-8 (m14-ac-split.sh, tested
#     via cmd_preflight above) plus case 9 and the success path here.
# ==============================================================================
OUT13A="$( cd "$REPO" && bash "$ENGINE" m14-check wp-over-budget over-budget.md 2>"$HERMETIC_ROOT/err13a" )"; RC13A=$?
ok_eq "13 m14-check over-budget: exit 8" "$RC13A" "8"
ok_eq "13 m14-check over-budget: empty stdout" "$OUT13A" ""
if [ "$(wc -l <"$HERMETIC_ROOT/err13a")" -eq 1 ] && grep -q '^m14-ac-split: case 9:' "$HERMETIC_ROOT/err13a"; then
  ok "13 m14-check over-budget: one stderr line, case 9"
else
  fail_msg "13 m14-check over-budget: stderr ($(cat "$HERMETIC_ROOT/err13a"))"
fi

OUT13B="$( cd "$REPO" && bash "$ENGINE" m14-check wp-e2e-split valid-spec.md )"; RC13B=$?
ok_eq "13 m14-check success: exit 0" "$RC13B" "0"
ok_eq "13 m14-check success: ac_source" "$(printf '%s' "$OUT13B" | jq -r '.ac_source')" "valid-spec.md"
ok_eq "13 m14-check success: ticket_id" "$(printf '%s' "$OUT13B" | jq -r '.ticket_id')" "wp-e2e-split"
ok_eq "13 m14-check success: acs length" "$(printf '%s' "$OUT13B" | jq '.acs | length')" "3"


# ==============================================================================
# 14. WP 1-15 C2: an AC with a Verify line -> plan.claims[].verify is the
#     command and .tool_budget is M14_VERIFY_TOOL_BUDGET (8); an AC with none
#     -> verify:null and tool_budget is INVESTIGATOR_TOOL_BUDGET (5). The
#     claim text stays the exact WP 1-14 template (byte-equal), unaffected
#     by the new keys.
# ==============================================================================
VA_LINE="$(grep -n '^- \*\*A\.\*\*' "$FIX/verify-spec.md" | head -1 | cut -d: -f1)"
VB_LINE="$(grep -n '^- \*\*B\.\*\*' "$FIX/verify-spec.md" | head -1 | cut -d: -f1)"
VERIFY_TRIGGER_ARG="Ship-gate audit for wp-verify-split. This ships under the ACs at ac-source=verify-spec.md (section '## Acceptance criteria', subsection '### wp-verify-split'). Claim under audit: the change ships correctly."
OUT14="$(preflight "$VERIFY_TRIGGER_ARG")"; RC14=$?
ok_eq "14 verify fixture: exit 0" "$RC14" "0"
ok_eq "14 claims[0].verify (A has a Verify line)" \
  "$(printf '%s' "$OUT14" | jq -r '.claims[0].verify')" "bash test-stub.sh"
ok_eq "14 claims[0].tool_budget == 8 (M14_VERIFY_TOOL_BUDGET)" \
  "$(printf '%s' "$OUT14" | jq '.claims[0].tool_budget')" "8"
ok_eq "14 claims[1].verify (B has none) == null" \
  "$(printf '%s' "$OUT14" | jq -c '.claims[1].verify')" "null"
ok_eq "14 claims[1].tool_budget == 5 (INVESTIGATOR_TOOL_BUDGET)" \
  "$(printf '%s' "$OUT14" | jq '.claims[1].tool_budget')" "5"
EXPECT_CLAIM_VA="$(expected_claim A wp-verify-split verify-spec.md "$VA_LINE")"
ok_eq "14 claims[0].claim exact template (verify does not change it)" \
  "$(printf '%s' "$OUT14" | jq -r '.claims[0].claim')" "$EXPECT_CLAIM_VA"
EXPECT_CLAIM_VB="$(expected_claim B wp-verify-split verify-spec.md "$VB_LINE")"
ok_eq "14 claims[1].claim exact template" \
  "$(printf '%s' "$OUT14" | jq -r '.claims[1].claim')" "$EXPECT_CLAIM_VB"

# ==============================================================================
# 15. Case 10 (a second Verify line on one AC): preflight propagates
#     m14-ac-split.sh's fail-closed exit 8, empty stdout.
# ==============================================================================
OUT15="$(preflight "Ship-gate audit for wp-bad-verify-split. ac-source=bad-verify-spec.md" 2>"$HERMETIC_ROOT/err15")"; RC15=$?
ok_eq "15 case 10 (second Verify line): exit 8" "$RC15" "8"
ok_eq "15 case 10 (second Verify line): empty stdout" "$OUT15" ""
if [ "$(wc -l <"$HERMETIC_ROOT/err15")" -eq 1 ] && grep -q '^m14-ac-split: case 10:' "$HERMETIC_ROOT/err15"; then
  ok "15 case 10 (second Verify line): one stderr line, case 10"
else
  fail_msg "15 case 10 (second Verify line): stderr ($(cat "$HERMETIC_ROOT/err15"))"
fi
echo
echo "PASS=$pass FAIL=$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
