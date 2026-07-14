#!/usr/bin/env bash
#
# metrics/test.sh — SPEC-026 bite-tests for emit-outcome.sh + outcome-rates.sh
#
# Machine-check: bash skills/metrics/test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EMIT="$SCRIPT_DIR/emit-outcome.sh"
RATES="$SCRIPT_DIR/outcome-rates.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# ---- Temp git repo (fake MROOT via git-common-dir) ---------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/metrics-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q "$TMP" || { echo "FAIL: git init" >&2; exit 1; }
cd "$TMP" || { echo "FAIL: cd $TMP" >&2; exit 1; }

LEDGER=".claude/metrics/outcomes.jsonl"

emit() {
  bash "$EMIT" "$@"
}

rates() {
  bash "$RATES" "$@"
}

reset_ledger() {
  rm -rf .claude/metrics
}

# =============================================================================
# 1. Append + append-only prior line identity
# =============================================================================
reset_ledger
emit "CDV-185" "T1" "ic4" "refactor" "M" "accepted" 2 1 0
RC=$?
LINES=$(wc -l < "$LEDGER" | tr -d ' ')
if [ "$RC" -eq 0 ] && [ "$LINES" -eq 1 ]; then
  pass "1a emit appends one line (rc=0)"
else
  fail "1a emit rc=$RC lines=$LINES (want 0 / 1)"
fi

LINE1=$(cat "$LEDGER")
emit "CDV-185" "T1b" "ic4" "refactor" "S" "accepted" 0 0 0
LINES=$(wc -l < "$LEDGER" | tr -d ' ')
LINE1_AFTER=$(head -n 1 "$LEDGER")
if [ "$LINES" -eq 2 ] && [ "$LINE1" = "$LINE1_AFTER" ]; then
  pass "1b second emit appends; prior line byte-identical"
else
  fail "1b append-only broken lines=$LINES prior_match=$([ "$LINE1" = "$LINE1_AFTER" ] && echo y || echo n)"
fi

# =============================================================================
# 2. Schema keys / enums / nulls
# =============================================================================
reset_ledger
emit "null" "null" "ic5" "null" "null" "escalated" "null" "null" "null"
REC=$(tail -n 1 "$LEDGER")
KEYS_OK=$(printf '%s' "$REC" | jq -e '
  has("ts") and has("ticket") and has("task_id") and has("agent")
  and has("task_class") and has("size") and has("outcome")
  and has("review_cycles") and has("qa_bounces") and has("council_overturns")
  and (.ticket == null) and (.task_id == null) and (.task_class == null)
  and (.size == null) and (.review_cycles == null) and (.qa_bounces == null)
  and (.council_overturns == null)
  and (.agent == "ic5") and (.outcome == "escalated")
  and (.ts | type == "number")
' >/dev/null 2>&1 && echo y || echo n)
if [ "$KEYS_OK" = "y" ]; then
  pass "2a schema keys + nulls + enums"
else
  fail "2a schema/nulls: $REC"
fi

# invalid agent / outcome → 64
RC=0
OUT=$(emit "t" "id" "tech-lead" "refactor" "M" "accepted" 0 0 0 2>&1) || RC=$?
if [ "$RC" -eq 64 ]; then
  pass "2b invalid agent exits 64"
else
  fail "2b invalid agent rc=$RC (want 64)"
fi

RC=0
OUT=$(emit "t" "id" "ic4" "refactor" "M" "success" 0 0 0 2>&1) || RC=$?
if [ "$RC" -eq 64 ]; then
  pass "2c invalid outcome exits 64"
else
  fail "2c invalid outcome rc=$RC (want 64)"
fi

RC=0
OUT=$(emit too few args 2>&1) || RC=$?
if [ "$RC" -eq 64 ]; then
  pass "2d wrong argc exits 64"
else
  fail "2d wrong argc rc=$RC (want 64)"
fi

# =============================================================================
# 3. Fail-open without jq (PATH without jq)
# =============================================================================
reset_ledger
NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
for c in bash sh git date mkdir cat dirname pwd tr wc head tail uname; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -sf "$p" "$NOJQ_BIN/$(basename "$p")"
done
BASH_ABS=$(command -v bash)
# Ensure jq is NOT on PATH for the child (invoke bash by absolute path)
RC=0
ERR=$(env PATH="$NOJQ_BIN" "$BASH_ABS" "$EMIT" "CDV-185" "T3" "ic4" "refactor" "M" "accepted" 0 0 0 2>&1 >/dev/null) || RC=$?
if [ "$RC" -eq 0 ] && [ ! -f "$LEDGER" ] && printf '%s' "$ERR" | grep -qi 'jq'; then
  pass "3 fail-open without jq (rc=0, no write, stderr notice)"
else
  fail "3 no-jq rc=$RC ledger=$([ -f "$LEDGER" ] && echo y || echo n) err=$ERR"
fi

# =============================================================================
# 4. Fail-open unwritable metrics dir
# =============================================================================
reset_ledger
mkdir -p .claude
chmod 555 .claude
RC=0
ERR=$(emit "CDV-185" "T4" "ic4" "refactor" "M" "accepted" 0 0 0 2>&1 >/dev/null) || RC=$?
chmod 755 .claude 2>/dev/null || true
if [ "$RC" -eq 0 ] && [ ! -f "$LEDGER" ] && printf '%s' "$ERR" | grep -qi 'skipping\|cannot'; then
  pass "4 fail-open unwritable metrics dir"
else
  fail "4 unwritable rc=$RC ledger=$([ -f "$LEDGER" ] && echo y || echo n) err=$ERR"
fi

# =============================================================================
# 5. Corrupt JSONL skipped by rates
# =============================================================================
reset_ledger
mkdir -p .claude/metrics
# 2 good + 1 corrupt + 1 good = 3 countable for (ic4, refactor)
emit "CDV-185" "c1" "ic4" "refactor" "M" "accepted" 1 0 0
printf 'NOT-JSON{{{\n' >> "$LEDGER"
emit "CDV-185" "c2" "ic4" "refactor" "M" "escalated" 2 0 0
emit "CDV-185" "c3" "ic4" "refactor" "M" "accepted" 0 0 0
JSON=$(rates ic4 refactor --json)
N=$(printf '%s' "$JSON" | jq -r '.n')
E=$(printf '%s' "$JSON" | jq -r '.escalated_count')
if [ "$N" = "3" ] && [ "$E" = "1" ]; then
  pass "5 corrupt JSONL line skipped (n=3 e=1)"
else
  fail "5 corrupt skip got n=$N e=$E json=$JSON"
fi

# =============================================================================
# 6. Cold-start silence n=3
# =============================================================================
reset_ledger
i=1
while [ "$i" -le 3 ]; do
  emit "CDV-185" "cs$i" "ic4" "refactor" "M" "escalated" 3 0 0
  i=$((i + 1))
done
HUMAN=$(OUTCOME_MIN_SAMPLES=5 rates ic4 refactor 2>/dev/null || true)
JSON=$(OUTCOME_MIN_SAMPLES=5 rates ic4 refactor --json)
ADV=$(printf '%s' "$JSON" | jq -r '.advisory')
N=$(printf '%s' "$JSON" | jq -r '.n')
if [ -z "$HUMAN" ] && [ "$ADV" = "false" ] && [ "$N" = "3" ]; then
  pass "6 cold-start silence n=3 (empty stdout, advisory=false)"
else
  fail "6 cold-start human='$HUMAN' adv=$ADV n=$N"
fi

# =============================================================================
# 7. Advisory fires n=5 high escalate rate on refactor
# =============================================================================
reset_ledger
# 3 escalated + 2 accepted = rate 0.6 ≥ 0.5, n=5
for i in 1 2 3; do
  emit "CDV-185" "a$i" "ic4" "refactor" "M" "escalated" 2 0 0
done
for i in 4 5; do
  emit "CDV-185" "a$i" "ic4" "refactor" "M" "accepted" 0 0 0
done
HUMAN=$(OUTCOME_MIN_SAMPLES=5 rates ic4 refactor 2>/dev/null || true)
JSON=$(OUTCOME_MIN_SAMPLES=5 rates ic4 refactor --json)
ADV=$(printf '%s' "$JSON" | jq -r '.advisory')
ALT=$(printf '%s' "$JSON" | jq -r '.alt')
N=$(printf '%s' "$JSON" | jq -r '.n')
E=$(printf '%s' "$JSON" | jq -r '.escalated_count')
if [ "$ADV" = "true" ] && [ "$ALT" = "ic5" ] && [ "$N" = "5" ] && [ "$E" = "3" ] \
  && printf '%s' "$HUMAN" | grep -q '^Advisory: ic4 escalated 3/5 refactor' \
  && printf '%s' "$HUMAN" | grep -q 'consider ic5'; then
  pass "7 advisory fires n=5 escalated 3/5 refactor → ic5"
else
  fail "7 advisory human='$HUMAN' json=$JSON"
fi

# =============================================================================
# 8. Boundary: impl-novel never advises ic4; no tech-lead alt
# =============================================================================
reset_ledger
# ic5 + impl-novel: high escalate, n=5 — alt empty → no advisory (never suggest ic4)
for i in 1 2 3 4 5; do
  emit "CDV-185" "n$i" "ic5" "impl-novel" "L" "escalated" 3 0 0
done
HUMAN=$(OUTCOME_MIN_SAMPLES=5 rates ic5 impl-novel 2>/dev/null || true)
JSON=$(OUTCOME_MIN_SAMPLES=5 rates ic5 impl-novel --json)
ADV=$(printf '%s' "$JSON" | jq -r '.advisory')
ALT=$(printf '%s' "$JSON" | jq -r '.alt')
if [ -z "$HUMAN" ] && [ "$ADV" = "false" ] && [ "$ALT" = "null" ]; then
  pass "8a impl-novel never advises ic4 (silence, alt=null)"
else
  fail "8a impl-novel boundary human='$HUMAN' json=$JSON"
fi

# ic5 + refactor may suggest ic4 (control — legal flip)
reset_ledger
for i in 1 2 3 4 5; do
  emit "CDV-185" "r$i" "ic5" "refactor" "M" "escalated" 2 0 0
done
JSON=$(OUTCOME_MIN_SAMPLES=5 rates ic5 refactor --json)
ALT=$(printf '%s' "$JSON" | jq -r '.alt')
ADV=$(printf '%s' "$JSON" | jq -r '.advisory')
if [ "$ADV" = "true" ] && [ "$ALT" = "ic4" ]; then
  pass "8b ic5+refactor may advise ic4 (legal)"
else
  fail "8b ic5 refactor control json=$JSON"
fi

# No agent path yields tech-lead / pm as alt
reset_ledger
for agent_tc in "ic4:refactor" "ic5:test" "local:impl-extend" "qa:test" "devops:infra" "ds:discovery"; do
  agent=${agent_tc%%:*}
  tc=${agent_tc##*:}
  for i in 1 2 3 4 5; do
    emit "CDV-185" "b${agent}$i" "$agent" "$tc" "M" "escalated" 3 0 0
  done
done
BAD_ALT=0
for agent_tc in "ic4:refactor" "ic5:test" "local:impl-extend" "qa:test" "devops:infra" "ds:discovery"; do
  agent=${agent_tc%%:*}
  tc=${agent_tc##*:}
  ALT=$(OUTCOME_MIN_SAMPLES=5 rates "$agent" "$tc" --json | jq -r '.alt // empty')
  case "$ALT" in
    tech-lead|pm|qa|devops|ds) BAD_ALT=1; echo "  bad alt for $agent/$tc: $ALT" >&2 ;;
  esac
done
if [ "$BAD_ALT" -eq 0 ]; then
  pass "8c no tech-lead/pm (or other boundary-cross) alt ever proposed"
else
  fail "8c boundary-crossing alt detected"
fi

# =============================================================================
# 9. Rates treat only escalated as failure metric
# =============================================================================
reset_ledger
# 2 accepted + 2 rejected + 1 escalated → n=5, escalated_count=1, rate=0.2
emit "CDV-185" "f1" "ic4" "test" "S" "accepted" 0 0 0
emit "CDV-185" "f2" "ic4" "test" "S" "accepted" 1 0 0
emit "CDV-185" "f3" "ic4" "test" "S" "rejected" 0 0 0
emit "CDV-185" "f4" "ic4" "test" "S" "rejected" 2 0 0
emit "CDV-185" "f5" "ic4" "test" "S" "escalated" 1 0 0
JSON=$(OUTCOME_MIN_SAMPLES=5 rates ic4 test --json)
N=$(printf '%s' "$JSON" | jq -r '.n')
E=$(printf '%s' "$JSON" | jq -r '.escalated_count')
RATE=$(printf '%s' "$JSON" | jq -r '.escalated_rate')
ADV=$(printf '%s' "$JSON" | jq -r '.advisory')
# rate 0.2 < 0.5; mean cycles (0+1+0+2+1)/5 = 0.8 < 2.0 → no advisory
if [ "$N" = "5" ] && [ "$E" = "1" ] && [ "$ADV" = "false" ] \
  && printf '%s' "$JSON" | jq -e '.escalated_rate == 0.2' >/dev/null; then
  pass "9 rates count only escalated as failure (e=1 rate=0.2; rejected ignored)"
else
  fail "9 failure metric json=$JSON"
fi

# null task_class excluded from aggregation
reset_ledger
for i in 1 2 3 4 5; do
  emit "CDV-185" "null$i" "ic4" "null" "M" "escalated" 5 0 0
done
JSON=$(OUTCOME_MIN_SAMPLES=5 rates ic4 refactor --json)
N=$(printf '%s' "$JSON" | jq -r '.n')
if [ "$N" = "0" ]; then
  pass "9b null task_class excluded from rates cells"
else
  fail "9b null class leaked n=$N json=$JSON"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
