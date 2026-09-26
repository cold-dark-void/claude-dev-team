#!/usr/bin/env bash
#
# autopilot/test-ship-gate-verdict.sh — fixture tests for ship-gate-verdict.sh
# (SPEC-033 M14(b)/(d)/(h)/(i), WP 1-14 T5, interface contract C4).
#
# Machine-check: bash skills/autopilot/test-ship-gate-verdict.sh  (exit 0, all PASS)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Covers plan T5 AC D/E/F cases:
#   F(i)-(v): 7-AC agree (both merge/patch and pr/null card1), one CONTRADICTED,
#     one missing, one at 79, self-verified at 95.
#   [process] fail-closed: zero technical ACs (empty ac_claims), a guard-1
#     split failure (--no-report), a stamp-shape miss (guard 3).
#   Unreadable meta / unreadable card1 -> halt, confidence 0.
#   Extra: duplicate verdicts (worst verdict wins, lowest confidence used),
#     untagged verdict ignored, verdict outside taxonomy -> unaudited,
#     non-M14 sidecar (no ac_claims) -> halt, struck-only AC -> unaudited,
#     float confidence floored, boundary 80 -> agree, mixed
#     unaudited+failed -> unaudited wins (M14(b) step order), argv misuse,
#     BC7-confidence invariant, one-line rationale ending council_tier=<t>.
#   Tech-lead review round 1 (B4a/B4b/B4c/N1): process_acs not a JSON array,
#     an ac_claims entry without ac_id, card #1 decision halt/missing on the
#     agree path, an unknown verification_mode, confidence outside [0,100]
#     (150 and -5) -- every case still exits 0 with valid JSON, never a bare
#     jq crash.
#   Tech-lead review round 2 (B-1): an absent, null or false verification_mode
#     must not be defaulted to "full" by `// "full"` (fail-open) -- each halts,
#     BC7, confidence 0.
#
# Every produced card2 JSON is also piped through append-card.sh in a
# hermetic temp git repo (never the live .claude/autopilot/) and MUST
# exit 0 — proving the mapper's output is writer-acceptable.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAPPER="$SCRIPT_DIR/ship-gate-verdict.sh"
APPEND="$SCRIPT_DIR/append-card.sh"
FIX="$SCRIPT_DIR/fixtures/ship-gate-verdict"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# ---- Hermetic temp git repo (fake MROOT for append-card.sh) -----------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ship-gate-verdict-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q "$TMP" || { echo "FAIL: git init" >&2; exit 1; }
cd "$TMP" || { echo "FAIL: cd $TMP" >&2; exit 1; }
AUTODIR="$TMP/.claude/autopilot"

# run_mapper <args...> -> sets G_OUT, G_RC (does not exit on nonzero)
run_mapper() {
  G_OUT=$(bash "$MAPPER" "$@" 2>"$TMP/stderr")
  G_RC=$?
  G_ERR=$(cat "$TMP/stderr")
}

# append_ok <label> — feed the last G_OUT through append-card.sh in a fresh
# ledger slot; assert exit 0 (AUTOPILOT_ROOT-equivalent: this repo IS the
# fake MROOT via git-common-dir; never touches the real .claude/autopilot/).
append_ok() {
  local label="$1" ticket="append-ok-$RANDOM$RANDOM"
  local decision bc confidence bump rationale rc
  decision=$(printf '%s' "$G_OUT" | jq -r '.decision')
  bc=$(printf '%s' "$G_OUT" | jq -r '.blocking_condition // "null"')
  confidence=$(printf '%s' "$G_OUT" | jq -r '.confidence')
  bump=$(printf '%s' "$G_OUT" | jq -r '.bump // "null"')
  rationale=$(printf '%s' "$G_OUT" | jq -r '.rationale')
  rc=0
  bash "$APPEND" orchestrate append-ok-ticket ship-choice "$decision" auto \
    "$bump" "$confidence" "$bc" run-1 0 10 orchestrator "$rationale" \
    >/dev/null 2>"$TMP/append-stderr" || rc=$?
  rm -f "$AUTODIR/append-ok-ticket.jsonl"
  if [ "$rc" -eq 0 ]; then
    pass "$label: append-card.sh accepts mapper output (rc=0)"
  else
    fail "$label: append-card.sh rc=$rc (want 0): $(cat "$TMP/append-stderr")"
  fi
}

# assert_field <label> <jq-filter> <expected>
assert_field() {
  local label="$1" filter="$2" expected="$3" got
  got=$(printf '%s' "$G_OUT" | jq -r "$filter" 2>/dev/null)
  if [ "$got" = "$expected" ]; then
    pass "$label: $filter == $expected"
  else
    fail "$label: $filter == '$got' (want '$expected') full=$G_OUT"
  fi
}

# assert_rationale_shape <label> <tier> — one line, no control chars, ends
# with the exact "; council_tier=<t>" suffix (C4).
assert_rationale_shape() {
  local label="$1" tier="$2" rationale
  rationale=$(printf '%s' "$G_OUT" | jq -r '.rationale')
  case "$rationale" in
    *$'\n'*) fail "$label: rationale has an embedded newline" ; return ;;
  esac
  if printf '%s' "$rationale" | grep -q '[[:cntrl:]]'; then
    fail "$label: rationale has a control char"
  else
    pass "$label: rationale has no control chars"
  fi
  case "$rationale" in
    *"; council_tier=$tier") pass "$label: rationale ends '; council_tier=$tier'" ;;
    *) fail "$label: rationale does not end '; council_tier=$tier': $rationale" ;;
  esac
}

# assert_rc0_json <label> — every computed outcome is exit 0 with valid JSON.
assert_rc0_json() {
  local label="$1"
  if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e . >/dev/null 2>&1; then
    pass "$label: exit 0, valid JSON"
  else
    fail "$label: rc=$G_RC json=$G_OUT stderr=$G_ERR"
  fi
}

# assert_bc7_confidence_invariant <label> — append-card.sh invariant (b):
# blocking_condition=7 requires confidence < 80. The mapper MUST NEVER
# violate this (BC7 with confidence >= 80).
assert_bc7_confidence_invariant() {
  local label="$1" ok
  ok=$(printf '%s' "$G_OUT" | jq -e '
    (.blocking_condition != 7) or (.confidence < 80)
  ' >/dev/null 2>&1 && echo yes || echo no)
  if [ "$ok" = yes ]; then
    pass "$label: BC7 => confidence < 80 holds"
  else
    fail "$label: BC7 with confidence >= 80 -- FORBIDDEN: $G_OUT"
  fi
}

# full_check <label> <tier> — bundles the 3 checks every case must pass.
full_check() {
  local label="$1" tier="$2"
  assert_rc0_json "$label"
  assert_bc7_confidence_invariant "$label"
  assert_rationale_shape "$label" "$tier"
  append_ok "$label"
}

# =============================================================================
# F(i) — all 7 ACs VERIFIED >= 80 -> agree, bump copied. Two card1 variants.
# =============================================================================
run_mapper --meta "$FIX/meta-7ac-verified.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "F(i)a merge/patch" light
assert_field "F(i)a" ".decision" "merge"
assert_field "F(i)a" ".blocking_condition" "null"
assert_field "F(i)a" ".confidence" "82"
assert_field "F(i)a" ".bump" "patch"

run_mapper --meta "$FIX/meta-7ac-verified.json" --card1 "$FIX/card1-pr-null.json" --tier full
full_check "F(i)b pr/null" full
assert_field "F(i)b" ".decision" "pr"
assert_field "F(i)b" ".blocking_condition" "null"
assert_field "F(i)b" ".confidence" "82"
assert_field "F(i)b" ".bump" "null"

# =============================================================================
# F(ii) — one CONTRADICTED -> halt, 0
# =============================================================================
run_mapper --meta "$FIX/meta-one-contradicted.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "F(ii)" light
assert_field "F(ii)" ".decision" "halt"
assert_field "F(ii)" ".blocking_condition" "7"
assert_field "F(ii)" ".confidence" "0"
assert_field "F(ii)" ".bump" "null"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"B=CONTRADICTED"*) pass "F(ii): rationale names failed AC id + verdict" ;;
  *) fail "F(ii): rationale missing B=CONTRADICTED: $G_OUT" ;;
esac

# =============================================================================
# F(iii) — one AC missing -> halt, 0, rationale names the id
# =============================================================================
run_mapper --meta "$FIX/meta-one-missing.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "F(iii)" light
assert_field "F(iii)" ".decision" "halt"
assert_field "F(iii)" ".blocking_condition" "7"
assert_field "F(iii)" ".confidence" "0"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"C"*) pass "F(iii): rationale names unaudited AC id C" ;;
  *) fail "F(iii): rationale missing C: $G_OUT" ;;
esac

# =============================================================================
# F(iv) — one AC at 79 -> halt, confidence STAYS 79 (not forced to 0)
# =============================================================================
run_mapper --meta "$FIX/meta-one-79.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "F(iv)" light
assert_field "F(iv)" ".decision" "halt"
assert_field "F(iv)" ".blocking_condition" "7"
assert_field "F(iv)" ".confidence" "79"
assert_field "F(iv)" ".bump" "null"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"E=79"*) pass "F(iv): rationale names AC id below 80 with its confidence" ;;
  *) fail "F(iv): rationale missing E=79: $G_OUT" ;;
esac

# =============================================================================
# F(v) — self-verified, all ACs at 95 -> halt, 0 (degraded run always halts)
# =============================================================================
run_mapper --meta "$FIX/meta-selfverified-95.json" --card1 "$FIX/card1-merge-patch.json" --tier full
full_check "F(v)" full
assert_field "F(v)" ".decision" "halt"
assert_field "F(v)" ".blocking_condition" "7"
assert_field "F(v)" ".confidence" "0"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"self-verified — refuters unavailable"*) pass "F(v): rationale cites the exact degraded marker" ;;
  *) fail "F(v): rationale missing degraded marker: $G_OUT" ;;
esac

# =============================================================================
# [process] fail-closed case 1: zero technical ACs (empty ac_claims[])
# =============================================================================
run_mapper --meta "$FIX/meta-empty-ac-claims.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "process-fail zero-technical-ACs" light
assert_field "process-fail zero-technical-ACs" ".decision" "halt"
assert_field "process-fail zero-technical-ACs" ".blocking_condition" "7"
assert_field "process-fail zero-technical-ACs" ".confidence" "0"

# =============================================================================
# [process] fail-closed case 2: guard-1 split failure -> --no-report
# =============================================================================
run_mapper --no-report "m14-ac-split: case 8: [process] AC fails guard 1: B" \
  --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "process-fail guard1-miss" light
assert_field "process-fail guard1-miss" ".decision" "halt"
assert_field "process-fail guard1-miss" ".blocking_condition" "7"
assert_field "process-fail guard1-miss" ".confidence" "0"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"m14-ac-split: case 8"*) pass "process-fail guard1-miss: rationale carries the cause" ;;
  *) fail "process-fail guard1-miss: rationale missing cause: $G_OUT" ;;
esac

# =============================================================================
# [process] fail-closed case 3: M14(h) guard 3 — process ACs present, card #1
# fails the stamp shape -> halt, 0 (regardless of otherwise-passing ACs).
# =============================================================================
run_mapper --meta "$FIX/meta-guard3.json" --card1 "$FIX/card1-badstamp.json" --tier light
full_check "process-fail stamp-shape-miss" light
assert_field "process-fail stamp-shape-miss" ".decision" "halt"
assert_field "process-fail stamp-shape-miss" ".blocking_condition" "7"
assert_field "process-fail stamp-shape-miss" ".confidence" "0"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"H"*"stamp shape"*) pass "process-fail stamp-shape-miss: rationale names process AC + stamp cause" ;;
  *) fail "process-fail stamp-shape-miss: rationale missing detail: $G_OUT" ;;
esac

# Guard 3 must NOT false-positive when the stamp is fine (same process ACs,
# good card #1) — the technical ACs still get matched normally -> agree.
run_mapper --meta "$FIX/meta-guard3.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "process-pass stamp-shape-ok" light
assert_field "process-pass stamp-shape-ok" ".decision" "merge"
assert_field "process-pass stamp-shape-ok" ".blocking_condition" "null"
assert_field "process-pass stamp-shape-ok" ".confidence" "90"

# =============================================================================
# Unreadable meta -> halt, confidence 0, bump null
# =============================================================================
run_mapper --meta "$FIX/does-not-exist.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "unreadable-meta" light
assert_field "unreadable-meta" ".decision" "halt"
assert_field "unreadable-meta" ".blocking_condition" "7"
assert_field "unreadable-meta" ".confidence" "0"
assert_field "unreadable-meta" ".bump" "null"

# =============================================================================
# Unreadable card1 -> halt, confidence 0, bump null
# =============================================================================
run_mapper --meta "$FIX/meta-7ac-verified.json" --card1 "$FIX/does-not-exist.json" --tier light
full_check "unreadable-card1" light
assert_field "unreadable-card1" ".decision" "halt"
assert_field "unreadable-card1" ".blocking_condition" "7"
assert_field "unreadable-card1" ".confidence" "0"
assert_field "unreadable-card1" ".bump" "null"

# =============================================================================
# Extra: duplicate verdicts per AC -> worst verdict, lowest confidence
# =============================================================================
# (a) worst-among-duplicates is still passing (PARTIALLY_VERIFIED) -> agree,
#     but confidence uses the LOWEST of the duplicates (85, not 95).
run_mapper --meta "$FIX/meta-duplicate-ok.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "duplicate-ok" light
assert_field "duplicate-ok" ".decision" "merge"
assert_field "duplicate-ok" ".confidence" "85"

# (b) worst-among-duplicates is CONTRADICTED -> failed AC, halt, even though
#     one of the duplicates was VERIFIED at 95.
run_mapper --meta "$FIX/meta-duplicate-fail.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "duplicate-fail" light
assert_field "duplicate-fail" ".decision" "halt"
assert_field "duplicate-fail" ".confidence" "0"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"A=CONTRADICTED"*) pass "duplicate-fail: worst verdict (CONTRADICTED) wins over a duplicate VERIFIED" ;;
  *) fail "duplicate-fail: rationale missing A=CONTRADICTED: $G_OUT" ;;
esac

# =============================================================================
# Extra: untagged verdict is ignored entirely (no [AC-<id>] prefix match)
# =============================================================================
run_mapper --meta "$FIX/meta-untagged-ignored.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "untagged-ignored" light
assert_field "untagged-ignored" ".decision" "merge"
assert_field "untagged-ignored" ".confidence" "90"

# =============================================================================
# Extra: verdict outside the taxonomy -> that AC is unaudited
# =============================================================================
run_mapper --meta "$FIX/meta-taxonomy-invalid.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "taxonomy-invalid" light
assert_field "taxonomy-invalid" ".decision" "halt"
assert_field "taxonomy-invalid" ".confidence" "0"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"A"*) pass "taxonomy-invalid: rationale names AC A as unaudited" ;;
  *) fail "taxonomy-invalid: rationale missing A: $G_OUT" ;;
esac

# =============================================================================
# Extra: non-M14 sidecar (no ac_claims key at all) -> halt, 0
# =============================================================================
run_mapper --meta "$FIX/meta-nonm14.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "nonm14-sidecar" light
assert_field "nonm14-sidecar" ".decision" "halt"
assert_field "nonm14-sidecar" ".confidence" "0"

# =============================================================================
# Extra: struck-only AC (zero unstruck verdicts at all) -> unaudited -> halt
# =============================================================================
run_mapper --meta "$FIX/meta-struck-only.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "struck-only" light
assert_field "struck-only" ".decision" "halt"
assert_field "struck-only" ".confidence" "0"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"S"*) pass "struck-only: rationale names AC S as unaudited" ;;
  *) fail "struck-only: rationale missing S: $G_OUT" ;;
esac

# =============================================================================
# Extra: float confidence is floored to an integer (CDT-181)
# =============================================================================
run_mapper --meta "$FIX/meta-float-confidence.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "float-confidence" light
assert_field "float-confidence" ".decision" "merge"
assert_field "float-confidence" ".confidence" "84"
CONF_TYPE=$(printf '%s' "$G_OUT" | jq -r '.confidence | type')
[ "$CONF_TYPE" = "number" ] && printf '%s' "$G_OUT" | jq -e '.confidence == (.confidence|floor)' >/dev/null 2>&1 \
  && pass "float-confidence: output confidence is an integer" \
  || fail "float-confidence: output confidence is not an integer: $G_OUT"

# =============================================================================
# Extra: boundary — confidence exactly 80 -> agree (not halt)
# =============================================================================
run_mapper --meta "$FIX/meta-boundary-80.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "boundary-80" light
assert_field "boundary-80" ".decision" "merge"
assert_field "boundary-80" ".blocking_condition" "null"
assert_field "boundary-80" ".confidence" "80"

# =============================================================================
# Extra: mixed unaudited + failed -> unaudited wins (M14(b) step order),
# rationale names only the unaudited AC, never the failed one.
# =============================================================================
run_mapper --meta "$FIX/meta-mixed-unaudited-and-failed.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "mixed-unaudited-and-failed" light
assert_field "mixed-unaudited-and-failed" ".decision" "halt"
RATIONALE=$(printf '%s' "$G_OUT" | jq -r '.rationale')
case "$RATIONALE" in
  *"unaudited"*"A"*)
    case "$RATIONALE" in
      *CONTRADICTED*) fail "mixed: rationale must not name the failed AC once unaudited wins: $RATIONALE" ;;
      *) pass "mixed: unaudited AC A takes precedence over failed AC B (step order)" ;;
    esac
    ;;
  *) fail "mixed: rationale missing unaudited AC A: $RATIONALE" ;;
esac

# =============================================================================
# Tech-lead review round 1 (B4a/B4b/B4c/N1): the mapper must fail closed on
# malformed input, never crash with a bare jq exit and no JSON.
# =============================================================================

# B4a — process_acs present but not a JSON array -> halt, 0 (never a jq crash).
run_mapper --meta "$FIX/meta-processacs-not-array.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "B4a process_acs-not-array" light
assert_field "B4a process_acs-not-array" ".decision" "halt"
assert_field "B4a process_acs-not-array" ".blocking_condition" "7"
assert_field "B4a process_acs-not-array" ".confidence" "0"

# B4a — an ac_claims[] entry without ac_id -> halt, 0 (never a jq crash).
run_mapper --meta "$FIX/meta-acclaims-missing-acid.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "B4a ac_claims-missing-ac_id" light
assert_field "B4a ac_claims-missing-ac_id" ".decision" "halt"
assert_field "B4a ac_claims-missing-ac_id" ".blocking_condition" "7"
assert_field "B4a ac_claims-missing-ac_id" ".confidence" "0"

# B4b — agree path requires card #1's decision in {pr, merge}.
run_mapper --meta "$FIX/meta-7ac-verified.json" --card1 "$FIX/card1-decision-halt.json" --tier light
full_check "B4b card1-decision-halt" light
assert_field "B4b card1-decision-halt" ".decision" "halt"
assert_field "B4b card1-decision-halt" ".blocking_condition" "7"
assert_field "B4b card1-decision-halt" ".confidence" "0"

run_mapper --meta "$FIX/meta-7ac-verified.json" --card1 "$FIX/card1-decision-missing.json" --tier light
full_check "B4b card1-decision-missing" light
assert_field "B4b card1-decision-missing" ".decision" "halt"
assert_field "B4b card1-decision-missing" ".blocking_condition" "7"
assert_field "B4b card1-decision-missing" ".confidence" "0"

# B4c — an unknown verification_mode value MUST NOT be treated as "full".
run_mapper --meta "$FIX/meta-vmode-unknown.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "B4c vmode-unknown" light
assert_field "B4c vmode-unknown" ".decision" "halt"
assert_field "B4c vmode-unknown" ".blocking_condition" "7"
assert_field "B4c vmode-unknown" ".confidence" "0"

# B-1 (review round 2) — an absent, null or false verification_mode MUST NOT
# be defaulted to "full" by `// "full"` (fail-open); each halts, BC7,
# confidence 0, same as an unknown string.
run_mapper --meta "$FIX/meta-vmode-absent.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "B-1 vmode-absent" light
assert_field "B-1 vmode-absent" ".decision" "halt"
assert_field "B-1 vmode-absent" ".blocking_condition" "7"
assert_field "B-1 vmode-absent" ".confidence" "0"

run_mapper --meta "$FIX/meta-vmode-null.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "B-1 vmode-null" light
assert_field "B-1 vmode-null" ".decision" "halt"
assert_field "B-1 vmode-null" ".blocking_condition" "7"
assert_field "B-1 vmode-null" ".confidence" "0"

run_mapper --meta "$FIX/meta-vmode-false.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "B-1 vmode-false" light
assert_field "B-1 vmode-false" ".decision" "halt"
assert_field "B-1 vmode-false" ".blocking_condition" "7"
assert_field "B-1 vmode-false" ".confidence" "0"

# N1 — a confidence outside [0,100] must never pass through: that AC becomes
# unaudited (dropped before matching), halt at confidence 0.
run_mapper --meta "$FIX/meta-confidence-over100.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "N1 confidence-150" light
assert_field "N1 confidence-150" ".decision" "halt"
assert_field "N1 confidence-150" ".blocking_condition" "7"
assert_field "N1 confidence-150" ".confidence" "0"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"unaudited AC(s): Z"*) pass "N1 confidence-150: AC Z is unaudited, not silently accepted at 150" ;;
  *) fail "N1 confidence-150: rationale missing unaudited AC Z: $G_OUT" ;;
esac

run_mapper --meta "$FIX/meta-confidence-negative.json" --card1 "$FIX/card1-merge-patch.json" --tier light
full_check "N1 confidence-negative" light
assert_field "N1 confidence-negative" ".decision" "halt"
assert_field "N1 confidence-negative" ".blocking_condition" "7"
assert_field "N1 confidence-negative" ".confidence" "0"
case "$(printf '%s' "$G_OUT" | jq -r '.rationale')" in
  *"unaudited AC(s): Z"*) pass "N1 confidence-negative: AC Z is unaudited, not silently accepted at -5" ;;
  *) fail "N1 confidence-negative: rationale missing unaudited AC Z: $G_OUT" ;;
esac

# =============================================================================
# Argv misuse -> exit 64, never a computed JSON outcome
# =============================================================================
expect_argv_misuse() {
  local desc="$1"; shift
  local rc=0
  bash "$MAPPER" "$@" >/dev/null 2>/dev/null || rc=$?
  if [ "$rc" -eq 64 ]; then pass "argv-misuse: $desc"; else fail "argv-misuse: $desc rc=$rc (want 64)"; fi
}

expect_argv_misuse "missing --card1" --meta "$FIX/meta-7ac-verified.json" --tier light
expect_argv_misuse "missing --tier" --meta "$FIX/meta-7ac-verified.json" --card1 "$FIX/card1-merge-patch.json"
expect_argv_misuse "bad --tier value" --meta "$FIX/meta-7ac-verified.json" --card1 "$FIX/card1-merge-patch.json" --tier medium
expect_argv_misuse "both --meta and --no-report" --meta "$FIX/meta-7ac-verified.json" --no-report "x" --card1 "$FIX/card1-merge-patch.json" --tier light
expect_argv_misuse "neither --meta nor --no-report" --card1 "$FIX/card1-merge-patch.json" --tier light
expect_argv_misuse "unknown flag" --meta "$FIX/meta-7ac-verified.json" --card1 "$FIX/card1-merge-patch.json" --tier light --bogus
expect_argv_misuse "dangling --meta with no value" --card1 "$FIX/card1-merge-patch.json" --tier light --meta
expect_argv_misuse "duplicate --tier" --meta "$FIX/meta-7ac-verified.json" --card1 "$FIX/card1-merge-patch.json" --tier light --tier full
expect_argv_misuse "empty --no-report cause" --no-report "" --card1 "$FIX/card1-merge-patch.json" --tier light

# =============================================================================
echo
echo "ship-gate-verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
exit $?
