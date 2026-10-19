#!/usr/bin/env bash
# test-gates.sh — trigger-(a) restricted gate + shadow bite-tests
# (SPEC-039 M23/M24/M25, epic child CDT-563-C7).
#
# Machine-check: bash skills/advisor/test-gates.sh  (exit 0)
#
# Every AC sub-clause of the SPEC-039 `### CDT-563` section gets its own
# named run-output PASS line (the C8/M14 lesson: an aggregate or
# source-assert-only name is not per-clause run output).
#
# Hermetic: everything lives under TMPDIR; the advisor state root is a
# scratch ADVISOR_STATE_ROOT. No model map is touched (gates.sh never reads
# it), so no shared-file lock is needed.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1
GATES="$ROOT/skills/advisor/gates.sh"
SKILL="$ROOT/skills/advisor/SKILL.md"
SA="$ROOT/skills/autopilot/self-answer.md"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/advisor-gates-test.XXXXXX")
[ -d "$TMP" ] || { echo "test-gates.sh: mktemp -d failed (check TMPDIR)" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

ST="$TMP/state"
gt() { # gt <args...> — gates.sh against the scratch state root
  ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" "$@" 2>"$TMP/gt.err"
}
gt_rc() { gt "$@" >/dev/null 2>&1; echo $?; }

# =============================================================================
# AC1 — allow: M24 allowed set passes; the M23 denylist is structurally
# unreachable (exit 64, allowed:false on stdout, stable reason on stderr).
# =============================================================================

for ID in bc7 bc2-diagnosis bc6-diagnosis bc1-mis-fire; do
  OUT=$(gt allow --bc "$ID"); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e --arg g "$ID" '.gate == $g and .allowed == true' >/dev/null 2>&1; then
    pass "a1-allow-$ID-exit-0-allowed-true"
  else
    fail "a1-allow-$ID-exit-0-allowed-true: rc=$RC out=$OUT"
  fi
done

for ID in bc3 bc8 bc6-extension bc1-as-human-preference; do
  OUT=$(gt allow --bc "$ID"); RC=$?
  if [ "$RC" -eq 64 ] && printf '%s' "$OUT" | jq -e --arg g "$ID" '.gate == $g and .allowed == false' >/dev/null 2>&1; then
    pass "a1-deny-$ID-exit-64-allowed-false"
  else
    fail "a1-deny-$ID-exit-64-allowed-false: rc=$RC out=$OUT"
  fi
  if grep -qF 'SPEC-039 M23 denylist' "$TMP/gt.err"; then
    pass "a1-deny-$ID-stable-reason-m23"
  else
    fail "a1-deny-$ID-stable-reason-m23: $(cat "$TMP/gt.err")"
  fi
done

OUT=$(gt allow --bc bc1-preference); RC=$?
if [ "$RC" -eq 64 ] && printf '%s' "$OUT" | jq -e '.allowed == false' >/dev/null 2>&1; then
  pass "a1-unknown-id-exit-64-allowed-false"
else
  fail "a1-unknown-id-exit-64-allowed-false: rc=$RC out=$OUT"
fi

if ! grep -qE 'Agent tool|spawn-request|subagent_type|curl |https?://' "$GATES" \
  && ! grep -qiE 'ask\.sh|resolve-model' "$GATES"; then
  pass "a1-no-llm-no-spawn-by-source"
else
  fail "a1-no-llm-no-spawn-by-source"
fi

OUT=$(GATES_PATH="$GATES" ADVISOR_STATE_ROOT="$ST" timeout 20 \
  bash -c '. "$GATES_PATH" allow --bc bc7' 2>"$TMP/src.err"); RC=$?
if [ "$RC" -eq 64 ] && ! printf '%s' "$OUT" | jq -e 'type == "object"' >/dev/null 2>&1 \
  && grep -qF 'never source' "$TMP/src.err"; then
  pass "a1-never-sourced-guard"
else
  fail "a1-never-sourced-guard: rc=$RC out=$OUT err=$(cat "$TMP/src.err")"
fi

# =============================================================================
# AC2 — ruling: M24 vocabularies. BC2/BC6 diagnosis accept only halt|decompose
# (proceed can never be emitted); BC1 mis-fire accepts only
# halt-stands|mis-fire; BC7 keeps the M18 vocabulary.
# =============================================================================

OUT=$(gt ruling --bc bc2-diagnosis --ruling halt); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.accepted == true' >/dev/null 2>&1; then
  pass "a2-bc2-diagnosis-halt-accepted"
else
  fail "a2-bc2-diagnosis-halt-accepted: rc=$RC out=$OUT"
fi
OUT=$(gt ruling --bc bc2-diagnosis --ruling decompose); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.accepted == true' >/dev/null 2>&1; then
  pass "a2-bc2-diagnosis-decompose-accepted"
else
  fail "a2-bc2-diagnosis-decompose-accepted: rc=$RC out=$OUT"
fi
OUT=$(gt ruling --bc bc2-diagnosis --ruling proceed); RC=$?
if [ "$RC" -eq 64 ] && printf '%s' "$OUT" | jq -e '.accepted == false' >/dev/null 2>&1; then
  pass "a2-bc2-diagnosis-proceed-rejected-64"
else
  fail "a2-bc2-diagnosis-proceed-rejected-64: rc=$RC out=$OUT"
fi
OUT=$(gt ruling --bc bc2-diagnosis --ruling AGREE); RC=$?
if [ "$RC" -eq 64 ]; then pass "a2-bc2-diagnosis-agree-rejected-64"; else fail "a2-bc2-diagnosis-agree-rejected-64: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc6-diagnosis --ruling decompose); RC=$?
if [ "$RC" -eq 0 ]; then pass "a2-bc6-diagnosis-decompose-accepted"; else fail "a2-bc6-diagnosis-decompose-accepted: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc6-diagnosis --ruling halt); RC=$?
if [ "$RC" -eq 0 ]; then pass "a2-bc6-diagnosis-halt-accepted"; else fail "a2-bc6-diagnosis-halt-accepted: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc6-diagnosis --ruling AGREE); RC=$?
if [ "$RC" -eq 64 ]; then pass "a2-bc6-diagnosis-agree-rejected-64"; else fail "a2-bc6-diagnosis-agree-rejected-64: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc6-diagnosis --ruling proceed); RC=$?
if [ "$RC" -eq 64 ]; then pass "a2-bc6-diagnosis-proceed-rejected-64"; else fail "a2-bc6-diagnosis-proceed-rejected-64: rc=$RC out=$OUT"; fi

OUT=$(gt ruling --bc bc1-mis-fire --ruling halt-stands); RC=$?
if [ "$RC" -eq 0 ]; then pass "a2-bc1-mis-fire-halt-stands-accepted"; else fail "a2-bc1-mis-fire-halt-stands-accepted: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc1-mis-fire --ruling mis-fire); RC=$?
if [ "$RC" -eq 0 ]; then pass "a2-bc1-mis-fire-mis-fire-accepted"; else fail "a2-bc1-mis-fire-mis-fire-accepted: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc1-mis-fire --ruling AGREE); RC=$?
if [ "$RC" -eq 64 ]; then pass "a2-bc1-mis-fire-agree-rejected-64"; else fail "a2-bc1-mis-fire-agree-rejected-64: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc1-mis-fire --ruling halt); RC=$?
if [ "$RC" -eq 64 ]; then pass "a2-bc1-mis-fire-halt-rejected-64"; else fail "a2-bc1-mis-fire-halt-rejected-64: rc=$RC out=$OUT"; fi

OUT=$(gt ruling --bc bc7 --ruling AGREE); RC=$?
if [ "$RC" -eq 0 ]; then pass "a2-bc7-agree-accepted-m18"; else fail "a2-bc7-agree-accepted-m18: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc7 --ruling INSUFFICIENT); RC=$?
if [ "$RC" -eq 0 ]; then pass "a2-bc7-insufficient-accepted-m18"; else fail "a2-bc7-insufficient-accepted-m18: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc7 --ruling CONTRADICT); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.accepted == true' >/dev/null 2>&1; then
  pass "a2-bc7-contradict-accepted-m18"
else
  fail "a2-bc7-contradict-accepted-m18: rc=$RC out=$OUT"
fi
OUT=$(gt ruling --bc bc7 --ruling halt); RC=$?
if [ "$RC" -eq 64 ]; then pass "a2-bc7-non-m18-rejected-64"; else fail "a2-bc7-non-m18-rejected-64: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc7 --ruling decompose); RC=$?
if [ "$RC" -eq 64 ]; then pass "a2-bc7-decompose-rejected-64"; else fail "a2-bc7-decompose-rejected-64: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc7 --ruling agree); RC=$?
if [ "$RC" -eq 64 ]; then pass "a2-bc7-lowercase-agree-rejected-64"; else fail "a2-bc7-lowercase-agree-rejected-64: rc=$RC out=$OUT"; fi
OUT=$(gt ruling --bc bc7 --ruling ""); RC=$?
if [ "$RC" -eq 64 ]; then pass "a2-empty-ruling-rejected-64"; else fail "a2-empty-ruling-rejected-64: rc=$RC out=$OUT"; fi

# =============================================================================
# AC3 — shadow: every allowed ruling is logged as one class=gate-shadow row
# (bc, ruling, question, card context, ts) in runs/<run_id>/shadow.jsonl,
# applied:false; denylisted/unknown bc and out-of-vocab rulings never reach
# the log.
# =============================================================================

rm -rf "$ST"
OUT=$(gt shadow --run-id r1 --bc bc7 --ruling AGREE --question "is the halt warranted?"); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == false and .mode == "shadow"' >/dev/null 2>&1; then
  pass "a3-shadow-applied-false-never-auto-applied"
else
  fail "a3-shadow-applied-false-never-auto-applied: rc=$RC out=$OUT"
fi
ROW=$(sed -n '1p' "$ST/runs/r1/shadow.jsonl" 2>/dev/null)
if printf '%s' "$ROW" | jq -e '.class == "gate-shadow" and .bc == "bc7" and .ruling == "AGREE" and .question == "is the halt warranted?" and (.ts | length > 0)' >/dev/null 2>&1; then
  pass "a3-shadow-row-bc-ruling-question-ts"
else
  fail "a3-shadow-row-bc-ruling-question-ts: $ROW"
fi

printf '{"gate":"ship-choice","iteration":3}' > "$TMP/ctx.json"
gt shadow --run-id r1 --bc bc2-diagnosis --ruling halt --card-context "$TMP/ctx.json" >/dev/null
ROW=$(sed -n '2p' "$ST/runs/r1/shadow.jsonl" 2>/dev/null)
if printf '%s' "$ROW" | jq -e '.card_context == "{\"gate\":\"ship-choice\",\"iteration\":3}"' >/dev/null 2>&1; then
  pass "a3-shadow-logs-card-context"
else
  fail "a3-shadow-logs-card-context: $ROW"
fi

if grep -qF '$MROOT/.claude/advisor' "$GATES"; then
  pass "a3-default-state-root-in-source"
else
  fail "a3-default-state-root-in-source"
fi

rm -rf "$ST"
gt shadow --run-id rd --bc bc3 --ruling halt >/dev/null 2>&1
gt shadow --run-id rd --bc bc8 --ruling proceed >/dev/null 2>&1
gt shadow --run-id rd --bc bc2-diagnosis --ruling proceed >/dev/null 2>&1
gt shadow --run-id rd --bc vibes --ruling halt >/dev/null 2>&1
if [ ! -e "$ST/runs/rd/shadow.jsonl" ]; then
  pass "a3-denylisted-unknown-out-of-vocab-never-logged"
else
  fail "a3-denylisted-unknown-out-of-vocab-never-logged: $(cat "$ST/runs/rd/shadow.jsonl" 2>/dev/null)"
fi

rm -rf "$ST"
OUT=$(gt shadow --run-id ../esc --bc bc7 --ruling AGREE); RC=$?
if [ "$RC" -eq 64 ] && grep -qF 'invalid run-id' "$TMP/gt.err" \
  && [ ! -e "$ST/esc" ] && [ ! -e "$ST/runs" ]; then
  pass "a3-run-id-traversal-rejected-64"
else
  fail "a3-run-id-traversal-rejected-64: rc=$RC out=$OUT err=$(cat "$TMP/gt.err")"
fi

# Every allowed gate id gets an exhibited shadow row (round-3 council strike c2a).
# Rulings follow each id's M24 vocabulary: bc6-diagnosis accepts halt,
# bc1-mis-fire accepts mis-fire.
for PAIR in bc6-diagnosis:halt bc1-mis-fire:mis-fire; do
  ID=${PAIR%%:*}; RULING=${PAIR#*:}
  OUT=$(gt shadow --run-id r-all --bc "$ID" --ruling "$RULING"); RC=$?
  ROW=$(tail -n 1 "$ST/runs/r-all/shadow.jsonl" 2>/dev/null)
  if [ "$RC" -eq 0 ] && printf '%s' "$ROW" | jq -e --arg g "$ID" --arg r "$RULING" '.class == "gate-shadow" and .bc == $g and .ruling == $r' >/dev/null 2>&1; then
    pass "a3-shadow-logs-$ID"
  else
    fail "a3-shadow-logs-$ID: rc=$RC row=$ROW"
  fi
done

# One shadow row carries all five fields; the raw row is echoed to the log.
rm -rf "$ST"
printf '{"gate":"ship-choice","iteration":3}' > "$TMP/ctx.json"
OUT=$(gt shadow --run-id r5f --bc bc7 --ruling AGREE --question "q5f" --card-context "$TMP/ctx.json"); RC=$?
ROW=$(sed -n '1p' "$ST/runs/r5f/shadow.jsonl" 2>/dev/null)
if [ "$RC" -eq 0 ] \
  && printf '%s' "$ROW" | jq -e '.class == "gate-shadow" and .bc == "bc7" and .ruling == "AGREE" and .question == "q5f" and (.card_context | length > 0) and (.ts | length > 0)' >/dev/null 2>&1; then
  pass "a3-shadow-row-five-fields-one-row"
  echo "ROW: $ROW"
else
  fail "a3-shadow-row-five-fields-one-row: rc=$RC row=$ROW"
fi

# Out-of-vocab ruling is never logged, for every allowed gate id.
rm -rf "$ST"
for ID in bc7 bc2-diagnosis bc6-diagnosis bc1-mis-fire; do
  gt shadow --run-id rnv --bc "$ID" --ruling bogus >/dev/null 2>&1
done
if [ ! -e "$ST/runs/rnv/shadow.jsonl" ]; then
  pass "a3-shadow-out-of-vocab-never-logged-matrix"
else
  fail "a3-shadow-out-of-vocab-never-logged-matrix: $(cat "$ST/runs/rnv/shadow.jsonl" 2>/dev/null)"
fi

# Executed default state root: ADVISOR_STATE_ROOT unset. gates.sh resolves the
# default root from git-common-dir — inside a linked worktree that is the main
# repo root, NOT this worktree root, so resolve it the same way gates.sh does.
DEF_ROOT=$(git rev-parse --git-common-dir 2>/dev/null) \
  && DEF_ROOT=$(cd "$(dirname "$DEF_ROOT")" && pwd) || DEF_ROOT="$ROOT"
OUT=$(env -u ADVISOR_STATE_ROOT timeout 20 bash "$GATES" shadow \
  --run-id default-probe --bc bc7 --ruling AGREE); RC=$?
ROW=$(sed -n '1p' "$DEF_ROOT/.claude/advisor/runs/default-probe/shadow.jsonl" 2>/dev/null)
if [ "$RC" -eq 0 ] && printf '%s' "$ROW" | jq -e '.class == "gate-shadow"' >/dev/null 2>&1; then
  pass "a3-default-state-root-executed"
else
  fail "a3-default-state-root-executed: rc=$RC row=$ROW"
fi
rm -rf "$DEF_ROOT/.claude/advisor/runs/default-probe"

# =============================================================================
# AC4 — shadow window: default N=5; ADVISOR_SHADOW_N only lowers (invalid
# ignored); shadow_used increments; mode stays shadow at and after N=5.
# =============================================================================

rm -rf "$ST"
OUT=$(gt mode --run-id m1)
if printf '%s' "$OUT" | jq -e '.mode == "shadow" and .shadow_n == 5 and .shadow_used == 0' >/dev/null 2>&1; then
  pass "a4-mode-default-n-5"
else
  fail "a4-mode-default-n-5: $OUT"
fi
OUT=$(ADVISOR_SHADOW_N=3 ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" mode --run-id m1)
if printf '%s' "$OUT" | jq -e '.shadow_n == 3' >/dev/null 2>&1; then
  pass "a4-shadow-n-env-lowers"
else
  fail "a4-shadow-n-env-lowers: $OUT"
fi
OUT=$(ADVISOR_SHADOW_N=junk ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" mode --run-id m1)
if printf '%s' "$OUT" | jq -e '.shadow_n == 5' >/dev/null 2>&1; then
  pass "a4-shadow-n-invalid-ignored"
else
  fail "a4-shadow-n-invalid-ignored: $OUT"
fi
OUT=$(ADVISOR_SHADOW_N=9 ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" mode --run-id m1)
if printf '%s' "$OUT" | jq -e '.shadow_n == 5' >/dev/null 2>&1; then
  pass "a4-shadow-n-above-default-ignored"
else
  fail "a4-shadow-n-above-default-ignored: $OUT"
fi

rm -rf "$ST"
gt shadow --run-id m2 --bc bc7 --ruling AGREE >/dev/null
OUT=$(gt mode --run-id m2)
if printf '%s' "$OUT" | jq -e '.shadow_used == 1 and .mode == "shadow"' >/dev/null 2>&1; then
  pass "a4-shadow-used-increments"
else
  fail "a4-shadow-used-increments: $OUT"
fi
i=1
while [ "$i" -le 4 ]; do # fill the window to used=5
  gt shadow --run-id m2 --bc bc7 --ruling AGREE >/dev/null
  i=$((i + 1))
done
OUT=$(gt mode --run-id m2)
if printf '%s' "$OUT" | jq -e '.shadow_used == 5 and .mode == "shadow"' >/dev/null 2>&1; then
  pass "a4-mode-shadow-at-n-boundary"
else
  fail "a4-mode-shadow-at-n-boundary: $OUT"
fi
gt shadow --run-id m2 --bc bc7 --ruling AGREE >/dev/null # 6th ruling
OUT=$(gt mode --run-id m2)
if printf '%s' "$OUT" | jq -e '.shadow_used == 6 and .mode == "shadow"' >/dev/null 2>&1; then
  pass "a4-mode-shadow-after-n-boundary"
else
  fail "a4-mode-shadow-after-n-boundary: $OUT"
fi

# =============================================================================
# AC5 — no automatic growth past shadow: zero widen transitions in the source
# and the counter never flips the mode.
# =============================================================================

if [ "$(grep -ci 'widen' "$GATES")" -eq 0 ]; then
  pass "a5-no-widen-transition-in-source"
else
  fail "a5-no-widen-transition-in-source: $(grep -in 'widen' "$GATES")"
fi
i=1
while [ "$i" -le 7 ]; do # past any boundary the mode must still be shadow
  gt shadow --run-id m3 --bc bc7 --ruling AGREE >/dev/null
  i=$((i + 1))
done
OUT=$(gt mode --run-id m3)
if printf '%s' "$OUT" | jq -e '.shadow_used == 7 and .mode == "shadow"' >/dev/null 2>&1; then
  pass "a5-counter-never-flips-mode"
else
  fail "a5-counter-never-flips-mode: $OUT"
fi
i=1
while [ "$i" -le 7 ]; do # fresh run-id, past any boundary: mode is still shadow
  gt shadow --run-id m5 --bc bc7 --ruling AGREE >/dev/null
  i=$((i + 1))
done
OUT=$(gt mode --run-id m5)
if printf '%s' "$OUT" | jq -e '.mode == "shadow"' >/dev/null 2>&1; then
  pass "a5-mode-still-reports-mode-shadow — mode: shadow exhibited after 7 recorded rulings"
else
  fail "a5-mode-still-reports-mode-shadow: $OUT"
fi

# =============================================================================
# AC6 — autopilot surface: the self-answer.md §3g trigger-(a) fence, gated on
# ADVISOR_ON=true with the ADVISOR_SKIP_TRIGGER=1 bypass; silent when off or
# bypassed; the refusal emits the halt signal on stderr; the halt MUST NOT
# persist.
# =============================================================================

FENCE=""
FENCE=$(awk '/CDT-563 trigger-\(a\) restricted gate/{f=1} f{print} f&&/^fi$/{exit}' "$SA")
if [ -n "$FENCE" ]; then
  pass "a6-fence-extractable"
else
  fail "a6-fence-extractable"
fi
case "$FENCE" in
  *'ADVISOR_ON:-}" = "true"'*'ADVISOR_SKIP_TRIGGER'*) pass "a6-fence-gated-advisor-on-and-bypass" ;;
  *) fail "a6-fence-gated-advisor-on-and-bypass" ;;
esac
case "$FENCE" in
  *"MUST NOT"*) pass "a6-fence-halt-must-not-persist" ;;
  *) fail "a6-fence-halt-must-not-persist" ;;
esac
case "$FENCE" in
  *"--bc"*) pass "a6-fence-invokes-gate-allow" ;;
  *) fail "a6-fence-invokes-gate-allow" ;;
esac

OUT=$(env -u ADVISOR_ON -u ADVISOR_SKIP_TRIGGER -u STUB_GATES bash -c "$FENCE" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "a6-fence-off-silent-executed"
else
  fail "a6-fence-off-silent-executed: rc=$RC out=$OUT"
fi
OUT=$(env -u STUB_GATES ADVISOR_ON=true ADVISOR_SKIP_TRIGGER=1 bash -c "$FENCE" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "a6-fence-bypass-silent-executed"
else
  fail "a6-fence-bypass-silent-executed: rc=$RC out=$OUT"
fi

# Refusal: PDH stubbed to the REAL gates.sh — the "<gate-id>" placeholder is
# an unknown id, so allow exits 64 and the fence emits the halt signal.
STUB="$TMP/stubpd"
mkdir -p "$STUB/skills"
cp "$GATES" "$STUB/stub-gates.sh"
printf '#!/usr/bin/env bash\nprintf "%%s" "${STUB_GATES:?}"\n' > "$STUB/skills/plugin-dir.sh"
OUT=$(env STUB_GATES="$STUB/stub-gates.sh" PDH="$STUB" ADVISOR_ON=true TMPDIR="$TMP" bash -c "$FENCE" 2>&1); RC=$?
case "$OUT" in
  *"advisor trigger-(a) gate refused — the halt stands"*)
    pass "a6-fence-refusal-halt-signal-on-stderr" ;;
  *) fail "a6-fence-refusal-halt-signal-on-stderr: rc=$RC out=$OUT" ;;
esac
case "$OUT" in
  *"unknown gate id"*) pass "a6-fence-refusal-carries-stable-reason" ;;
  *) fail "a6-fence-refusal-carries-stable-reason: out=$OUT" ;;
esac

# =============================================================================
# AC7 — SKILL.md documents the gate: subcommands, denylist ids, M24
# vocabularies, and the shadow log path.
# =============================================================================

if grep -q 'allow --bc' "$SKILL" && grep -q 'ruling --bc' "$SKILL" \
  && grep -q 'shadow --run-id' "$SKILL" && grep -q 'mode --run-id' "$SKILL"; then
  pass "a7-skill-documents-gate-subcommands"
else
  fail "a7-skill-documents-gate-subcommands"
fi
if grep -qF 'bc1-as-human-preference' "$SKILL" && grep -qF 'bc6-extension' "$SKILL" \
  && grep -qF 'bc3' "$SKILL" && grep -qF 'bc8' "$SKILL"; then
  pass "a7-skill-documents-denylist-ids"
else
  fail "a7-skill-documents-denylist-ids"
fi
if grep -qF 'halt|decompose' "$SKILL" && grep -qF 'halt-stands|mis-fire' "$SKILL"; then
  pass "a7-skill-documents-m24-vocabularies"
else
  fail "a7-skill-documents-m24-vocabularies"
fi
if grep -qF 'runs/<run_id>/shadow.jsonl' "$SKILL"; then
  pass "a7-skill-documents-shadow-log-path"
else
  fail "a7-skill-documents-shadow-log-path"
fi
if grep -qF 'gates.sh mode --run-id ID' "$SKILL"; then
  pass "a4-skill-documents-subprocess-invocation"
else
  fail "a4-skill-documents-subprocess-invocation"
fi
if grep -qF 'AGREE|CONTRADICT|INSUFFICIENT' "$SKILL"; then
  pass "a7-skill-documents-m18-vocabulary"
else
  fail "a7-skill-documents-m18-vocabulary"
fi
if grep -qF 'gates.sh shadow --run-id ID --bc <gate> --ruling <ruling>' "$SKILL"; then
  pass "a3-skill-documents-full-shadow-invocation"
else
  fail "a3-skill-documents-full-shadow-invocation"
fi

# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
