#!/usr/bin/env bash
#
# skills/autopilot/test-contract-prose.sh — SPEC-033 wp-1-08-autopilot-state
# AC C (contract prose: M10.1, card #2 actor discriminator, ship-gate-council.md
# §2a run_id).
#
# Static text asserts only. Starts no live council. Writes only under a
# private TMPDIR (mutated temp copies, for the bite tests).
#
# c1 — SPEC-033 Version History has a dated WP 1-08 row.
# c2 — Outside its `## Acceptance criteria` section, SPEC-033 does not
#      contain "Evaluated at `scope-confirm` and `plan-approve`", and
#      neither does skills/autopilot/SKILL.md; both files contain
#      "Evaluated at `scope-confirm` only".
# c3 — The F4-n-tight plan-approve row in the self-answer gate fixture
#      (fixtures/self-answer-scenarios.json, successor of the retired
#      self-answer-scenarios.md prose) still expects a BC4 halt at
#      plan-approve.
# c4 — ship-gate-council.md §2a gives the fresh (card #1 unreadable) halt
#      card the run_id `orchestrate-<ISSUE-ID>-<RUN_START_EPOCH>`.
# c5 — ship-gate-council.md §6 requires `actor` `ship-gate-council` on
#      card #2.
# c6 — ship-gate-council.md §5 is byte-equal to a committed golden
#      extracted from 38bc739 (through tests/lib/fence.sh md_section).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$ROOT/tests/lib/hermetic.sh"
source "$ROOT/tests/lib/text.sh"
source "$ROOT/tests/lib/fence.sh"

SPEC="$ROOT/specs/core/SPEC-033-autopilot-policy.md"
SKILL="$SCRIPT_DIR/SKILL.md"
SG="$SCRIPT_DIR/ship-gate-council.md"
SCEN="$SCRIPT_DIR/fixtures/self-answer-scenarios.json"
GOLDEN_S5="$SCRIPT_DIR/fixtures/contract-prose/sgc-s5-38bc739.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

hermetic_init

TMP=$(mktemp -d "${TMPDIR:-/tmp}/contract-prose-test.XXXXXX")
cleanup() { rm -rf "$TMP"; hermetic_cleanup; }
trap cleanup EXIT

for f in "$SPEC" "$SKILL" "$SG" "$SCEN" "$GOLDEN_S5"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: fixture/source file missing: $f" >&2
    exit 1
  fi
done

# extract_ac_section <spec-file> -- the "## Acceptance criteria" section
# body, up to (not including) the next "## " heading. A complement
# operation, a different shape from md_section (tests/lib/fence.sh); stays
# local (single consumer).
extract_outside_ac() {
  awk '
    /^## Acceptance criteria/ { grab = 1 }
    grab && /^## / && !/^## Acceptance criteria/ { grab = 0 }
    !grab { print }
  ' "$1"
}

# extract_wp108_row <spec-file> -- the Version History row line for WP 1-08
# (single consumer; table-row extraction is a different shape from
# md_section's heading-section extraction).
extract_wp108_row() {
  grep -F -- 'WP 1-08 (`wp-1-08-autopilot-state`' "$1"
}

# f4ntight_row <fixture.json> -- the F4-n-tight plan-approve card row
# (single consumer; row extraction is jq, not a line grep — 05 E5).
f4ntight_row() {
  jq -c '[.fixtures[] | select(.id=="F4-n-tight" and .card[2]=="plan-approve")][0]' "$1" 2>/dev/null
}

extract_sgc_2a() { md_section "$1" "### 2a. Process-stamp pre-flight"; }
extract_sgc_6() { md_section "$1" "## 6. Card-append sequencing"; }
extract_sgc_5() { md_section "$1" "## 5."; }

# =============================================================================
# c1 -- SPEC-033 Version History has a dated WP 1-08 row.
# =============================================================================
WP108_STR='WP 1-08 (`wp-1-08-autopilot-state`'
ROW=$(extract_wp108_row "$SPEC")
if [ -z "$ROW" ]; then
  fail "c1 SPEC-033 Version History missing the WP 1-08 row"
elif printf '%s\n' "$ROW" | grep -E -q '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|'; then
  pass "c1 SPEC-033 Version History has a dated WP 1-08 row"
else
  fail "c1 SPEC-033 WP 1-08 row is present but not dated"
fi
remove_line_substr "$SPEC" "$TMP/c1-mut.md" "$WP108_STR"
if has "$TMP/c1-mut.md" "$WP108_STR"; then
  fail "c1-bite mutated SPEC-033 still had the WP 1-08 row"
else
  pass "c1-bite mutated SPEC-033 no longer has the WP 1-08 row -> check would fail"
fi
# c1-bite2: strip just the date cell off the (otherwise intact) row, so the
# row-presence check above would still pass, and confirm the date-anchored
# regex is what actually catches it.
sed 's/^| 2026-09-28 | WP 1-08 (`wp-1-08-autopilot-state`/| WP 1-08 (`wp-1-08-autopilot-state`/' \
  "$SPEC" > "$TMP/c1-datemut.md"
ROW_DATEMUT=$(extract_wp108_row "$TMP/c1-datemut.md")
if [ -n "$ROW_DATEMUT" ] && printf '%s\n' "$ROW_DATEMUT" | grep -E -q '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|'; then
  fail "c1-bite2 date-stripped row still matched the dated-row regex"
else
  pass "c1-bite2 date-stripped row no longer matches the dated-row regex -> check would fail"
fi

# =============================================================================
# c2 -- M10.1: outside "## Acceptance criteria", SPEC-033 does not contain
# "Evaluated at `scope-confirm` and `plan-approve`", and neither does
# SKILL.md; both files contain "Evaluated at `scope-confirm` only".
# =============================================================================
BAD='Evaluated at `scope-confirm` and `plan-approve`'
GOOD='Evaluated at `scope-confirm` only'

OUTSIDE_AC=$(extract_outside_ac "$SPEC")
if printf '%s\n' "$OUTSIDE_AC" | grep -F -q -- "$BAD"; then
  fail "c2 SPEC-033 (outside AC section) still contains the dual-gate M10.1 phrase"
else
  pass "c2 SPEC-033 (outside AC section) does not contain the dual-gate M10.1 phrase"
fi

if has "$SPEC" "$GOOD" && has "$SKILL" "$GOOD"; then
  pass "c2 SPEC-033 and SKILL.md both contain the scope-confirm-only M10.1 phrase"
else
  fail "c2 scope-confirm-only M10.1 phrase missing from SPEC-033 and/or SKILL.md"
fi

# c2-nonvacuous: confirm extract_outside_ac's positive side is actually
# non-empty (it must carry the GOOD phrase from AC4/M10, not just skip past
# it) -- otherwise the "does not contain BAD" check above could pass on an
# empty extraction.
if printf '%s\n' "$OUTSIDE_AC" | grep -F -q -- "$GOOD"; then
  pass "c2-nonvacuous extract_outside_ac carries the scope-confirm-only phrase (AC4/M10) -- not an empty extraction"
else
  fail "c2-nonvacuous extract_outside_ac does not carry the scope-confirm-only phrase -- the BAD-absence check above would be vacuous"
fi

# c2-bite: SKILL.md loses the scope-confirm-only phrase.
remove_line_substr "$SKILL" "$TMP/c2-mut.md" "$GOOD"
if has "$TMP/c2-mut.md" "$GOOD"; then
  fail "c2-bite mutated SKILL.md still had the scope-confirm-only phrase"
else
  pass "c2-bite mutated SKILL.md no longer has the phrase -> check would fail"
fi

# c2-bite2: planted negative control -- a temp copy of SPEC-033 with the
# GOOD phrase (which lives outside the AC section, at AC4/M10) replaced by
# BAD; extract_outside_ac of that copy MUST now surface BAD, proving the
# extractor (not just grep on the raw file) would actually catch a
# regression placed outside the AC section.
sed 's/Evaluated at `scope-confirm` only/Evaluated at `scope-confirm` and `plan-approve`/' \
  "$SPEC" > "$TMP/c2-spec-mut.md"
OUTSIDE_AC_MUT=$(extract_outside_ac "$TMP/c2-spec-mut.md")
if printf '%s\n' "$OUTSIDE_AC_MUT" | grep -F -q -- "$BAD"; then
  pass "c2-bite2 planted BAD outside the AC section is caught by extract_outside_ac -> check would fail"
else
  fail "c2-bite2 planted BAD outside the AC section was NOT caught by extract_outside_ac"
fi

# =============================================================================
# c3 -- the F4-n-tight plan-approve fixture row still expects a BC4 halt.
# =============================================================================
TIGHT_DEC="halt"
TIGHT_BC="4"
ROW_F4=$(f4ntight_row "$SCEN")
if [ -z "$ROW_F4" ] || [ "$ROW_F4" = "null" ]; then
  fail "c3 fixture has no F4-n-tight plan-approve row"
elif [ "$(jq -r '.expect.decision' <<<"$ROW_F4")" = "$TIGHT_DEC" ] \
  && [ "$(jq -r '.expect.bc' <<<"$ROW_F4")" = "$TIGHT_BC" ]; then
  pass "c3 fixture F4-n-tight plan-approve row still expects a BC4 halt"
else
  fail "c3 fixture F4-n-tight plan-approve row expects decision=$(jq -r '.expect.decision' <<<"$ROW_F4") bc=$(jq -r '.expect.bc' <<<"$ROW_F4") (want halt/4)"
fi
# c3-bite: flip the row's bc to 5; the row-scoped check must fail.
jq '(.fixtures[] | select(.id=="F4-n-tight" and .card[2]=="plan-approve") | .expect.bc) = "5"' \
  "$SCEN" > "$TMP/c3-mut.json" 2>/dev/null
ROW_F4_MUT=$(f4ntight_row "$TMP/c3-mut.json")
if [ -n "$ROW_F4_MUT" ] && [ "$ROW_F4_MUT" != "null" ] \
  && [ "$(jq -r '.expect.decision' <<<"$ROW_F4_MUT")" = "$TIGHT_DEC" ] \
  && [ "$(jq -r '.expect.bc' <<<"$ROW_F4_MUT")" = "$TIGHT_BC" ]; then
  fail "c3-bite mutated F4-n-tight row still expects a BC4 halt"
else
  pass "c3-bite mutated F4-n-tight row no longer expects a BC4 halt -> check would fail"
fi

# c3-bite2: planted negative control -- the halt/BC4 expectation moved to an
# UNRELATED row (F4-gen) while the F4-n-tight plan-approve row loses it. A
# file-wide "some row halts BC4" check would PASS (the expectation still
# exists somewhere); the row-scoped check MUST fail, proving c3 actually
# reads the F4-n-tight plan-approve row.
jq '(.fixtures[] | select(.id=="F4-gen") | .expect) = {"exit":0,"decision":"halt","bc":"4"}
    | (.fixtures[] | select(.id=="F4-n-tight" and .card[2]=="plan-approve") | .expect) = {"exit":0,"decision":"approve","bc":"null"}' \
  "$SCEN" > "$TMP/c3-moved.json" 2>/dev/null
ROW_F4_MOVED=$(f4ntight_row "$TMP/c3-moved.json")
if [ -n "$ROW_F4_MOVED" ] && [ "$ROW_F4_MOVED" != "null" ] \
  && [ "$(jq -r '.expect.decision' <<<"$ROW_F4_MOVED")" = "$TIGHT_DEC" ] \
  && [ "$(jq -r '.expect.bc' <<<"$ROW_F4_MOVED")" = "$TIGHT_BC" ]; then
  fail "c3-bite2 row-scoped check still matched after the expectation moved off the F4-n-tight row -- c3 is not actually row-scoped"
else
  pass "c3-bite2 row-scoped check correctly fails when a BC4 halt exists on another row but not on F4-n-tight -> proves row scoping"
fi

# =============================================================================
# c4 -- ship-gate-council.md §2a: fresh halt card run_id formula.
# =============================================================================
RUNID_STR='`run_id` = `orchestrate-<ISSUE-ID>-<RUN_START_EPOCH>`'
BLOCK_2A=$(extract_sgc_2a "$SG")
if [ -z "$BLOCK_2A" ]; then
  fail "c4 could not extract ship-gate-council.md §2a"
elif printf '%s\n' "$BLOCK_2A" | grep -F -q -- "$RUNID_STR"; then
  pass "c4 ship-gate-council.md §2a gives the fresh halt card the ISSUE-ID/RUN_START_EPOCH run_id"
else
  fail "c4 ship-gate-council.md §2a missing the fresh halt card run_id formula"
fi
remove_line_substr "$SG" "$TMP/c4-mut.md" "$RUNID_STR"
MUT_2A=$(extract_sgc_2a "$TMP/c4-mut.md")
if printf '%s\n' "$MUT_2A" | grep -F -q -- "$RUNID_STR"; then
  fail "c4-bite mutated §2a still had the run_id formula"
else
  pass "c4-bite mutated §2a no longer has the run_id formula -> check would fail"
fi

# =============================================================================
# c5 -- ship-gate-council.md §6: card #2 actor literal ship-gate-council.
# =============================================================================
ACTOR_STR='`actor` = the literal'
ACTOR_LIT="\`ship-gate-council\` (M13's actor discriminator"
BLOCK_6=$(extract_sgc_6 "$SG")
if [ -z "$BLOCK_6" ]; then
  fail "c5 could not extract ship-gate-council.md §6"
elif printf '%s\n' "$BLOCK_6" | grep -F -q -- "$ACTOR_STR" \
  && printf '%s\n' "$BLOCK_6" | grep -F -q -- "$ACTOR_LIT"; then
  pass "c5 ship-gate-council.md §6 requires actor ship-gate-council on card #2"
else
  fail "c5 ship-gate-council.md §6 missing the card #2 actor literal requirement"
fi
remove_line_substr "$SG" "$TMP/c5-mut.md" "$ACTOR_LIT"
MUT_6=$(extract_sgc_6 "$TMP/c5-mut.md")
if printf '%s\n' "$MUT_6" | grep -F -q -- "$ACTOR_LIT"; then
  fail "c5-bite mutated §6 still had the actor literal"
else
  pass "c5-bite mutated §6 no longer has the actor literal -> check would fail"
fi

# =============================================================================
# c6 -- ship-gate-council.md §5 byte-equal to the committed golden
# (extracted from 38bc739, through the same md_section helper).
# =============================================================================
extract_sgc_5 "$SG" > "$TMP/sgc-s5-live.md"
if [ ! -s "$TMP/sgc-s5-live.md" ]; then
  fail "c6 could not extract ship-gate-council.md §5"
elif diff "$TMP/sgc-s5-live.md" "$GOLDEN_S5" >/dev/null 2>&1; then
  pass "c6 ship-gate-council.md §5 byte-equal to committed golden (base 38bc739)"
else
  fail "c6 ship-gate-council.md §5 differs from the committed golden"
fi
remove_line_substr "$SG" "$TMP/c6-mut.md" "re-derive the SPEC-013 spawn-failure"
extract_sgc_5 "$TMP/c6-mut.md" > "$TMP/sgc-s5-mut.md"
if diff "$TMP/sgc-s5-mut.md" "$GOLDEN_S5" >/dev/null 2>&1; then
  fail "c6-bite mutated §5 still matched the golden"
else
  pass "c6-bite mutated §5 diverges from golden -> byte-compare would fail"
fi

# c6-heading -- AC C requires the byte-equal comparison to cover the §5
# heading text itself (md_section excludes it from the body comparison
# above). Assert the live heading line, exact and whole-line
# (grep -qxF), matches the golden's original heading at 38bc739.
if grep -qxF '## 5. Degraded-run rule' "$SG"; then
  pass "c6-heading ship-gate-council.md §5 heading is byte-equal to 38bc739 ('## 5. Degraded-run rule')"
else
  fail "c6-heading ship-gate-council.md §5 heading differs from 38bc739"
fi
# c6-heading-bite: rename the heading (keeping the "## 5." prefix, so a
# prefix-only check would still pass) and confirm the whole-line check
# fails.
sed 's/^## 5\. Degraded-run rule$/## 5. Degraded-run rule (renamed)/' \
  "$SG" > "$TMP/c6-heading-mut.md"
if grep -qxF '## 5. Degraded-run rule' "$TMP/c6-heading-mut.md"; then
  fail "c6-heading-bite renamed heading still matched the whole-line check"
else
  pass "c6-heading-bite renamed heading no longer matches -> check would fail"
fi

# =============================================================================
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
