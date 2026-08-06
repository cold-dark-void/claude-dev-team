#!/usr/bin/env bash
# Static ACs for council-tier plumbing in engine.sh / index-writer.sh
# (CDT-126, SPEC-013 "Council tiering"). Grading itself lives in
# test-tier-grade.sh; this file covers what the engine does with a tier once
# the caller has resolved one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
IDX="$ROOT/skills/council/index-writer.sh"
FIX="$ROOT/skills/council/fixtures/finalize-task-id"
fail=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tier-engine-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; mkdir -p "$REPO"; git init -q "$REPO"

OUT=""; RC=0
plan() {  # plan <preflight args...>
  OUT="$(bash "$ENGINE" preflight "$@" 2>/dev/null)"
  RC=$?
}

expect() {  # expect <label> <jq-filter>
  if printf '%s' "$OUT" | jq -e "$2" >/dev/null 2>&1; then
    echo "OK: $1"
  else
    echo "FAIL: $1"; echo "     got: $OUT"; fail=1
  fi
}

expect_rc() {  # expect_rc <label> <want>
  if [ "$RC" -eq "$2" ]; then echo "OK: $1"; else echo "FAIL: $1 exit $RC (want $2)"; fail=1; fi
}

ok() {  # ok <label> <condition-cmd...>
  if "${@:2}" >/dev/null 2>&1; then echo "OK: $1"; else echo "FAIL: $1"; fail=1; fi
}

grep_file() {  # grep_file <label> <pattern> <file>
  if grep -qF -- "$2" "$3"; then echo "OK: $1"; else echo "FAIL: $1 (missing: $2)"; fail=1; fi
}

ngrep_file() {  # ngrep_file <label> <pattern> <file>
  if grep -qF -- "$2" "$3"; then echo "FAIL: $1 (present: $2)"; fail=1; else echo "OK: $1"; fi
}

# ---- Default: no --tier is a full run ----------------------------------------
plan --scope claim --scope-arg "x"
expect_rc "no --tier exit 0" 0
expect "no --tier -> council_tier=full" '.council_tier=="full"'
expect "no --tier -> grading_reason distinguishes ungraded" '.grading_reason|test("ungraded")'
expect "full generic keeps both flavors" '.flavors==["paranoid-ic","jaded-senior"]'
expect "full generic runs phase 3" '.phases["3_domain_specialist"].skipped==false'
expect "full generic runs phase 4" '.phases["4_prosecution_defense"].prosecutor.role=="Prosecutor"'
expect "full generic judge gets briefs" \
  '.phases["5_judgment"].inputs==["claims","evidence_bundles","prosecutor_brief","advocate_brief"]
   and (.phases["5_judgment"]|has("briefs_omitted")|not)'

# ---- light + generic ---------------------------------------------------------
plan --scope claim --scope-arg "x" --tier light --grading-reason "clear-low (files=2<=5)"
expect_rc "light exit 0" 0
expect "light -> council_tier=light" '.council_tier=="light" and .grading_reason=="clear-low (files=2<=5)"'
expect "light generic flavors unchanged (already exactly 2)" '.flavors==["paranoid-ic","jaded-senior"]'
expect "light skips phase 3" \
  '.phases["3_domain_specialist"].skipped==true and .phases["3_domain_specialist"].reason=="council_tier: light"'
expect "light skips phase 4" \
  '.phases["4_prosecution_defense"].skipped==true and .phases["4_prosecution_defense"].reason=="council_tier: light"'
expect "light judge gets claims+bundles only" \
  '.phases["5_judgment"].inputs==["claims","evidence_bundles"]
   and .phases["5_judgment"].briefs_omitted==true
   and .phases["5_judgment"].briefs_omitted_reason=="council_tier: light"'

# ---- full + diff-mode: the pre-existing shape skip is NOT replaced ------------
plan --scope diff
expect "full diff-mode keeps all 5 flavors" \
  '.flavors==["logic","security","compliance","quality","simplification"]'
expect "full diff-mode still skips phase 4 on shape alone" \
  '.phases["4_prosecution_defense"].skipped==true
   and .phases["4_prosecution_defense"].reason=="finding[]-shape preset"'

# ---- light + diff-mode: both conditions hold, both recorded ------------------
plan --scope diff --tier light --grading-reason "clear-low"
expect "light diff-mode drops the 3 polish axes" '.flavors==["logic","security"]'
expect "light diff-mode phase-4 reason names both conditions" \
  '.phases["4_prosecution_defense"].reason=="finding[]-shape preset; council_tier: light"'
expect "light diff-mode phase-3 reason stays the diff-mode one" \
  '.phases["3_domain_specialist"].reason=="diff-mode (finding[] flavors cover specialist axes)"'

# ---- --tier full is byte-identical to today's plan (modulo the new keys) -----
bash "$ENGINE" preflight --scope claim --scope-arg "x" \
  | jq -S 'del(.cache_dir,.run_id,.council_tier,.grading_reason)' > "$TMP/default.json"
bash "$ENGINE" preflight --scope claim --scope-arg "x" --tier full --grading-reason "clear-high (loc=900>600)" \
  | jq -S 'del(.cache_dir,.run_id,.council_tier,.grading_reason)' > "$TMP/full.json"
ok "--tier full plan == default plan" diff -q "$TMP/default.json" "$TMP/full.json"

# ---- Rejected tiers ----------------------------------------------------------
plan --scope claim --scope-arg "x" --tier skip
expect_rc "--tier skip rejected (caller short-circuits, never preflight)" 2
plan --scope claim --scope-arg "x" --tier middle
expect_rc "--tier middle rejected (not a council_tier value)" 2
plan --scope claim --scope-arg "x" --tier LIGHT
expect_rc "--tier is case-sensitive" 2

# ---- finalize: light report ---------------------------------------------------
bash "$ENGINE" preflight --scope claim --scope-arg "x" --tier light \
  --grading-reason "triage: docs-only change" > "$TMP/plan-light.json"
bash "$ENGINE" finalize --plan-file "$TMP/plan-light.json" --evidence-file "$FIX/evidence.json" \
  --judge-output "$FIX/judge.json" --report-out "$TMP/light.md" >/dev/null 2>&1
grep_file "light report frontmatter carries council_tier" 'council_tier: "light"' "$TMP/light.md"
grep_file "light report frontmatter carries grading_reason" \
  'grading_reason: "triage: docs-only change"' "$TMP/light.md"
grep_file "light report records the Phase-4 skip in the briefs' place" \
  '_Phase 4 skipped, reason: council_tier: light' "$TMP/light.md"
ngrep_file "light report never emits the not-provided brief stub" \
  '_Brief not provided._' "$TMP/light.md"

# ---- finalize: healthy light run is NOT self-verified (orthogonal fields) ----
grep_file "healthy light run stays verification_mode=full" \
  'verification_mode: "full"' "$TMP/light.md"
ngrep_file "healthy light run has no degradation marker" \
  'self-verified — refuters unavailable' "$TMP/light.md"

# ---- finalize: full report keeps real briefs ---------------------------------
bash "$ENGINE" preflight --scope claim --scope-arg "x" > "$TMP/plan-full.json"
bash "$ENGINE" finalize --plan-file "$TMP/plan-full.json" --evidence-file "$FIX/evidence.json" \
  --judge-output "$FIX/judge.json" --report-out "$TMP/full.md" >/dev/null 2>&1
grep_file "full report frontmatter carries council_tier" 'council_tier: "full"' "$TMP/full.md"
ngrep_file "full report has no Phase-4 skip note" '_Phase 4 skipped' "$TMP/full.md"

# ---- finalize: pre-tiering plan files still finalize (default full) ----------
bash "$ENGINE" finalize --plan-file "$FIX/plan-unbound.json" --evidence-file "$FIX/evidence.json" \
  --judge-output "$FIX/judge.json" --report-out "$TMP/legacy.md" >/dev/null 2>&1
grep_file "plan without council_tier defaults to full" 'council_tier: "full"' "$TMP/legacy.md"

# ---- frontmatter stays parseable with a hostile grading_reason ---------------
bash "$ENGINE" preflight --scope claim --scope-arg "x" --tier light \
  --grading-reason 'he said "ship it"
newline + back\slash' > "$TMP/plan-evil.json"
bash "$ENGINE" finalize --plan-file "$TMP/plan-evil.json" --evidence-file "$FIX/evidence.json" \
  --judge-output "$FIX/judge.json" --report-out "$TMP/evil.md" >/dev/null 2>&1
ok "grading_reason stays one YAML line (embedded newline collapsed)" \
  bash -c "[ \"\$(grep -c '^grading_reason:' '$TMP/evil.md')\" = 1 ] \
           && ! grep -q '^newline + back' '$TMP/evil.md'"
ok "embedded quotes/backslashes are escaped, not emitted raw" \
  grep -qF 'grading_reason: "he said \"ship it\" newline + back\\slash"' "$TMP/evil.md"

# ---- index.json row ----------------------------------------------------------
(
  cd "$REPO" || exit 1
  bash "$ENGINE" preflight --scope claim --scope-arg "x" --tier light \
    --grading-reason "clear-low (files=1<=5, loc=4<=100, no critical-area signal)" \
    --task-id CDT-126-9 > plan.json
  bash "$ENGINE" finalize --plan-file plan.json --evidence-file "$FIX/evidence.json" \
    --judge-output "$FIX/judge.json" --task-id CDT-126-9 >/dev/null 2>&1
) || { echo "FAIL: task-bound light finalize"; fail=1; }
if jq -e '.["CDT-126-9"][0]
          | .council_tier=="light"
            and (.grading_reason|test("clear-low"))
            and has("report_path") and has("created_at")
            and has("max_verdict_confidence") and has("max_finding_confidence")' \
     "$REPO/.claude/council/index.json" >/dev/null 2>&1; then
  echo "OK: index row carries council_tier + grading_reason alongside the existing keys"
else
  echo "FAIL: index row shape"; jq -c . "$REPO/.claude/council/index.json" 2>/dev/null; fail=1
fi

bash "$IDX" T1 /tmp/r.md null 90 bogus "why" >/dev/null 2>&1
ok "index-writer rejects a non-enum council_tier" test $? -eq 1
bash "$IDX" T1 /tmp/r.md null 90 >/dev/null 2>&1
ok "index-writer rejects the pre-CDT-126 4-arg form" test $? -eq 1

# ---- Template injection via grading_reason (council review, CRITICAL) --------
# grading_reason is free text from the tier-triage model. A `{{LATER_VAR}}`
# inside it must never be re-expanded by a subsequent substitution — that let
# attacker-chosen multi-line content land raw at column 0 inside the YAML fences.
bash "$ENGINE" preflight --scope claim --scope-arg "x" --tier light \
  --grading-reason 'routine {{CROSS_REVIEW_RANKINGS}} tail' > "$TMP/plan-inj.json"
bash "$ENGINE" finalize --plan-file "$TMP/plan-inj.json" --evidence-file "$FIX/evidence.json" \
  --judge-output "$FIX/judge.json" --report-out "$TMP/inj.md" \
  --cross-review-rankings 'attacker line one
injected_key: "attacker-controlled"
more' >/dev/null 2>&1
grep_file "a {{VAR}} inside grading_reason stays literal (no re-expansion)" \
  'grading_reason: "routine {{CROSS_REVIEW_RANKINGS}} tail"' "$TMP/inj.md"
ok "nothing injected between the frontmatter fences" \
  bash -c "[ \"\$(awk '/^---\$/{n++; next} n==1' '$TMP/inj.md' | grep -c injected_key)\" = 0 ]"
ok "the legitimate rankings value still renders in its own section" \
  grep -q 'attacker line one' "$TMP/inj.md"

# ---- Malformed plan tier: report and index row must not disagree -------------
jq '.council_tier = "bogus"' "$TMP/plan-light.json" > "$TMP/plan-bad.json"
(
  cd "$REPO" || exit 1
  bash "$ENGINE" finalize --plan-file "$TMP/plan-bad.json" --evidence-file "$FIX/evidence.json" \
    --judge-output "$FIX/judge.json" --task-id CDT-126-BAD >/dev/null 2>&1
)
ok "malformed council_tier fails closed without aborting the run (no exit 6)" test $? -eq 0
if jq -e '.["CDT-126-BAD"][0].council_tier=="full"' "$REPO/.claude/council/index.json" >/dev/null 2>&1; then
  echo "OK: malformed tier writes an index row agreeing with the report (both full)"
else
  echo "FAIL: malformed tier — report/index disagree or no row written"; fail=1
fi

# ---- Phase 3 skip gets a visible audit trail, like Phase 2.5's bypass note ---
grep_file "light report records the Phase-3 skip and its reason" \
  '| Phase 3 (domain specialist) | SKIPPED (reason: council_tier: light) |' "$TMP/light.md"
grep_file "full generic report records Phase 3 as eligible" \
  '| Phase 3 (domain specialist) | ELIGIBLE (runtime classify) |' "$TMP/full.md"

# ---- Workflow path forwards the resolved tier (output parity) ----------------
if node --input-type=module <<'JS' >/dev/null 2>&1
import { runCouncil } from './skills/council/workflow.js'
const agent = async (_p, o) => {
  if (o.phase === 'Investigate') return { bundles: [{ tool_use_id: 't', raw_blob: 'b', file_line: 'f:1', reproducible_command: 'e' }] }
  if (o.phase === 'Phase4') return { briefs: [{ claim_id: 'c0', evidence_against: 'e', requested_verdict: 'UNVERIFIED', supporting_tool_use_ids: ['t'] }], struck_lines: [] }
  if (o.label === 'council-judge') return { verdicts: [{ claim: 'x', verdict: 'UNVERIFIED', confidence: 50, evidence_blob: 'b' }], struck_lines: [] }
  return null
}
const r = await runCouncil({
  args: { scope: 'claim', claim: 'x', council_tier: 'full', grading_reason: 'clear-high (loc=900>600)' },
  agent, phase: () => {}, parallel: async fns => Promise.all(fns.map(f => f())),
})
if (!r.ok) throw new Error(JSON.stringify(r))
if (r.plan.council_tier !== 'full') throw new Error('tier not forwarded: ' + r.plan.council_tier)
if (r.plan.grading_reason !== 'clear-high (loc=900>600)') throw new Error('reason not forwarded: ' + r.plan.grading_reason)
JS
then
  echo "OK: workflow.js forwards --tier/--grading-reason (no re-grade as ungraded)"
else
  echo "FAIL: workflow.js dropped the resolved tier"; fail=1
fi

WF="$ROOT/skills/council/workflow.js"
ok "workflow.js builds the Phase-4 marker from the plan's reason" \
  grep -q "NOT RUN — Phase 4 skipped (reason: " "$WF"
ok "workflow.js no longer hardcodes the finding[]-shape brief sentinel" \
  bash -c "! grep -q '_skipped (finding\[\] shape)_' '$WF'"

# ---- Workflow path is full-only, under its own notice -------------------------
CMD="$ROOT/commands/council.md"
grep_file "council.md emits the tier-specific Workflow fallback notice" \
  'council: council_tier=light unsupported on the Workflow path; falling back to engine.sh' "$CMD"
ok "the tier fallback does not reuse CDV-196's availability string" \
  bash -c "! grep -n 'council_tier' '$CMD' | grep -q 'Workflow unavailable'"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
