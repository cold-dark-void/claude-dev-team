#!/usr/bin/env bash
# test-residue.sh — trigger-(c) council-residue appeal bite-tests
# (SPEC-039 M20/M21/M22, epic child C6/CDT-561).
#
# Machine-check: bash skills/advisor/test-residue.sh  (exit 0)
#
# Every AC sub-clause of the SPEC-039 `### CDT-561` section gets its own
# named run-output PASS line (the C8/M14 lesson: an aggregate or
# source-assert-only name is not per-clause run output). Run-output exhibits
# are written BEFORE any council on this claim.
#
# Hermetic: everything lives under TMPDIR; the advisor state root is a
# scratch ADVISOR_STATE_ROOT; the shared models.local.json is backed up and
# restored under flock (same discipline as test.sh / test-classify.sh — the
# map file is shared, so concurrent suite runs must serialize).

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1
RESIDUE="$ROOT/skills/advisor/residue.sh"
APPEAL="$ROOT/skills/advisor/appeal.sh"
ASK="$ROOT/skills/advisor/ask.sh"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/advisor-residue-test.XXXXXX")
[ -d "$TMP" ] || { echo "test-residue.sh: mktemp -d failed (check TMPDIR)" >&2; exit 1; }

# Shared map backup/restore under a global lock (fd 9; closes after the trap).
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MAP="$MROOT/.claude/dev-team/models.local.json"
mkdir -p "$(dirname "$MAP")"
exec 9>>"$(dirname "$MAP")/.test-map.lock"
flock 9
MAP_BAK="$TMP/models.local.json.bak"
if [ -f "$MAP" ]; then cp "$MAP" "$MAP_BAK"; fi
restore_map() {
  if [ -f "$MAP_BAK" ]; then mv "$MAP_BAK" "$MAP"; else rm -f "$MAP"; fi
}
trap 'restore_map; rm -rf "$TMP"' EXIT

plant_advisor() {
  mkdir -p "$(dirname "$MAP")"
  echo '{"version":1,"agents":{"advisor":"test-model-x"},"effort":{"advisor":"low"}}' > "$MAP"
}
clear_map() { rm -f "$MAP"; }

ST="$TMP/state"

# res <args...> — residue.sh against the scratch root (state root is unused
# by the detector; passed anyway so a leak would land in scratch).
res() { ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$RESIDUE" "$@" 2>"$TMP/res.err"; }

# ---- fixtures (the 2026-10-19-claim clean shape: all VERIFIED >= 80) --------
V_CLEAN='{"unstruck_verdicts":[{"claim":"A","verdict":"VERIFIED","confidence":92,"evidence_blob":"x"},{"claim":"B","verdict":"PARTIALLY_VERIFIED","confidence":80,"evidence_blob":"y"}],"verdict_counts":{"VERIFIED":1,"PARTIALLY_VERIFIED":1,"UNVERIFIED":0,"CONTRADICTED":0,"FABRICATED":0},"verification_mode":"full","unstruck_findings":null,"finding_counts":null}'
V_BELOW='{"unstruck_verdicts":[{"claim":"A","verdict":"VERIFIED","confidence":55,"evidence_blob":"x"}],"verdict_counts":{"VERIFIED":1},"verification_mode":"full","unstruck_findings":null}'
V_79='{"unstruck_verdicts":[{"claim":"A","verdict":"VERIFIED","confidence":79,"evidence_blob":"x"}],"verdict_counts":{"VERIFIED":1},"verification_mode":"full","unstruck_findings":null}'
V_CONTRA='{"unstruck_verdicts":[{"claim":"C1","verdict":"CONTRADICTED","confidence":90,"evidence_blob":"x"}],"verdict_counts":{"CONTRADICTED":1},"verification_mode":"full","unstruck_findings":null}'
V_FAB='{"unstruck_verdicts":[{"claim":"C2","verdict":"FABRICATED","confidence":88,"evidence_blob":"x"}],"verdict_counts":{"FABRICATED":1},"verification_mode":"full","unstruck_findings":null}'
V_UNVER='{"unstruck_verdicts":[{"claim":"C3","verdict":"UNVERIFIED","confidence":95,"evidence_blob":"x"}],"verdict_counts":{"UNVERIFIED":1},"verification_mode":"full","unstruck_findings":null}'
V_DEG='{"unstruck_verdicts":[{"claim":"A","verdict":"VERIFIED","confidence":95,"evidence_blob":"x"}],"verdict_counts":{"VERIFIED":1},"verification_mode":"self-verified","unstruck_findings":null}'
F_BELOW='{"unstruck_findings":[{"file":"a.go","line":12,"severity":"warning","confidence":70}],"finding_counts":{"warning":1},"verification_mode":"full","unstruck_verdicts":null,"verdict_counts":null}'
F_CLEAN='{"unstruck_findings":[{"file":"a.go","line":12,"severity":"warning","confidence":85}],"finding_counts":{"warning":1},"verification_mode":"full","unstruck_verdicts":null,"verdict_counts":null}'
BANNER_REPORT='# council report
> **self-verified — refuters unavailable**
> detail
'
PLAIN_REPORT='# council report
no banner here
'

mk_fix() { # mk_fix <name> <json>
  printf '%s\n' "$2" > "$TMP/$1.json"
}
mk_fix clean "$V_CLEAN"; mk_fix below "$V_BELOW"; mk_fix v79 "$V_79"
mk_fix contra "$V_CONTRA"; mk_fix fab "$V_FAB"; mk_fix unver "$V_UNVER"
mk_fix deg "$V_DEG"; mk_fix fbelow "$F_BELOW"; mk_fix fclean "$F_CLEAN"
printf '%s\n' "$BANNER_REPORT" > "$TMP/banner-report.md"
printf '%s\n' "$PLAIN_REPORT" > "$TMP/plain-report.md"
printf '%s\n' '{"ruling":"AGREE","confidence":92,"evidence":[{"cmd":"ls","exit":0,"sha256":"x","locator":"a.go:1"}]}' > "$TMP/rul-agree.json"

# =============================================================================
# AC1 — detector contract: deterministic subprocess CLI, one JSON object,
# usage errors exit 64.
# =============================================================================

if ! grep -qE 'ask\.sh|resolve-model|Agent tool|spawn-request|subagent_type|curl |https?://' "$RESIDUE"; then
  pass "r1-no-llm-no-spawn-by-source"
else
  fail "r1-no-llm-no-spawn-by-source"
fi

OUT1=$(res --meta "$TMP/clean.json"); OUT2=$(res --meta "$TMP/clean.json")
if [ "$OUT1" = "$OUT2" ] && printf '%s' "$OUT1" | jq -e 'type == "object"' >/dev/null 2>&1; then
  pass "r1-single-deterministic-json-object"
else
  fail "r1-single-deterministic-json-object: $OUT1 vs $OUT2"
fi

if printf '%s' "$OUT1" | jq -e \
  'has("residue") and has("kinds") and has("below_threshold") and has("contradicted") and has("unverified") and has("degraded") and has("threshold")' >/dev/null 2>&1; then
  pass "r1-object-shape-residue-kinds-four-kind-objects"
else
  fail "r1-object-shape-residue-kinds-four-kind-objects: $OUT1"
fi

for kc in below_threshold contradicted unverified; do
  if printf '%s' "$OUT1" | jq -e --arg k "$kc" '.[$k] | has("present") and has("count") and has("items")' >/dev/null 2>&1; then
    pass "r1-$kc-present-count-items-shape"
  else
    fail "r1-$kc-present-count-items-shape: $OUT1"
  fi
done
if printf '%s' "$OUT1" | jq -e '.degraded | has("present") and has("reasons")' >/dev/null 2>&1; then
  pass "r1-degraded-present-reasons-shape"
else
  fail "r1-degraded-present-reasons-shape: $OUT1"
fi

res --meta "$TMP/clean.json" --report "$TMP/banner-report.md"
[ $? -eq 0 ] && pass "r1-scan-exit-0" || fail "r1-scan-exit-0"
res 2>/dev/null; [ $? -eq 64 ] && pass "r1-missing-meta-usage-64" || fail "r1-missing-meta-usage-64"
res --meta "$TMP/nope.json" 2>/dev/null; [ $? -eq 64 ] && pass "r1-missing-meta-file-64" || fail "r1-missing-meta-file-64"
printf 'not json' > "$TMP/bad.json"
res --meta "$TMP/bad.json" 2>/dev/null; [ $? -eq 64 ] && pass "r1-unparseable-meta-64" || fail "r1-unparseable-meta-64"
printf '[1,2]' > "$TMP/arr.json"
res --meta "$TMP/arr.json" 2>/dev/null; [ $? -eq 64 ] && pass "r1-non-object-meta-64" || fail "r1-non-object-meta-64"
res --meta "$TMP/clean.json" --threshold abc 2>/dev/null; [ $? -eq 64 ] && pass "r1-nonint-threshold-64" || fail "r1-nonint-threshold-64"
res --meta "$TMP/clean.json" --threshold 101 2>/dev/null; [ $? -eq 64 ] && pass "r1-threshold-over-100-64" || fail "r1-threshold-over-100-64"
res --meta "$TMP/clean.json" --report "$TMP/nope.md" 2>/dev/null; [ $? -eq 64 ] && pass "r1-missing-report-file-64" || fail "r1-missing-report-file-64"

# Round-2 bites (M14 C6): per-clause run-output exhibits for AC1.
res --meta "$TMP/clean.json" --threshold -1 2>/dev/null; [ $? -eq 64 ] && pass "r1-negative-threshold-below-zero-64" || fail "r1-negative-threshold-below-zero-64"

# Subprocess-only: sourcing the CLI is rejected (the sourced run hits the same
# usage fence, exit 64, in a scratch subshell) while the real subprocess scan
# via `bash "$RESIDUE"` succeeds with one JSON object.
SRC_RC=0; ( . "$RESIDUE" ) >/dev/null 2>&1 || SRC_RC=$?
SUB=$(res --meta "$TMP/clean.json"); SUB_RC=$?
if [ "$SRC_RC" -eq 64 ] && [ "$SUB_RC" -eq 0 ] \
  && printf '%s' "$SUB" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "subprocess-only: never sourced (sourcing subshell exits $SRC_RC; bash \"\$RESIDUE\" scan exits 0 with one JSON object)"
  pass "r1-subprocess-only-never-sourced"
else
  fail "r1-subprocess-only-never-sourced: src_rc=$SRC_RC sub_rc=$SUB_RC"
fi

if printf '%s' "$OUT1" | jq -e \
  '(.below_threshold | has("present") and has("count") and has("items")) and (.degraded | has("present") and has("reasons"))' >/dev/null 2>&1; then
  echo "keys: present, count, items|reasons"
  pass "r1-item-token-present-count-items-reasons"
else
  fail "r1-item-token-present-count-items-reasons: $OUT1"
fi

# Round-3 bites (M14 C6): run-output exhibits carrying the struck tokens.
HEAD1=$(head -1 "$RESIDUE")
if [ "$HEAD1" = "#!/usr/bin/env bash" ] \
  && ! grep -qE 'python|perl|ruby|node|php|lua|tcl' "$RESIDUE"; then
  pass "r1-bash-jq-only-interpreter-scan — bash+jq only (shebang: $HEAD1; interpreter scan: clean)"
else
  fail "r1-bash-jq-only-interpreter-scan: shebang=$HEAD1 hits=$(grep -nE 'python|perl|ruby|node|php|lua|tcl' "$RESIDUE" || true)"
fi

OUT_R=$(res --meta "$TMP/clean.json" --report "$TMP/banner-report.md"); RC_R=$?
if [ "$RC_R" -eq 0 ] \
  && printf '%s\n' "$OUT_R" | jq -e 'type == "object"' >/dev/null 2>&1 \
  && printf '%s\n' "$OUT_R" | jq -s 'length == 1' >/dev/null 2>&1; then
  pass "r1-single-json-object-with-report — exactly one JSON object on stdout (--report run)"
else
  fail "r1-single-json-object-with-report: rc=$RC_R out=$OUT_R"
fi

if printf '%s' "$OUT1" | jq -e '(.below_threshold | has("present") and has("count") and has("items")) and (.contradicted | has("present") and has("count") and has("items")) and (.unverified | has("present") and has("count") and has("items")) and (.degraded | has("present") and has("reasons"))' >/dev/null 2>&1; then
  pass "r1-items-reasons-span-exhibited {present, count, items|reasons}"
else
  fail "r1-items-reasons-span-exhibited: $OUT1"
fi

# Round-4 bites (M14 C6): default-path cardinality, exact kind key set, and a
# positive bash+jq-only exhibit.

OUT_DP=$(res --meta "$TMP/clean.json"); RC_DP=$?
if [ "$RC_DP" -eq 0 ] \
  && printf '%s\n' "$OUT_DP" | jq -s 'length == 1' >/dev/null 2>&1 \
  && printf '%s\n' "$OUT_DP" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "default-path stdout: exactly one JSON object (residue: $(printf '%s' "$OUT_DP" | jq -r '.residue'))"
  pass "r1-single-json-object-default-path — exactly one JSON object on stdout (default path)"
else
  fail "r1-single-json-object-default-path: rc=$RC_DP out=$OUT_DP"
fi

KSET_OK=1
for kc in below_threshold contradicted unverified; do
  printf '%s' "$OUT1" | jq -e --arg k "$kc" '.[$k] | keys_unsorted == ["present","count","items"]' >/dev/null 2>&1 || KSET_OK=0
done
printf '%s' "$OUT1" | jq -e '.degraded | keys_unsorted == ["present","reasons"]' >/dev/null 2>&1 || KSET_OK=0
# threshold is top-level only: present on the scan object, absent from every kind object.
printf '%s' "$OUT1" | jq -e 'has("threshold") and (.below_threshold | has("threshold") | not) and (.contradicted | has("threshold") | not) and (.unverified | has("threshold") | not) and (.degraded | has("threshold") | not)' >/dev/null 2>&1 || KSET_OK=0
if [ "$KSET_OK" -eq 1 ]; then
  echo "kind key sets: below_threshold/contradicted/unverified = [\"present\",\"count\",\"items\"]; degraded = [\"present\",\"reasons\"]; threshold top-level only"
  pass "r1-kind-exact-key-set — kind objects exact keys {present, count, items|reasons}, threshold top-level only"
else
  fail "r1-kind-exact-key-set: $(printf '%s' "$OUT1" | jq -c '{below_threshold: .below_threshold|keys_unsorted, contradicted: .contradicted|keys_unsorted, unverified: .unverified|keys_unsorted, degraded: .degraded|keys_unsorted, top_threshold: has("threshold")}')"
fi

# Positive bash+jq-only exhibit: shebang bash, no interpreter exec tokens, no
# env-style interpreter lines, no eval/source of another interpreter.
INT_SCAN=$(grep -nE 'python|perl|ruby|node|php|lua|tcl' "$RESIDUE" || true)
ENV_SCAN=$(grep -nE '(^|[[:space:]])env[[:space:]]+(python|perl|ruby|node|php|lua|tcl)|/usr/bin/env[[:space:]]+(python|perl|ruby|node|php|lua|tcl)' "$RESIDUE" || true)
EVAL_SCAN=$(grep -nE '(eval|source|\.[[:space:]])[^\n]*(python|perl|ruby|node|php|lua|tcl)' "$RESIDUE" || true)
if [ "$HEAD1" = "#!/usr/bin/env bash" ] && [ -z "$INT_SCAN" ] && [ -z "$ENV_SCAN" ] && [ -z "$EVAL_SCAN" ]; then
  pass "r1-bash-jq-only-positive — bash+jq only (shebang: $HEAD1; interpreter exec-token scan: clean; env-style interpreter lines: none; eval/source of other interpreters: none)"
else
  fail "r1-bash-jq-only-positive: shebang=$HEAD1 int=$INT_SCAN env=$ENV_SCAN eval=$EVAL_SCAN"
fi

# =============================================================================
# AC2 — residue kinds (M20): below-threshold, contradicted, unverified,
# degraded; clean pass emits residue:false.
# =============================================================================

OUT=$(res --meta "$TMP/clean.json")
if printf '%s' "$OUT" | jq -e '.residue == false and (.kinds | length) == 0 and .below_threshold.present == false and .contradicted.present == false and .unverified.present == false and .degraded.present == false' >/dev/null 2>&1; then
  pass "r2-clean-pass-residue-false-all-kinds-absent"
else
  fail "r2-clean-pass-residue-false-all-kinds-absent: $OUT"
fi

OUT=$(res --meta "$TMP/below.json")
if printf '%s' "$OUT" | jq -e '.residue == true and (.kinds | index("below-threshold")) != null and .below_threshold.count == 1 and .below_threshold.items[0].claim == "A" and .below_threshold.items[0].confidence == 55' >/dev/null 2>&1; then
  pass "r2-below-threshold-verdict-item-claim-confidence"
else
  fail "r2-below-threshold-verdict-item-claim-confidence: $OUT"
fi

OUT=$(res --meta "$TMP/fbelow.json")
if printf '%s' "$OUT" | jq -e '.below_threshold.present == true and .below_threshold.items[0].locator == "a.go:12" and .below_threshold.items[0].confidence == 70' >/dev/null 2>&1; then
  pass "r2-below-threshold-finding-file-line-locator"
else
  fail "r2-below-threshold-finding-file-line-locator: $OUT"
fi

OUT=$(res --meta "$TMP/fclean.json")
printf '%s' "$OUT" | jq -e '.residue == false' >/dev/null 2>&1 \
  && pass "r2-finding-run-clean-pass-no-residue" || fail "r2-finding-run-clean-pass-no-residue: $OUT"

OUT=$(res --meta "$TMP/below.json" --threshold 90)
printf '%s' "$OUT" | jq -e '.below_threshold.present == true' >/dev/null 2>&1 \
  && pass "r2-threshold-override-fires" || fail "r2-threshold-override-fires: $OUT"

OUT=$(res --meta "$TMP/v79.json")
printf '%s' "$OUT" | jq -e '.below_threshold.present == true' >/dev/null 2>&1 \
  && pass "r2-79-below-default-80" || fail "r2-79-below-default-80: $OUT"

OUT=$(res --meta "$TMP/clean.json")
printf '%s' "$OUT" | jq -e '.below_threshold.present == false' >/dev/null 2>&1 \
  && pass "r2-80-at-threshold-not-below" || fail "r2-80-at-threshold-not-below: $OUT"

OUT=$(res --meta "$TMP/contra.json")
if printf '%s' "$OUT" | jq -e '.contradicted.present == true and .contradicted.count == 1 and .contradicted.items[0].verdict == "CONTRADICTED"' >/dev/null 2>&1; then
  pass "r2-contradicted-verdict-fires"
else
  fail "r2-contradicted-verdict-fires: $OUT"
fi

OUT=$(res --meta "$TMP/fab.json")
printf '%s' "$OUT" | jq -e '.contradicted.present == true and .contradicted.items[0].verdict == "FABRICATED"' >/dev/null 2>&1 \
  && pass "r2-fabricated-counts-as-contradicted" || fail "r2-fabricated-counts-as-contradicted: $OUT"

OUT=$(res --meta "$TMP/unver.json")
printf '%s' "$OUT" | jq -e '.unverified.present == true and .unverified.items[0].verdict == "UNVERIFIED"' >/dev/null 2>&1 \
  && pass "r2-unverified-verdict-fires" || fail "r2-unverified-verdict-fires: $OUT"

OUT=$(res --meta "$TMP/deg.json")
printf '%s' "$OUT" | jq -e '.degraded.present == true and .degraded.reasons == ["verification_mode=self-verified"]' >/dev/null 2>&1 \
  && pass "r2-degraded-self-verified-mode" || fail "r2-degraded-self-verified-mode: $OUT"

OUT=$(res --meta "$TMP/clean.json" --report "$TMP/banner-report.md")
printf '%s' "$OUT" | jq -e '.degraded.present == true and (.degraded.reasons | index("report-banner")) != null' >/dev/null 2>&1 \
  && pass "r2-degraded-report-banner" || fail "r2-degraded-report-banner: $OUT"

OUT=$(res --meta "$TMP/deg.json" --report "$TMP/banner-report.md")
printf '%s' "$OUT" | jq -e '(.degraded.reasons | length) == 2' >/dev/null 2>&1 \
  && pass "r2-degraded-both-reasons-recorded" || fail "r2-degraded-both-reasons-recorded: $OUT"

OUT=$(res --meta "$TMP/clean.json" --report "$TMP/plain-report.md")
printf '%s' "$OUT" | jq -e '.degraded.present == false' >/dev/null 2>&1 \
  && pass "r2-no-banner-no-degraded" || fail "r2-no-banner-no-degraded: $OUT"

# Round-2 bite (M14 C6): the exact AC2 token forms exhibited verbatim.
OUT=$(res --meta "$TMP/clean.json"); RCD=$?
DEG=$(res --meta "$TMP/deg.json")
FB=$(res --meta "$TMP/fbelow.json")
if [ "$RCD" -eq 0 ] \
  && printf '%s' "$OUT" | jq -e '.residue == false and .below_threshold.present == false and .contradicted.present == false and .unverified.present == false and .degraded.present == false' >/dev/null 2>&1 \
  && printf '%s' "$DEG" | jq -e '.degraded.present == true and .degraded.reasons == ["verification_mode=self-verified"]' >/dev/null 2>&1 \
  && printf '%s' "$FB" | jq -e '.below_threshold.items[0].locator == "a.go:12"' >/dev/null 2>&1; then
  echo "residue: false"
  echo "present: false"
  echo "locator form: file:line ($(printf '%s' "$FB" | jq -r '.below_threshold.items[0].locator'))"
  echo "degraded fires when verification_mode == \"self-verified\" ($(printf '%s' "$DEG" | jq -r '.degraded.reasons | join(",")'))"
  pass "r2-ac2-token-forms-exhibited"
else
  fail "r2-ac2-token-forms-exhibited: rc=$RCD out=$OUT deg=$DEG fb=$FB"
fi

# =============================================================================
# AC3 — the appeal seam gate (M20): clean pass = zero advisor calls; off /
# bypass = silent skip.
# =============================================================================

gate() { # gate <args...> — appeal.sh gate against the scratch root; pass
          # ADVISOR_ON=true (or not) via the environment at the call site.
  ADVISOR_STATE_ROOT="$ST" timeout 30 bash "$APPEAL" gate "$@" 2>"$TMP/gate.err"
}

rm -rf "$ST"; clear_map; plant_advisor
OUT=$(gate --meta "$TMP/clean.json" --run-id r3-clean); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$ST" ]; then
  pass "r3-clean-gate-silent-and-writes-nothing"
else
  fail "r3-clean-gate-silent-and-writes-nothing: rc=$RC out=$OUT st=$ST"
fi
if [ -z "$(find "$ST" -name 'spawn-request.json' -print -quit 2>/dev/null)" ]; then
  pass "r3-clean-pass-no-probe-request-written"
else
  fail "r3-clean-pass-no-probe-request-written"
fi

rm -rf "$ST"
OUT=$(ADVISOR_ON=true ADVISOR_STATE_ROOT="$ST" timeout 30 bash "$APPEAL" gate --meta "$TMP/clean.json" --run-id r3-clean-on 2>"$TMP/gate.err"); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$ST" ]; then
  pass "r3-clean-pass-zero-advisor-calls-even-advisor-on"
else
  fail "r3-clean-pass-zero-advisor-calls-even-advisor-on: rc=$RC out=$OUT"
fi

rm -rf "$ST"
OUT=$(gate --meta "$TMP/below.json" --run-id r3-off); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$ST" ]; then
  pass "r3-advisor-off-silent-skip-no-probe"
else
  fail "r3-advisor-off-silent-skip-no-probe: rc=$RC out=$OUT"
fi

rm -rf "$ST"
OUT=$(ADVISOR_ON=true ADVISOR_SKIP_TRIGGER=1 ADVISOR_STATE_ROOT="$ST" timeout 30 bash "$APPEAL" gate --meta "$TMP/below.json" --run-id r3-bypass 2>"$TMP/gate.err"); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$ST" ]; then
  pass "r3-bypass-silent-skip-no-probe"
else
  fail "r3-bypass-silent-skip-no-probe: rc=$RC out=$OUT"
fi

# =============================================================================
# AC4 — residue + advisor on: evidence staged OUTSIDE the council bundle set,
# probe trigger c, hash covers staged evidence content.
# =============================================================================

rm -rf "$ST"; plant_advisor
OUT=$(ADVISOR_ON=true gate --meta "$TMP/below.json" --run-id r4-appeal); RC=$?
ACT=$(printf '%s' "$OUT" | jq -r '.action // empty' 2>/dev/null)
SRP="$ST/runs/r4-appeal/spawn-request.json"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  pass "r4-residue-gate-emits-one-probe-json-object"
else
  fail "r4-residue-gate-emits-one-probe-json-object: rc=$RC out=$OUT"
fi
if [ "$ACT" = "spawn" ] || [ "$ACT" = "cache-hit" ]; then
  pass "r4-probe-action-spawn-or-cache-hit"
else
  fail "r4-probe-action-spawn-or-cache-hit: $ACT"
fi
if [ -f "$SRP" ] && [ "$(jq -r '.trigger' "$SRP")" = "c" ] \
  && [ "$(jq -r '.evidence_dir' "$SRP")" = "$ST/runs/r4-appeal/appeal-evidence" ]; then
  pass "r4-spawn-request-trigger-c-staged-evidence-dir"
else
  fail "r4-spawn-request-trigger-c-staged-evidence-dir: $(cat "$SRP" 2>/dev/null)"
fi
if [ -f "$ST/runs/r4-appeal/appeal-evidence/council.finalize-meta.json" ]; then
  pass "r4-appeal-evidence-staged-under-advisor-state-root"
else
  fail "r4-appeal-evidence-staged-under-advisor-state-root"
fi

H1=$(jq -r '.question_hash' "$SRP")
rm -rf "$ST"; plant_advisor
# Changed staged evidence (different meta content) -> new question hash.
jq '.unstruck_verdicts[0].confidence = 60' "$TMP/below.json" > "$TMP/below2.json"
OUT=$(ADVISOR_ON=true gate --meta "$TMP/below2.json" --run-id r4-hash); RC=$?
H2=$(jq -r '.question_hash' "$ST/runs/r4-hash/spawn-request.json" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ -n "$H1" ] && [ "$H1" != "$H2" ]; then
  pass "r4-hash-covers-staged-evidence-content"
else
  fail "r4-hash-covers-staged-evidence-content: $H1 vs $H2 (rc=$RC)"
fi

# Same inputs after a recorded ruling -> free cache-hit (M26 dedupe; the
# cache entry exists only once finalize recorded the ruling).
ADVISOR_STATE_ROOT="$ST" timeout 30 bash "$ASK" finalize --run-id r4-hash \
  --ruling-file "$TMP/rul-agree.json" >/dev/null 2>&1
OUT=$(ADVISOR_ON=true gate --meta "$TMP/below2.json" --run-id r4-hash); RC=$?
ACT=$(printf '%s' "$OUT" | jq -r '.action // empty' 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$ACT" = "cache-hit" ]; then
  pass "r4-repeat-gate-after-finalize-is-free-cache-hit"
else
  fail "r4-repeat-gate-after-finalize-is-free-cache-hit: rc=$RC act=$ACT"
fi

# --evidence-dir override is honored (caller-owned path).
rm -rf "$ST" "$TMP/evdir"; plant_advisor
OUT=$(ADVISOR_ON=true gate --meta "$TMP/below.json" --run-id r4-ovr --evidence-dir "$TMP/evdir"); RC=$?
if [ "$RC" -eq 0 ] && [ -f "$TMP/evdir/council.finalize-meta.json" ]; then
  pass "r4-evidence-dir-override-honored"
else
  fail "r4-evidence-dir-override-honored: rc=$RC"
fi

# Round-2 bite (M14 C6): the gate's stdout action object exhibited and parsed.
rm -rf "$ST"; plant_advisor
OUT=$(ADVISOR_ON=true gate --meta "$TMP/below.json" --run-id r4-stdout); RC=$?
SRP="$ST/runs/r4-stdout/spawn-request.json"
SRP_OUT=$(printf '%s' "$OUT" | jq -r '.spawn_request_path // empty' 2>/dev/null)
EVDIR=$(jq -r '.evidence_dir' "$SRP" 2>/dev/null)
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | jq -e 'type == "object" and .action == "spawn" and (.spawn_request_path | length > 0)' >/dev/null 2>&1 \
  && [ "$SRP_OUT" = "$SRP" ] \
  && [ "$(jq -r '.trigger' "$SRP")" = "c" ]; then
  echo "gate stdout action object: {action: \"spawn\", spawn_request_path: \"$SRP_OUT\"}"
  echo "trigger: \"c\""
  echo "staged: $EVDIR/"
  pass "r4-gate-stdout-action-object-trigger-c"
else
  fail "r4-gate-stdout-action-object-trigger-c: rc=$RC out=$OUT srp_out=$SRP_OUT"
fi

# Round-3 bites (M14 C6): staged-evidence placement, stdout->SRP->trigger
# chain, and hash-covers-staged-content run output.
rm -rf "$ST"; plant_advisor
OUT=$(ADVISOR_ON=true gate --meta "$TMP/below.json" --run-id r4-outside); RC=$?
EVD="$ST/runs/r4-outside/appeal-evidence"
BSET_DIR=$(mktemp -d "${TMPDIR:-/tmp}/advisor-residue-bundle.XXXXXX")
printf '%s\n' '[{"tool_use_id":"t1","raw_blob":"out"}]' > "$BSET_DIR/bundle-set.json"
CBS_RC=0; ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$APPEAL" check-bundle-set \
  --file "$BSET_DIR/bundle-set.json" >/dev/null 2>&1 || CBS_RC=$?
if [ "$RC" -eq 0 ] && [ -f "$EVD/council.finalize-meta.json" ] \
  && [ "$CBS_RC" -eq 0 ] \
  && case "$EVD" in "$BSET_DIR"/*) false ;; *) true ;; esac; then
  pass "r4-staged-outside-council-bundle-set — staged evidence $EVD is outside council bundle set $BSET_DIR"
else
  fail "r4-staged-outside-council-bundle-set: rc=$RC cbs_rc=$CBS_RC evd=$EVD bset=$BSET_DIR"
fi
rm -rf "$BSET_DIR"

rm -rf "$ST"; plant_advisor
OUT=$(ADVISOR_ON=true gate --meta "$TMP/below.json" --run-id r4-parse); RC=$?
SRP_OUT=$(printf '%s' "$OUT" | jq -r '.spawn_request_path // empty' 2>/dev/null)
TRIG=$(jq -r '.trigger' "$SRP_OUT" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ -n "$SRP_OUT" ] && [ "$TRIG" = "c" ]; then
  echo "stdout action object: spawn_request_path=$SRP_OUT"
  echo "parsed through the stdout chain: trigger: \"c\""
  pass "r4-stdout-action-object-trigger-c-parsed — stdout spawn_request_path -> SRP trigger: \"c\""
else
  fail "r4-stdout-action-object-trigger-c-parsed: rc=$RC out=$OUT srp_out=$SRP_OUT trig=$TRIG"
fi

rm -rf "$ST"; plant_advisor
mkdir -p "$TMP/fix"
printf '%s\n' "$V_BELOW" > "$TMP/fix/council.finalize-meta.json"
ADVISOR_ON=true gate --meta "$TMP/fix/council.finalize-meta.json" --run-id r4-hash2 >/dev/null 2>&1
H1=$(jq -r '.question_hash' "$ST/runs/r4-hash2/spawn-request.json" 2>/dev/null)
Q1=$(jq -r '.question' "$ST/runs/r4-hash2/spawn-request.json" 2>/dev/null)
jq '.unstruck_verdicts[0].confidence = 60' \
  "$ST/runs/r4-hash2/appeal-evidence/council.finalize-meta.json" > "$TMP/fix/mut.json" \
  && mv "$TMP/fix/mut.json" "$ST/runs/r4-hash2/appeal-evidence/council.finalize-meta.json"
# Same run-id, no finalize in between; the gate re-probes with the MUTATED
# staged file (--evidence-dir override avoids the same-file cp); question is
# byte-identical, so only the staged evidence content moves the hash.
ADVISOR_ON=true gate --meta "$ST/runs/r4-hash2/appeal-evidence/council.finalize-meta.json" \
  --evidence-dir "$TMP/fix/ev-mut" --run-id r4-hash2 >/dev/null 2>&1
H2=$(jq -r '.question_hash' "$ST/runs/r4-hash2/spawn-request.json" 2>/dev/null)
Q2=$(jq -r '.question' "$ST/runs/r4-hash2/spawn-request.json" 2>/dev/null)
if [ -n "$H1" ] && [ -n "$H2" ] && [ "$H1" != "$H2" ] && [ "$Q1" = "$Q2" ]; then
  echo "staged evidence content moved the hash with the question fixed: $Q1"
  echo "H1=$H1 H2=$H2"
  pass "r4-hash-covers-staged-file-content — staged evidence content changed the question hash (H1 != H2, question identical)"
else
  fail "r4-hash-covers-staged-file-content: H1=$H1 H2=$H2 q1=$Q1 q2=$Q2"
fi

# =============================================================================
# AC5 — authority fence (M21): sustain-halt / re-council only, labelled
# advisor_appeal, never proceed.
# =============================================================================

authority() { # authority <args...>
  ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$APPEAL" authority "$@" 2>"$TMP/auth.err"
}
printf '%s\n' '{"ruling":"AGREE","confidence":92,"evidence":[{"cmd":"ls","exit":0,"sha256":"x","locator":"a.go:1"}]}' > "$TMP/rul-agree.json"
printf '%s\n' '{"ruling":"CONTRADICT","confidence":85,"evidence":[{"cmd":"ls","exit":0,"sha256":"x","locator":"a.go:1"}]}' > "$TMP/rul-contra.json"
printf '%s\n' '{"ruling":"INSUFFICIENT","confidence":70,"evidence":[{"cmd":"ls","exit":0,"sha256":"x","locator":"a.go:1"}]}' > "$TMP/rul-insuf.json"

OUT=$(authority --ruling-file "$TMP/rul-agree.json")
if printf '%s' "$OUT" | jq -e '.authority == "sustain-halt" and .advisor_appeal == true and .ruling == "AGREE" and .confidence == 92' >/dev/null 2>&1; then
  pass "r5-agree-sustain-halt-labelled"
else
  fail "r5-agree-sustain-halt-labelled: $OUT"
fi

OUT=$(authority --ruling-file "$TMP/rul-contra.json")
printf '%s' "$OUT" | jq -e '.authority == "re-council" and .advisor_appeal == true' >/dev/null 2>&1 \
  && pass "r5-contradict-re-council-labelled" || fail "r5-contradict-re-council-labelled: $OUT"

OUT=$(authority --ruling-file "$TMP/rul-insuf.json")
printf '%s' "$OUT" | jq -e '.authority == "re-council"' >/dev/null 2>&1 \
  && pass "r5-insufficient-fails-closed-to-re-council" || fail "r5-insufficient-fails-closed-to-re-council: $OUT"

OUT=$(authority --ruling-file "$TMP/rul-agree.json")
printf '%s' "$OUT" | jq -r '.authority' | grep -qx 'proceed' \
  && fail "r5-proceed-never-emitted" || pass "r5-proceed-never-emitted"

rm -rf "$ST"
authority --ruling-file "$TMP/rul-agree.json" --run-id r5-rec >/dev/null
if [ -f "$ST/runs/r5-rec/appeal.json" ] && jq -e '.advisor_appeal == true and .authority == "sustain-halt"' "$ST/runs/r5-rec/appeal.json" >/dev/null 2>&1; then
  pass "r5-appeal-record-written-labelled"
else
  fail "r5-appeal-record-written-labelled"
fi

# Round-3 bite (M14 C6): every authority run's stdout is exactly one JSON
# object — AGREE, CONTRADICT, and the --run-id case (whose stdout the
# labelled-record test above discards).
OUT_A=$(authority --ruling-file "$TMP/rul-agree.json"); RC_A=$?
OUT_C=$(authority --ruling-file "$TMP/rul-contra.json"); RC_C=$?
rm -rf "$ST"
OUT_I=$(authority --ruling-file "$TMP/rul-agree.json" --run-id r5-obj); RC_I=$?
if [ "$RC_A" -eq 0 ] && [ "$RC_C" -eq 0 ] && [ "$RC_I" -eq 0 ] \
  && printf '%s\n' "$OUT_A" | jq -e 'type == "object"' >/dev/null 2>&1 \
  && printf '%s\n' "$OUT_A" | jq -s 'length == 1' >/dev/null 2>&1 \
  && printf '%s\n' "$OUT_C" | jq -e 'type == "object"' >/dev/null 2>&1 \
  && printf '%s\n' "$OUT_C" | jq -s 'length == 1' >/dev/null 2>&1 \
  && printf '%s\n' "$OUT_I" | jq -e 'type == "object"' >/dev/null 2>&1 \
  && printf '%s\n' "$OUT_I" | jq -s 'length == 1' >/dev/null 2>&1; then
  pass "r5-authority-stdout-exactly-one-json-object — exactly one JSON object on stdout (AGREE, CONTRADICT, --run-id)"
else
  fail "r5-authority-stdout-exactly-one-json-object: rc_a=$RC_A rc_c=$RC_C rc_i=$RC_I out_a=$OUT_A out_c=$OUT_C out_i=$OUT_I"
fi

# Round-4 bites (M14 C6): INSUFFICIENT cardinality, exact key set in emit
# order, and the AC5 token exhibit backed by the AGREE stdout + record file.

OUT_S=$(authority --ruling-file "$TMP/rul-insuf.json"); RC_S=$?
if [ "$RC_S" -eq 0 ] \
  && printf '%s\n' "$OUT_S" | jq -s 'length == 1' >/dev/null 2>&1 \
  && printf '%s\n' "$OUT_S" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "INSUFFICIENT stdout: exactly one JSON object (authority: $(printf '%s' "$OUT_S" | jq -r '.authority'))"
  pass "r5-authority-stdout-exactly-one-json-object-insufficient — exactly one JSON object on stdout (INSUFFICIENT)"
else
  fail "r5-authority-stdout-exactly-one-json-object-insufficient: rc=$RC_S out=$OUT_S"
fi

OUT_KS=$(authority --ruling-file "$TMP/rul-agree.json"); RC_KS=$?
if [ "$RC_KS" -eq 0 ] \
  && printf '%s' "$OUT_KS" | jq -e 'keys_unsorted == ["authority","advisor_appeal","ruling","confidence"]' >/dev/null 2>&1; then
  echo "emit order: authority, advisor_appeal, ruling, confidence (ts only in the --run-id file variant)"
  pass "r5-authority-stdout-exact-key-set — exact key set {authority, advisor_appeal, ruling, confidence} (emit order: authority, advisor_appeal, ruling, confidence)"
else
  fail "r5-authority-stdout-exact-key-set: rc=$RC_KS keys=$(printf '%s' "$OUT_KS" | jq -c 'keys_unsorted' 2>/dev/null)"
fi

rm -rf "$ST"
OUT_T=$(authority --ruling-file "$TMP/rul-agree.json" --run-id r5-tokens); RC_T=$?
APPEAL_REC="$ST/runs/r5-tokens/appeal.json"
if [ "$RC_T" -eq 0 ] \
  && printf '%s' "$OUT_T" | jq -e 'type == "object" and .advisor_appeal == true and (.ruling | length > 0) and (.confidence | type == "number") and (keys_unsorted == ["authority","advisor_appeal","ruling","confidence"])' >/dev/null 2>&1 \
  && [ -f "$APPEAL_REC" ] && jq -e '.advisor_appeal == true' "$APPEAL_REC" >/dev/null 2>&1; then
  echo "stdout: $(printf '%s' "$OUT_T" | jq -c '{authority, advisor_appeal, ruling, confidence}')"
  echo "record: runs/<RUN_ID>/appeal.json ($APPEAL_REC)"
  pass "r5-ac5-tokens-exhibited appeal.sh authority --ruling-file PATH [--run-id ID] {authority, advisor_appeal: true, ruling, confidence} runs/<RUN_ID>/appeal.json"
else
  fail "r5-ac5-tokens-exhibited: rc=$RC_T out=$OUT_T rec=$APPEAL_REC"
fi

printf '%s\n' '{"ruling":"PROCEED","confidence":90,"evidence":[]}' > "$TMP/rul-bad.json"
authority --ruling-file "$TMP/rul-bad.json" >/dev/null 2>&1
[ $? -eq 64 ] && pass "r5-unknown-ruling-exit-64" || fail "r5-unknown-ruling-exit-64"

# =============================================================================
# AC6 — M22 injection guard: labelled evidence rejected from a bundle set.
# =============================================================================

check() { # check <args...>
  ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$APPEAL" check-bundle-set "$@" 2>"$TMP/cbs.err"
}
printf '%s\n' '[{"tool_use_id":"t1","raw_blob":"out"}]' > "$TMP/bundles-clean.json"
printf '%s\n' '[{"tool_use_id":"t1","raw_blob":"out"},{"tool_use_id":"t2","raw_blob":"x","advisor_appeal":true}]' > "$TMP/bundles-injected.json"
printf '%s\n' '{"bundles":[{"nested":{"advisor_appeal":true}}]}' > "$TMP/bundles-nested.json"
printf 'not json' > "$TMP/bundles-bad.json"

check --file "$TMP/bundles-clean.json"
[ $? -eq 0 ] && pass "r6-clean-bundle-set-accepted" || fail "r6-clean-bundle-set-accepted"

check --file "$TMP/bundles-injected.json" >/dev/null 2>&1
[ $? -eq 64 ] && pass "r6-labelled-evidence-in-bundle-set-rejected-64" || fail "r6-labelled-evidence-in-bundle-set-rejected-64"

check --file "$TMP/bundles-nested.json" >/dev/null 2>&1
[ $? -eq 64 ] && pass "r6-nested-labelled-object-rejected-64" || fail "r6-nested-labelled-object-rejected-64"

check --file "$TMP/bundles-bad.json" >/dev/null 2>&1
[ $? -eq 64 ] && pass "r6-unparseable-bundle-set-64" || fail "r6-unparseable-bundle-set-64"

# =============================================================================
# AC7 — hook fence in ship-gate-council.md §4a + SKILL.md trigger-(c) docs.
# =============================================================================

SGC="$ROOT/skills/autopilot/ship-gate-council.md"
SKILL="$ROOT/skills/advisor/SKILL.md"

if grep -q 'appeal.sh gate' "$SGC" && grep -q 'check-bundle-set' "$SGC" \
  && grep -q 'ADVISOR_SKIP_TRIGGER' "$SGC" && grep -q '4a. Trigger-(c) advisor appeal' "$SGC"; then
  pass "r7-ship-gate-council-4a-fence-present"
else
  fail "r7-ship-gate-council-4a-fence-present"
fi

# The doc must state the authority limits: sustain-halt persists nothing,
# re-council is a fresh pass, and the appeal word alone never ships.
grep -q 'MUST NOT' "$SGC" && grep -q 'FRESH council' "$SGC" \
  && grep -q 'never ships' "$SGC" \
  && pass "r7-fence-states-authority-limits" || fail "r7-fence-states-authority-limits"

grep -q 'appeal.sh gate' "$SKILL" && grep -q 'appeal.sh authority' "$SKILL" \
  && grep -q 'check-bundle-set' "$SKILL" && grep -q 'Trigger (c)' "$SKILL" \
  && grep -q 'advisor_appeal' "$SKILL" \
  && pass "r7-skill-documents-trigger-c-end-to-end" || fail "r7-skill-documents-trigger-c-end-to-end"

# Round-3 bite (M14 C6): the trigger-(c) end-to-end order line carries
# gate -> probe -> native spawn -> finalize -> authority with strictly
# increasing token offsets (echoed as run output).
ORDER_LINE=$(awk '/^## Trigger \(c\)/{f=1;next} f&&/^## /{exit} f && /gate.*probe.*native spawn.*finalize.*authority/{print; exit}' "$SKILL")
if [ -n "$ORDER_LINE" ]; then
  ORDER_CHK=$(printf '%s' "$ORDER_LINE" | awk '{
    ok = 1; prev = 0; found = "";
    n = split("gate|probe|native spawn|finalize|authority", t, "|");
    for (i = 1; i <= n; i++) {
      p = index(substr($0, prev + 1), t[i]);
      if (p == 0) { ok = 0; break }
      p = p + prev;
      found = found (i == 1 ? "" : " -> ") t[i] "@" p;
      prev = p + length(t[i]) - 1;
    }
    print (ok ? "OK " found : "BAD " found);
  }')
  case "$ORDER_CHK" in
    OK\ *)
      echo "SKILL.md trigger-(c) order line: $ORDER_LINE"
      echo "token offsets strictly increasing: $ORDER_CHK"
      pass "r7-skill-documents-order-native-spawn-finalize — native spawn before finalize in the trigger-(c) order line ($ORDER_CHK)"
      ;;
    *) fail "r7-skill-documents-order-native-spawn-finalize: line=$ORDER_LINE chk=$ORDER_CHK" ;;
  esac
else
  fail "r7-skill-documents-order-native-spawn-finalize: no trigger-(c) order line found in $SKILL"
fi

# Extract the §4a fence: from the APPEAL_META= placeholder line through the
# fence's closing fi (same extract-and-execute-the-real-text discipline as
# test-classify.sh exec_fence).
FENCE=$(awk '/^APPEAL_META=/{f=1} f{print} f&&/^fi$/{exit}' "$SGC")
if [ -n "$FENCE" ]; then
  pass "r7-fence-extractable"
else
  fail "r7-fence-extractable"
fi

if [ -n "$FENCE" ]; then
  # The PDH stub resolves any `file <relpath>` to the REAL repo file, so the
  # fence's appeal.sh and ask.sh's resolve-model.sh both work for real.
  mkdir -p "$TMP/stub/skills"
  printf '#!/usr/bin/env bash\n[ "$1" = file ] && printf "%%s" "${REPO_ROOT:?}/$2"\n' \
    > "$TMP/stub/skills/plugin-dir.sh"
  F_CLEAN_SUB=$(printf '%s' "$FENCE" \
    | sed "s#<report>.finalize-meta.json#$TMP/clean.json.finalize-meta.json#g" \
    | sed "s#<report>#$TMP/clean.json#g" \
    | sed "s#<RUN_ID>#r7-fence-clean#g")
  # Clean pass, advisor on + mapped: silent exit 0, nothing written.
  cp "$TMP/clean.json" "$TMP/clean.json.finalize-meta.json"
  rm -rf "$ST"
  OUT=$(REPO_ROOT="$ROOT" PDH="$TMP/stub" ADVISOR_ON=true ADVISOR_STATE_ROOT="$ST" \
    timeout 30 bash -c "$F_CLEAN_SUB" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$(find "$ST" -name 'spawn-request.json' -print -quit 2>/dev/null)" ]; then
    pass "r7-fence-executed-clean-pass-silent-no-probe"
  else
    fail "r7-fence-executed-clean-pass-silent-no-probe: rc=$RC out=$OUT"
  fi

  F_RES_SUB=$(printf '%s' "$FENCE" \
    | sed "s#<report>.finalize-meta.json#$TMP/below.json.finalize-meta.json#g" \
    | sed "s#<report>#$TMP/below.json#g" \
    | sed "s#<RUN_ID>#r7-fence-res#g")
  cp "$TMP/below.json" "$TMP/below.json.finalize-meta.json"
  rm -rf "$ST"; plant_advisor
  OUT=$(REPO_ROOT="$ROOT" PDH="$TMP/stub" ADVISOR_ON=true ADVISOR_STATE_ROOT="$ST" \
    timeout 30 bash -c "$F_RES_SUB" 2>&1); RC=$?
  case "$OUT" in
    *"advisor trigger-(c) appeal"*)
      pass "r7-fence-executed-residue-emits-appeal-signal" ;;
    *) fail "r7-fence-executed-residue-emits-appeal-signal: rc=$RC out=$OUT" ;;
  esac
  SRP="$ST/runs/r7-fence-res/spawn-request.json"
  if [ -f "$SRP" ] && [ "$(jq -r '.trigger' "$SRP")" = "c" ]; then
    pass "r7-fence-executed-residue-probe-recorded"
  else
    fail "r7-fence-executed-residue-probe-recorded"
  fi

  # Advisor off / bypass: the real fence text is silent (no stub needed).
  F_OFF_SUB=$(printf '%s' "$FENCE" | sed "s#<report>#$TMP/x#g" | sed "s#<RUN_ID>#r7-off#g")
  OUT=$(REPO_ROOT="$ROOT" PDH="$TMP/stub" timeout 30 bash -c "$F_OFF_SUB" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "r7-fence-executed-advisor-off-silent"
  else
    fail "r7-fence-executed-advisor-off-silent: rc=$RC out=$OUT"
  fi
  OUT=$(REPO_ROOT="$ROOT" PDH="$TMP/stub" ADVISOR_ON=true ADVISOR_SKIP_TRIGGER=1 \
    timeout 30 bash -c "$F_OFF_SUB" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "r7-fence-executed-bypass-silent"
  else
    fail "r7-fence-executed-bypass-silent: rc=$RC out=$OUT"
  fi
fi

# =============================================================================
# M37 — the appeal forwards the run's model override to the probe.
# =============================================================================

rm -rf "$ST"; plant_advisor
OUT=$(ADVISOR_ON=true gate --meta "$TMP/below.json" --run-id r8-model --model appeal-model-z); RC=$?
SRP="$ST/runs/r8-model/spawn-request.json"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.model // empty')" = "appeal-model-z" ]; then
  pass "r8-gate-forwards-model-to-probe"
else
  fail "r8-gate-forwards-model-to-probe: rc=$RC out=$OUT"
fi
if [ -f "$SRP" ] && [ "$(jq -r '.model_source // empty' "$SRP")" = "flag" ]; then
  pass "r8-gate-probe-records-model-source-flag"
else
  fail "r8-gate-probe-records-model-source-flag: $(cat "${SRP:-/dev/null}" 2>/dev/null)"
fi

# Without --model the mapped choice still wins (no silent change).
rm -rf "$ST"; plant_advisor
OUT=$(ADVISOR_ON=true gate --meta "$TMP/below.json" --run-id r8-nomodel); RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.model // empty')" = "test-model-x" ]; then
  pass "r8-gate-without-model-uses-map"
else
  fail "r8-gate-without-model-uses-map: rc=$RC out=$OUT"
fi

# A reserved or malformed token is usage, never a fallback.
rm -rf "$ST"; plant_advisor
RC=0; gate --meta "$TMP/below.json" --run-id r8-bad --model '$(id)' >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 64 ]; then pass "r8-gate-model-metachar-64"; else fail "r8-gate-model-metachar-64: rc=$RC"; fi
RC=0; gate --meta "$TMP/below.json" --run-id r8-null --model null >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 64 ]; then pass "r8-gate-model-null-64"; else fail "r8-gate-model-null-64: rc=$RC"; fi

# =============================================================================
echo
echo "test-residue.sh: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
