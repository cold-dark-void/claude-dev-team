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

# ---- Summary -----------------------------------------------------------------
echo
echo "PASS=$pass FAIL=$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
