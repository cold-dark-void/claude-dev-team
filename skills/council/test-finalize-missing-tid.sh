#!/usr/bin/env bash
# CDT-178 AC6 — finalize missing-tool_use_id strike packaging regression.
# Fixtures: skills/council/fixtures/finalize-missing-tid/
# Isolated from test-tier-engine.sh; invoke standalone.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
FIX="$ROOT/skills/council/fixtures/finalize-missing-tid"
fail=0
pass=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/finalize-missing-tid.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Isolated git repo so task-bound finalize index writes never touch real MROOT.
REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"

# Plan without task_id (avoids index write except case 8).
# report_path stripped — always pass --report-out under TMPDIR.
PLAN_UNBOUND="$TMP/plan-unbound.json"
jq 'del(.task_id) | del(.report_path)' "$FIX/plan-finding.json" > "$PLAN_UNBOUND"

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
# Extract section body between "## Title" and the next "## " heading (or EOF).
section() {  # section <file> <heading-prefix>
  awk -v h="$2" '
    $0 ~ "^## " {
      if (insec) exit
      if (index($0, h) == 1) { insec=1; next }
    }
    insec { print }
  ' "$1"
}

# ---- Case 1–7, 9: mixed finalize ------------------------------------------------
REPORT="$TMP/mixed.md"
META="${REPORT}.finalize-meta.json"
OUT="$TMP/mixed.stdout"
RC=0
bash "$ENGINE" finalize \
  --plan-file "$PLAN_UNBOUND" \
  --evidence-file "$FIX/evidence-mixed.json" \
  --judge-output "$FIX/judge-mixed.json" \
  --report-out "$REPORT" >"$OUT" 2>&1 || RC=$?

# 1. exit 0
if [ "$RC" -eq 0 ]; then ok "1 mixed finalize exit 0"; else fail_msg "1 mixed finalize exit $RC"; fi

# 2. FINDINGS: valid text present; missing-tid descriptions absent from body
FINDINGS_BODY=$(section "$REPORT" "## Findings")
if printf '%s' "$FINDINGS_BODY" | grep -qF 'valid high-conf warning with tool_use_id — must remain unstruck'; then
  ok "2 FINDINGS has valid finding text"
else
  fail_msg "2 FINDINGS missing valid finding text"
fi
for bad in \
  'critical finding missing tool_use_id — must be struck and must not block gate' \
  'finding with empty tool_use_id — must be struck' \
  'finding with whitespace-only tool_use_id — must be struck'
do
  if printf '%s' "$FINDINGS_BODY" | grep -qF -- "$bad"; then
    fail_msg "2 FINDINGS leaked struck description: $bad"
  else
    ok "2 FINDINGS omits struck: ${bad:0:40}…"
  fi
done

# 3. EVIDENCE: finding[] template has no EVIDENCE section; assert packaging
#    does not invent `### \`unknown\`` for blank/missing — only literal valid
#    tid "unknown" (bundle) would appear if evidence were rendered. Missing
#    paths must not produce empty-tid headings; struck trail uses file_line.
STRUCK_BODY=$(section "$REPORT" "## Audit Trail")
if printf '%s' "$STRUCK_BODY" | grep -qF 'evidence bundle missing tool_use_id (file_line=skills/council/engine.sh:2)'; then
  ok "3 missing bundle struck by file_line (no unknown placeholder)"
else
  fail_msg "3 missing bundle strike reason absent"
fi
# Blank/empty must not appear as ### `` headings in report
if grep -qE '^### ``' "$REPORT"; then
  fail_msg "3 empty-tid heading ### \`\` invented"
else
  ok "3 no empty-tid ### headings"
fi
# FINDINGS must not invent tool_use_id: `unknown` for the struck critical
# (only valid unstruck finding has external:…)
if printf '%s' "$FINDINGS_BODY" | grep -qF 'tool_use_id: `external:codex:deadbeef`'; then
  ok "3 FINDINGS cites valid external tid"
else
  fail_msg "3 FINDINGS missing valid external tid"
fi
# Literal valid "unknown" is a bundle tid — packaging must NOT strike it.
# Assert engine did not strike file_line=:1 (the unknown bundle).
if printf '%s' "$STRUCK_BODY" | grep -qF 'file_line=skills/council/engine.sh:1'; then
  fail_msg "3 literal unknown bundle was struck (must remain valid)"
else
  ok "3 literal unknown bundle not struck"
fi

# 4. STRUCK: engine reasons + judge pre-strike merge
grep_file "4 STRUCK has judge pre-strike" 'judge pre-strike' "$REPORT"
grep_file "4 STRUCK has evidence missing reason" \
  'evidence bundle missing tool_use_id (file_line=skills/council/engine.sh:2)' "$REPORT"
grep_file "4 STRUCK has finding missing reason" \
  'finding missing tool_use_id (file=skills/council/engine.sh line=2)' "$REPORT"

# 5. COMMIT_GATE: critical-with-missing-tid does not BLOCK
grep_file "5 COMMIT_GATE PASSED (struck critical ignored)" '**PASSED**' "$REPORT"
ngrep_file "5 COMMIT_GATE not BLOCKED" '**BLOCKED**' "$REPORT"

# 6. Severity table: unstruck only → critical 0, warning 1, nitpick 0
SEV=$(section "$REPORT" "## Severity Summary")
if printf '%s\n' "$SEV" | grep -qE '\| critical \| 0 \|' \
  && printf '%s\n' "$SEV" | grep -qE '\| warning \| 1 \|' \
  && printf '%s\n' "$SEV" | grep -qE '\| nitpick \| 0 \|'; then
  ok "6 severity table unstruck only (c0/w1/n0)"
else
  fail_msg "6 severity table wrong"; printf '%s\n' "$SEV"
fi

# 7. Stdout Struck lines: N == trail length (meta struck_count)
STRUCK_N=$(grep -c '^- ' <<<"$STRUCK_BODY" || true)
STDOUT_N=$(sed -n 's/^Struck lines: //p' "$OUT" | head -1)
META_N=$(jq -r '.struck_count' "$META")
if [ "$STDOUT_N" = "7" ] && [ "$META_N" = "7" ] && [ "$STRUCK_N" = "7" ]; then
  ok "7 Struck lines: 7 == trail length == meta (1 pre + 3 bundle + 3 finding)"
else
  fail_msg "7 Struck count mismatch stdout=$STDOUT_N meta=$META_N trail=$STRUCK_N (want 7)"
fi

# 9. Valid unknown / external / self-verify not struck
# external finding remains; unknown bundle not in strike list (case 3).
grep_file "9 valid external finding unstruck" \
  'tool_use_id: `external:codex:deadbeef`' "$REPORT"
# Optional AC5: null tool_use_id struck; self-verify-… not struck
JUDGE_SV="$TMP/judge-self-verify.json"
EVID_SV="$TMP/evidence-self-verify.json"
cat >"$JUDGE_SV" <<'EOF'
{
  "findings": [
    {
      "file": "skills/council/engine.sh",
      "line": 50,
      "severity": "warning",
      "category": "correctness",
      "description": "self-verify tid must remain unstruck",
      "suggestion": "keep",
      "confidence": 90,
      "tool_use_id": "self-verify-orchestrator-1"
    },
    {
      "file": "skills/council/engine.sh",
      "line": 51,
      "severity": "warning",
      "category": "correctness",
      "description": "null tool_use_id must be struck",
      "suggestion": "strike",
      "confidence": 88,
      "tool_use_id": null
    }
  ],
  "struck_lines": []
}
EOF
cat >"$EVID_SV" <<'EOF'
[
  {
    "tool_use_id": "self-verify-orchestrator-1",
    "raw_blob": "self-verify bundle",
    "file_line": "skills/council/engine.sh:50",
    "reproducible_command": "true"
  },
  {
    "tool_use_id": null,
    "raw_blob": "null tid bundle",
    "file_line": "skills/council/engine.sh:51",
    "reproducible_command": "true"
  }
]
EOF
REPORT_SV="$TMP/self-verify.md"
OUT_SV="$TMP/self-verify.stdout"
RC_SV=0
bash "$ENGINE" finalize \
  --plan-file "$PLAN_UNBOUND" \
  --evidence-file "$EVID_SV" \
  --judge-output "$JUDGE_SV" \
  --report-out "$REPORT_SV" >"$OUT_SV" 2>&1 || RC_SV=$?
if [ "$RC_SV" -eq 0 ]; then ok "9 self-verify fixture exit 0"; else fail_msg "9 self-verify fixture exit $RC_SV"; fi
grep_file "9 self-verify finding unstruck" \
  'tool_use_id: `self-verify-orchestrator-1`' "$REPORT_SV"
ngrep_file "9 null tid finding struck (not in FINDINGS)" \
  'null tool_use_id must be struck' "$REPORT_SV"
grep_file "9 null finding in STRUCK" \
  'finding missing tool_use_id (file=skills/council/engine.sh line=51)' "$REPORT_SV"
grep_file "9 null bundle in STRUCK" \
  'evidence bundle missing tool_use_id (file_line=skills/council/engine.sh:51)' "$REPORT_SV"

# ---- Case 8: index max_finding_confidence among unstruck only (85 not 99) ----
PLAN_BOUND="$TMP/plan-bound.json"
jq '.task_id="T-178" | del(.report_path)' "$FIX/plan-finding.json" > "$PLAN_BOUND"
REPORT_BOUND="$TMP/bound.md"
(
  cd "$REPO" || exit 1
  bash "$ENGINE" finalize \
    --plan-file "$PLAN_BOUND" \
    --evidence-file "$FIX/evidence-mixed.json" \
    --judge-output "$FIX/judge-mixed.json" \
    --report-out "$REPORT_BOUND" >/dev/null 2>&1
) || { fail_msg "8 task-bound finalize failed"; }
IDX="$REPO/.claude/council/index.json"
if [ -f "$IDX" ] && jq -e '.["T-178"][0].max_finding_confidence == 85' "$IDX" >/dev/null 2>&1; then
  ok "8 index max_finding_confidence == 85 (unstruck only, not struck 99)"
else
  fail_msg "8 index max_finding_confidence wrong"
  jq -c . "$IDX" 2>/dev/null || true
fi
# Guard: never wrote into real worktree index via accidental cwd
if [ -f "$ROOT/.claude/council/index.json" ] && grep -q 'T-178' "$ROOT/.claude/council/index.json" 2>/dev/null; then
  # Only fail if our run polluted — fixture may not exist; skip if absent
  fail_msg "8 polluted $ROOT/.claude/council/index.json"
else
  ok "8 index isolated under test REPO"
fi

# ---- Case 10: all-struck fixture ------------------------------------------------
REPORT_ALL="$TMP/all-struck.md"
OUT_ALL="$TMP/all-struck.stdout"
RC_ALL=0
bash "$ENGINE" finalize \
  --plan-file "$PLAN_UNBOUND" \
  --evidence-file "$FIX/evidence-mixed.json" \
  --judge-output "$FIX/judge-all-struck.json" \
  --report-out "$REPORT_ALL" >"$OUT_ALL" 2>&1 || RC_ALL=$?
if [ "$RC_ALL" -eq 0 ]; then ok "10 all-struck exit 0"; else fail_msg "10 all-struck exit $RC_ALL"; fi
FINDINGS_ALL=$(section "$REPORT_ALL" "## Findings")
if printf '%s' "$FINDINGS_ALL" | grep -qF '_No findings._'; then
  ok "10 findings body empty (_No findings._)"
else
  fail_msg "10 findings body not empty"
fi
# Ensure no residual finding headings from struck items
if printf '%s' "$FINDINGS_ALL" | grep -qE '^### \['; then
  fail_msg "10 findings body still has ### [ headings"
else
  ok "10 findings body has no finding headings"
fi
STRUCK_ALL=$(section "$REPORT_ALL" "## Audit Trail")
if printf '%s' "$STRUCK_ALL" | grep -q '^- '; then
  ok "10 struck non-empty"
else
  fail_msg "10 struck empty"
fi
ngrep_file "10 all-struck critical description omitted" \
  'all-struck critical missing tid' "$REPORT_ALL"

# ---- Case 11: struck_lines objects render as text, not Python dict repr -----
EVID_F22="$TMP/evidence-f22.json"
JUDGE_F22="$TMP/judge-f22.json"
cat >"$EVID_F22" <<'EOF'
[{"tool_use_id":"t-f22","raw_blob":"blob","file_line":"a.js:1","reproducible_command":"true"}]
EOF
cat >"$JUDGE_F22" <<'EOF'
{
  "findings": [{
    "file": "a.js", "line": 1, "severity": "warning", "category": "quality",
    "description": "kept", "suggestion": "none", "confidence": 90,
    "tool_use_id": "t-f22"
  }],
  "struck_lines": [{"claim_id": "c0", "line": "the checkbox was checked", "reason": "no tool_use_id"}]
}
EOF
REPORT_F22="$TMP/f22.md"
RC_F22=0
bash "$ENGINE" finalize \
  --plan-file "$PLAN_UNBOUND" \
  --evidence-file "$EVID_F22" \
  --judge-output "$JUDGE_F22" \
  --report-out "$REPORT_F22" >"$TMP/f22.stdout" 2>&1 || RC_F22=$?
if [ "$RC_F22" -eq 0 ]; then ok "11 struck-object finalize exit 0"; else fail_msg "11 struck-object finalize exit $RC_F22"; fi
grep_file "11 struck object renders claim, line, and reason" \
  'c0 — the checkbox was checked — no tool_use_id' "$REPORT_F22"
ngrep_file "11 struck object is not a Python dict repr" \
  "{'claim_id'" "$REPORT_F22"

# ---- CDT-303 / CDT-390 / CDT-317 / CDT-401 / CDT-422 / W2-15 / W1-56 ----------
IDX="$ROOT/skills/council/index-writer.sh"
PLAN_VERDICT="$TMP/plan-verdict.json"
jq 'del(.task_id) | del(.report_path) | .output_shape="verdict[]" | .preset="generic" | .scope="claim" | .slug="cdt303" | .scope_arg="named claim" | .phases["4_prosecution_defense"] = {"prosecutor":{"role":"Prosecutor"}}' \
  "$FIX/plan-finding.json" > "$PLAN_VERDICT"
EVID_OK="$TMP/evidence-ok.json"
cat >"$EVID_OK" <<'EOF'
[{"tool_use_id":"t-ok","raw_blob":"QUOTE-OK blob text","file_line":"a:1","reproducible_command":"true"}]
EOF

# CDT-303: each bad verdict is struck and excluded from max_verdict_confidence.
JUDGE_BAD="$TMP/judge-bad.json"
cat >"$JUDGE_BAD" <<'EOF'
{"verdicts":[
  {"claim_id":"c7","claim":"named claim","verdict":"VERIFIED","confidence":80,"evidence_blob":"QUOTE-OK"},
  {"claim_id":"c-bogus","claim":"bogus","verdict":"BOGUS","confidence":99,"evidence_blob":"QUOTE-OK"},
  {"claim_id":"c-empty","claim":"empty","verdict":"VERIFIED","confidence":95,"evidence_blob":""},
  {"claim_id":"c-101","claim":"oob","verdict":"VERIFIED","confidence":101,"evidence_blob":"QUOTE-OK"},
  {"claim_id":"c-foreign","claim":"foreign","verdict":"VERIFIED","confidence":99,"evidence_blob":"QUOTE-OK","tool_use_id":"not-a-bundle"},
  {"claim_id":"c-blob","claim":"blob","verdict":"VERIFIED","confidence":99,"evidence_blob":"NOT-IN-ANY-BUNDLE"}
],"struck_lines":[]}
EOF
REPORT_BAD="$TMP/judge-bad.md"
(
  cd "$REPO" || exit 1
  bash "$ENGINE" finalize --plan-file "$PLAN_VERDICT" --evidence-file "$EVID_OK" \
    --judge-output "$JUDGE_BAD" --task-id CDT-303-MIX --report-out "$REPORT_BAD"
) >"$TMP/judge-bad.stdout" 2>&1 || true
if [ "$(jq -r '.["CDT-303-MIX"][0].max_verdict_confidence' "$REPO/.claude/council/index.json")" = "80" ]; then
  ok "303 max_verdict_confidence is 80 (struck 99/101 excluded)"
else
  fail_msg "303 max_verdict_confidence not 80"
  jq -c '.["CDT-303-MIX"][0]' "$REPO/.claude/council/index.json" 2>/dev/null || true
fi
grep_file "303 valid claim_id renders" '### Claim c7:' "$REPORT_BAD"
ngrep_file "303 no Claim ? heading" '### Claim ?:' "$REPORT_BAD"
if section "$REPORT_BAD" "## Verdicts" | grep -qF 'BOGUS'; then
  fail_msg "303 BOGUS rendered as an unstruck verdict"
else
  ok "303 BOGUS not in verdicts body"
fi
for reason in \
  'verdict BOGUS outside taxonomy' \
  'verdict evidence_blob empty' \
  'verdict confidence not in 0..100 after floor' \
  'verdict tool_use_id not in evidence bundles' \
  'verdict evidence_blob is not a substring of a bundle raw_blob'
do
  grep_file "303 struck: ${reason:0:32}" "$reason" "$REPORT_BAD"
done
grep_file "303 stdout unstruck VERIFIED only" \
  'VERIFIED: 1  PARTIALLY_VERIFIED: 0  UNVERIFIED: 0  CONTRADICTED: 0  FABRICATED: 0' \
  "$TMP/judge-bad.stdout"
ngrep_file "303 stdout does not list BOGUS" 'BOGUS' "$TMP/judge-bad.stdout"

# CDT-390: top-level array judge exits 0 and counters read .verdicts.
JUDGE_ARR="$TMP/judge-array.json"
printf '%s\n' '[{"claim_id":"c0","claim":"arr","verdict":"VERIFIED","confidence":91,"evidence_blob":"QUOTE-OK"}]' >"$JUDGE_ARR"
REPORT_ARR="$TMP/array.md"
RC_ARR=0
bash "$ENGINE" finalize --plan-file "$PLAN_VERDICT" --evidence-file "$EVID_OK" \
  --judge-output "$JUDGE_ARR" --report-out "$REPORT_ARR" >"$TMP/array.stdout" 2>&1 || RC_ARR=$?
if [ "$RC_ARR" -eq 0 ]; then ok "390 array judge exit 0"; else fail_msg "390 array judge exit $RC_ARR"; cat "$TMP/array.stdout"; fi
grep_file "390 stdout VERIFIED count" 'VERIFIED: 1' "$TMP/array.stdout"
# finding[] array
JUDGE_FARR="$TMP/judge-farray.json"
printf '%s\n' '[{"file":"a.js","line":1,"severity":"warning","category":"quality","description":"array finding","suggestion":"keep","confidence":90,"tool_use_id":"t-ok"}]' >"$JUDGE_FARR"
REPORT_FARR="$TMP/farray.md"
RC_FARR=0
bash "$ENGINE" finalize --plan-file "$PLAN_UNBOUND" --evidence-file "$EVID_OK" \
  --judge-output "$JUDGE_FARR" --report-out "$REPORT_FARR" >"$TMP/farray.stdout" 2>&1 || RC_FARR=$?
if [ "$RC_FARR" -eq 0 ]; then ok "390 finding array exit 0"; else fail_msg "390 finding array exit $RC_FARR"; fi
grep_file "390 stdout warning count" 'warning: 1' "$TMP/farray.stdout"

# CDT-317: FABRICATED@95 fails the task gate; VERIFIED@90 passes threshold 80.
JUDGE_FAB="$TMP/judge-fab.json"
cat >"$JUDGE_FAB" <<'EOF'
{"verdicts":[{"claim_id":"c0","claim":"fab","verdict":"FABRICATED","confidence":95,"evidence_blob":"QUOTE-OK"}],"struck_lines":[]}
EOF
(
  cd "$REPO" || exit 1
  bash "$ENGINE" finalize --plan-file "$PLAN_VERDICT" --evidence-file "$EVID_OK" \
    --judge-output "$JUDGE_FAB" --task-id CDT-317-FAB --report-out "$TMP/fab.md"
) >/dev/null 2>&1 || fail_msg "317 fabricated finalize failed"
if jq -e '.["CDT-317-FAB"][0].worst_verdict=="FABRICATED" and .["CDT-317-FAB"][0].max_verified_confidence==null and .["CDT-317-FAB"][0].max_verdict_confidence==95' \
    "$REPO/.claude/council/index.json" >/dev/null; then
  ok "317 index row worst_verdict FABRICATED and no verified confidence"
else
  fail_msg "317 index row shape"
  jq -c '.["CDT-317-FAB"][0]' "$REPO/.claude/council/index.json" 2>/dev/null || true
fi
mkdir -p "$REPO/.claude/tasks"
printf '%s\n' '{"task_id":"CDT-317-FAB","requires_council":true,"status":"in_progress"}' >"$REPO/.claude/tasks/CDT-317-FAB.json"
bash "$ROOT/skills/init-orchestration/check-hook-templates.sh" --extract task-completed >"$TMP/task-completed.sh"
chmod +x "$TMP/task-completed.sh"
RC_GATE=0
printf '%s' '{"task_id":"CDT-317-FAB"}' | (cd "$REPO" && bash "$TMP/task-completed.sh") >"$TMP/gate-fab.out" 2>"$TMP/gate-fab.err" || RC_GATE=$?
if [ "$RC_GATE" -eq 2 ] && grep -q 'FABRICATED' "$TMP/gate-fab.err"; then
  ok "317 FABRICATED@95 fails the task gate"
else
  fail_msg "317 gate rc=$RC_GATE (want 2)"; cat "$TMP/gate-fab.err"
fi
JUDGE_OKV="$TMP/judge-okv.json"
cat >"$JUDGE_OKV" <<'EOF'
{"verdicts":[{"claim_id":"c0","claim":"ok","verdict":"VERIFIED","confidence":90,"evidence_blob":"QUOTE-OK"}],"struck_lines":[]}
EOF
(
  cd "$REPO" || exit 1
  bash "$ENGINE" finalize --plan-file "$PLAN_VERDICT" --evidence-file "$EVID_OK" \
    --judge-output "$JUDGE_OKV" --task-id CDT-317-OK --report-out "$TMP/okv.md"
) >/dev/null 2>&1 || fail_msg "317 verified finalize failed"
if jq -e '.["CDT-317-OK"][0].max_verified_confidence==90 and .["CDT-317-OK"][0].worst_verdict=="VERIFIED"' \
    "$REPO/.claude/council/index.json" >/dev/null; then
  ok "317 VERIFIED@90 writes max_verified_confidence 90"
else
  fail_msg "317 verified index row"
fi
printf '%s\n' '{"task_id":"CDT-317-OK","requires_council":true,"status":"in_progress"}' >"$REPO/.claude/tasks/CDT-317-OK.json"
printf '%s\n' '{"council":{"taskgate":{"min_confidence":80}}}' >"$REPO/.claude/settings.json"
RC_OK=0
printf '%s' '{"task_id":"CDT-317-OK"}' | (cd "$REPO" && bash "$TMP/task-completed.sh") >"$TMP/gate-ok.out" 2>"$TMP/gate-ok.err" || RC_OK=$?
if [ "$RC_OK" -eq 0 ]; then ok "317 VERIFIED@90 passes threshold 80"; else fail_msg "317 pass gate rc=$RC_OK"; cat "$TMP/gate-ok.err"; fi

# CDT-401: dict and list briefs do not crash; report contains the text.
EVID_BRIEF="$TMP/evidence-brief.json"
cat >"$EVID_BRIEF" <<'EOF'
{"bundles":[{"tool_use_id":"t-ok","raw_blob":"QUOTE-OK blob text","file_line":"a:1","reproducible_command":"true"}],
 "prosecutor_brief":{"briefs":[{"claim_id":"c0","requested_verdict":"VERIFIED","argument":"prosecutor says BRIEF-ARG","supporting_tool_use_ids":["t-ok"]}]},
 "advocate_brief":[{"claim_id":"c0","requested_verdict":"UNVERIFIED","text":"advocate says BRIEF-TEXT","supporting_tool_use_ids":["t-ok"]}]}
EOF
REPORT_BRIEF="$TMP/brief.md"
RC_BRIEF=0
bash "$ENGINE" finalize --plan-file "$PLAN_VERDICT" --evidence-file "$EVID_BRIEF" \
  --judge-output "$JUDGE_OKV" --report-out "$REPORT_BRIEF" >"$TMP/brief.stdout" 2>&1 || RC_BRIEF=$?
if [ "$RC_BRIEF" -eq 0 ]; then ok "401 dict/list briefs exit 0"; else fail_msg "401 briefs exit $RC_BRIEF"; cat "$TMP/brief.stdout"; fi
grep_file "401 prosecutor argument" 'prosecutor says BRIEF-ARG' "$REPORT_BRIEF"
grep_file "401 advocate text" 'advocate says BRIEF-TEXT' "$REPORT_BRIEF"

# CDT-422: confidence filter, empty diff_summary, empty suggestion, no literal placeholder.
PLAN_FILT="$TMP/plan-filt.json"
jq '.confidence_filter_threshold=80 | .diff_summary="" | .scope_arg="" | .applicable_specs=""' "$PLAN_UNBOUND" >"$PLAN_FILT"
JUDGE_LOW="$TMP/judge-low.json"
cat >"$JUDGE_LOW" <<'EOF'
{"findings":[
  {"file":"a.js","line":1,"severity":"critical","category":"security","description":"low crit must not block","suggestion":"","confidence":79,"tool_use_id":"t-ok"},
  {"file":"a.js","line":2,"severity":"bogus","category":"quality","description":"bad severity finding","suggestion":"x","confidence":90,"tool_use_id":"t-ok"},
  {"file":"a.js","line":3,"severity":"warning","category":"quality","description":"foreign tid finding","suggestion":"x","confidence":90,"tool_use_id":"foreign-tid"}
],"struck_lines":[]}
EOF
REPORT_LOW="$TMP/low.md"
RC_LOW=0
bash "$ENGINE" finalize --plan-file "$PLAN_FILT" --evidence-file "$EVID_OK" \
  --judge-output "$JUDGE_LOW" --report-out "$REPORT_LOW" >"$TMP/low.stdout" 2>&1 || RC_LOW=$?
if [ "$RC_LOW" -eq 0 ]; then ok "422 filter finalize exit 0"; else fail_msg "422 filter exit $RC_LOW"; cat "$TMP/low.stdout"; fi
if section "$REPORT_LOW" "## Findings" | grep -qF 'low crit must not block'; then
  fail_msg "422 low critical still an unstruck finding"
else
  ok "422 low critical not an unstruck finding"
fi
grep_file "422 gate PASSED" '**PASSED**' "$REPORT_LOW"
ngrep_file "422 gate not BLOCKED" '**BLOCKED**' "$REPORT_LOW"
grep_file "422 strike names threshold" 'confidence_filter_threshold 80' "$REPORT_LOW"
grep_file "422 bad severity struck" 'finding severity bogus outside taxonomy' "$REPORT_LOW"
grep_file "422 foreign tid struck" 'finding tool_use_id not in evidence bundles' "$REPORT_LOW"
grep_file "422 stdout ignores below-threshold critical" \
  'critical: 0  warning: 0  nitpick: 0' "$TMP/low.stdout"
ngrep_file "422 low critical absent from stdout" 'low crit must not block' "$TMP/low.stdout"
# Failed-judge finding stays unstruck at confidence 50. A normal 79 critical
# in the same run is still struck and does not increment the stdout count.
JUDGE_DEG="$TMP/judge-degraded.json"
cat >"$JUDGE_DEG" <<'EOF'
{"findings":[
  {"file":"a.js","line":1,"severity":"critical","category":"security","description":"low crit must not block","suggestion":"","confidence":79,"tool_use_id":"t-ok"},
  {"file":"a.js","line":9,"severity":"critical","category":"design","description":"(degraded-judge: council-judge spawn failed) still blocks","suggestion":"re-run","confidence":50,"tool_use_id":"t-ok"}
],"struck_lines":[]}
EOF
REPORT_DEG="$TMP/degraded.md"
RC_DEG=0
bash "$ENGINE" finalize --plan-file "$PLAN_FILT" --evidence-file "$EVID_OK" \
  --judge-output "$JUDGE_DEG" --report-out "$REPORT_DEG" >"$TMP/degraded.stdout" 2>&1 || RC_DEG=$?
if [ "$RC_DEG" -eq 0 ]; then ok "degraded-judge finalize exit 0"; else fail_msg "degraded-judge exit $RC_DEG"; cat "$TMP/degraded.stdout"; fi
grep_file "degraded-judge stays unstruck" '(degraded-judge: council-judge spawn failed) still blocks' "$REPORT_DEG"
grep_file "degraded-judge blocks the commit gate" '**BLOCKED**' "$REPORT_DEG"
if section "$REPORT_DEG" "## Findings" | grep -qF 'low crit must not block'; then
  fail_msg "degraded run kept the 79 critical"
else
  ok "degraded run still strikes the 79 critical"
fi
grep_file "degraded stdout counts only the failed judge" \
  'critical: 1  warning: 0  nitpick: 0' "$TMP/degraded.stdout"
ngrep_file "degraded stdout omits the 79 critical" 'low crit must not block' "$TMP/degraded.stdout"
grep_file "422 empty diff summary" '_Not available._' "$REPORT_LOW"
grep_file "422 empty applicable specs" '_None matched._' "$REPORT_LOW"
if section "$REPORT_LOW" "## Action Items" | grep -qF 'desc —  [confidence'; then
  fail_msg "422 empty suggestion rendered the suggestion clause"
else
  ok "422 empty suggestion omits the suggestion clause"
fi
# The low finding has an empty suggestion; if it were unstruck the clause would show.
# A kept finding with empty suggestion is checked on its own report.
JUDGE_EMPTY_SUGG="$TMP/judge-empty-sugg.json"
cat >"$JUDGE_EMPTY_SUGG" <<'EOF'
{"findings":[{"file":"a.js","line":4,"severity":"warning","category":"quality","description":"empty sugg desc","suggestion":"","confidence":90,"tool_use_id":"t-ok"}],"struck_lines":[]}
EOF
PLAN_NOSUG="$TMP/plan-nosug.json"
jq 'del(.confidence_filter_threshold)' "$PLAN_UNBOUND" >"$PLAN_NOSUG"
REPORT_SUGG="$TMP/sugg.md"
bash "$ENGINE" finalize --plan-file "$PLAN_NOSUG" --evidence-file "$EVID_OK" \
  --judge-output "$JUDGE_EMPTY_SUGG" --report-out "$REPORT_SUGG" >/dev/null 2>&1 || fail_msg "422 empty-sugg finalize failed"
if grep -qF 'empty sugg desc —  [confidence' "$REPORT_SUGG"; then
  fail_msg "422 empty suggestion clause present"
else
  ok "422 empty suggestion clause absent"
fi
grep_file "422 empty suggestion keeps desc and confidence" 'empty sugg desc [confidence: 90]' "$REPORT_SUGG"
if grep -qF '`{{FINDINGS}}`' "$ROOT/skills/council/templates/report-finding.md"; then
  fail_msg "422 template still has a backtick FINDINGS placeholder"
else
  ok "422 template has no backtick FINDINGS placeholder"
fi
grep_file "422 template keeps the real placeholder" '{{FINDINGS}}' "$ROOT/skills/council/templates/report-finding.md"

# W2-15: invalid task-id writes no report. Empty task_id rejected by index-writer.
REPORT_TRAV="$TMP/should-not-exist-task.md"
RC_TRAV=0
bash "$ENGINE" finalize --plan-file "$PLAN_UNBOUND" --evidence-file "$EVID_OK" \
  --judge-output "$JUDGE_FARR" --report-out "$REPORT_TRAV" --task-id 'a/b' >/dev/null 2>&1 || RC_TRAV=$?
if [ "$RC_TRAV" -ne 0 ] && [ ! -e "$REPORT_TRAV" ]; then
  ok "W2-15 task-id a/b exits non-zero and writes no report"
else
  fail_msg "W2-15 task-id a/b rc=$RC_TRAV file=$([ -e "$REPORT_TRAV" ] && echo present || echo absent)"
fi
RC_DOTS=0
bash "$ENGINE" finalize --plan-file "$PLAN_UNBOUND" --evidence-file "$EVID_OK" \
  --judge-output "$JUDGE_FARR" --report-out "$REPORT_TRAV" --task-id '..' >/dev/null 2>&1 || RC_DOTS=$?
if [ "$RC_DOTS" -ne 0 ] && [ ! -e "$REPORT_TRAV" ]; then
  ok "W1-56 task-id .. rejected"
else
  fail_msg "W1-56 task-id .. rc=$RC_DOTS"
fi
PLAN_SLUG="$TMP/plan-slug.json"
jq --arg rp "$TMP/slug-escape.md" '.slug="../evil" | .report_path=$rp | del(.task_id)' "$PLAN_UNBOUND" >"$PLAN_SLUG"
RC_SLUG=0
bash "$ENGINE" finalize --plan-file "$PLAN_SLUG" --evidence-file "$EVID_OK" \
  --judge-output "$JUDGE_FARR" >/dev/null 2>&1 || RC_SLUG=$?
if [ "$RC_SLUG" -ne 0 ] && [ ! -e "$TMP/slug-escape.md" ]; then
  ok "W1-56 slug ../evil rejected before write"
else
  fail_msg "W1-56 slug traversal rc=$RC_SLUG"
fi
RC_EMPTY=0
(cd "$REPO" && bash "$IDX" "" "$TMP/r.md" null null full "empty") >/dev/null 2>&1 || RC_EMPTY=$?
if [ "$RC_EMPTY" -ne 0 ]; then ok "W2-15 empty task_id rejected"; else fail_msg "W2-15 empty task_id accepted"; fi
RC_SKIP=0
(cd "$REPO" && bash "$IDX" CDT-SKIP-1 "$TMP/r.md" null null skip "dri skip") >/dev/null 2>&1 || RC_SKIP=$?
if [ "$RC_SKIP" -eq 0 ] && jq -e '.["CDT-SKIP-1"][0].council_tier=="skip"' "$REPO/.claude/council/index.json" >/dev/null; then
  ok "W2-15 non-empty skip-tier id accepted"
else
  fail_msg "W2-15 skip-tier id rejected rc=$RC_SKIP"
fi

# W1-56: repair, exit codes, resolve-task-id, --last, cache cleanup, concurrency.
# Report-path collision is already asserted in test-report-path-reserve.sh (skipped here).
JUDGE_FENCE="$TMP/judge-fence.json"
cat >"$JUDGE_FENCE" <<'EOF'
```json
{"verdicts":[{"claim_id":"c0","claim":"fence","verdict":"VERIFIED","confidence":88,"evidence_blob":"QUOTE-OK"}],"struck_lines":[]}
```
EOF
REPORT_FENCE="$TMP/fence.md"
RC_FENCE=0
bash "$ENGINE" finalize --plan-file "$PLAN_VERDICT" --evidence-file "$EVID_OK" \
  --judge-output "$JUDGE_FENCE" --report-out "$REPORT_FENCE" >"$TMP/fence.stdout" 2>&1 || RC_FENCE=$?
if [ "$RC_FENCE" -eq 0 ]; then ok "W1-56 judge fence strip exit 0"; else fail_msg "W1-56 fence exit $RC_FENCE"; cat "$TMP/fence.stdout"; fi
EVID_BS="$TMP/evidence-bs.json"
printf '%s\n' '[{"tool_use_id":"t-bs","raw_blob":"re \d path","file_line":"a:1","reproducible_command":"true"}]' >"$EVID_BS"
JUDGE_BS="$TMP/judge-bs.json"
printf '%s\n' '{"verdicts":[{"claim_id":"c0","claim":"bs","verdict":"VERIFIED","confidence":70,"evidence_blob":"re \d path"}],"struck_lines":[]}' >"$JUDGE_BS"
REPORT_BS="$TMP/bs.md"
RC_BS=0
bash "$ENGINE" finalize --plan-file "$PLAN_VERDICT" --evidence-file "$EVID_BS" \
  --judge-output "$JUDGE_BS" --report-out "$REPORT_BS" >"$TMP/bs.stdout" 2>&1 || RC_BS=$?
if [ "$RC_BS" -eq 0 ]; then ok "W1-56 bad-backslash repair exit 0"; else fail_msg "W1-56 backslash exit $RC_BS"; cat "$TMP/bs.stdout"; fi
RC4=0
(cd "$REPO" && bash "$ENGINE" preflight --scope claim --scope-arg x --preset nope >/dev/null 2>&1) || RC4=$?
if [ "$RC4" -eq 4 ]; then ok "W1-56 exit 4 unknown preset"; else fail_msg "W1-56 exit 4 got $RC4"; fi
printf '%s\n' '[]' >"$TMP/evidence-empty.json"
RC5=0
bash "$ENGINE" finalize --plan-file "$PLAN_VERDICT" --evidence-file "$TMP/evidence-empty.json" \
  --judge-output "$JUDGE_OKV" --report-out "$TMP/exit5.md" >/dev/null 2>&1 || RC5=$?
if [ "$RC5" -eq 5 ] && [ ! -e "$TMP/exit5.md" ]; then ok "W1-56 exit 5 empty evidence"; else fail_msg "W1-56 exit 5 got $RC5"; fi
printf '%s\n' 'not-json' >"$TMP/judge-badjson.json"
RC7=0
bash "$ENGINE" finalize --plan-file "$PLAN_VERDICT" --evidence-file "$EVID_OK" \
  --judge-output "$TMP/judge-badjson.json" --report-out "$TMP/exit7.md" >/dev/null 2>&1 || RC7=$?
if [ "$RC7" -eq 7 ] && [ ! -e "$TMP/exit7.md" ]; then ok "W1-56 exit 7 bad judge JSON"; else fail_msg "W1-56 exit 7 got $RC7"; fi
GOT_FLAG=$(bash "$ENGINE" resolve-task-id --task-id FLAGID)
GOT_ENV=$(CLAUDE_TASK_ID=ENVID bash "$ENGINE" resolve-task-id)
GOT_BOTH=$(CLAUDE_TASK_ID=ENVID bash "$ENGINE" resolve-task-id --task-id FLAGID)
if [ "$GOT_FLAG" = "FLAGID" ] && [ "$GOT_ENV" = "ENVID" ] && [ "$GOT_BOTH" = "FLAGID" ]; then
  ok "W1-56 resolve-task-id flag then CLAUDE_TASK_ID"
else
  fail_msg "W1-56 resolve-task-id flag=$GOT_FLAG env=$GOT_ENV both=$GOT_BOTH"
fi
LAST_JSON=$(cd "$REPO" && bash "$ENGINE" preflight --scope session --scope-arg s --last 4)
if printf '%s' "$LAST_JSON" | jq -e '.slug=="session-last-4"' >/dev/null; then
  ok "W1-56 --last slug"
else
  fail_msg "W1-56 --last slug"
fi
CACHE_DIR=$(printf '%s' "$LAST_JSON" | jq -r '.cache_dir // empty')
printf '%s\n' "$LAST_JSON" >"$TMP/plan-last.json"
if [ -n "$CACHE_DIR" ] && [ -d "$CACHE_DIR" ]; then
  bash "$ENGINE" finalize --plan-file "$TMP/plan-last.json" --evidence-file "$EVID_OK" \
    --judge-output "$JUDGE_OKV" --report-out "$TMP/cache.md" >/dev/null 2>&1 || true
  if [ ! -d "$CACHE_DIR" ]; then ok "W1-56 finalize removes cache dir"; else fail_msg "W1-56 cache dir remains"; rm -rf -- "$CACHE_DIR"; fi
else
  fail_msg "W1-56 preflight did not create cache dir"
fi
(
  cd "$REPO" || exit 1
  bash "$IDX" CDT-W156-A "$TMP/r.md" null null full "a" &
  bash "$IDX" CDT-W156-B "$TMP/r.md" null null full "b" &
  wait
) || fail_msg "W1-56 concurrent index-writer failed"
if jq -e '.["CDT-W156-A"] and .["CDT-W156-B"]' "$REPO/.claude/council/index.json" >/dev/null \
   && jq -e . "$REPO/.claude/council/index.json" >/dev/null; then
  ok "W1-56 two index writers both rows valid JSON"
else
  fail_msg "W1-56 concurrent index rows missing"
fi

# ---- Summary -----------------------------------------------------------------
echo
echo "PASS=$pass FAIL=$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
