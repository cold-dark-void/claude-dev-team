#!/usr/bin/env bash
#
# skills/autopilot/test-ship-gate-guardrails.sh — SPEC-033 M14(k) static
# guardrail test (WP 1-14 T9).
#
# Static text asserts only. Starts no live council. Writes only under a
# private TMPDIR (mutated copies of the real docs, for the bite tests).
#
# Covers SPEC-033 AC B (the 5 M14 guardrails), asserted in BOTH
# specs/core/SPEC-033-autopilot-policy.md and skills/autopilot/ship-gate-council.md:
#   g1 — M14 fires once per attempt, with exactly two cards.
#   g2 — BC7 is reused; no ninth BC is added.
#   g3 — no auto-clear, no self-answer past BC7, no auto re-run.
#   g4 — the M14(d) degraded rule is unchanged (byte-compared to a committed
#        golden extracted from base 1898468, plus the two ship-gate-council.md
#        §5 phrases it must keep).
#        g4-bite locates the mutation by the same (d)..(e) markers
#        extract_m14d uses, not a fixed line number; g4-bite2 re-proves that
#        after one line is inserted above the block (AC K).
#   g5 — `--council-tier` is the sole flag.
#   g6 — `ship-gate-verdict.sh` is byte-identical to `cbee656` (blob-hash
#        fixture; WP 1-15 AC G).
#   g7 — the SPEC-033 M14(b) block, extracted by its `(b)`..`(c)` markers, is
#        byte-equal to a committed golden extracted from `cbee656` (WP 1-15
#        AC G). The M14(d) golden (g4) is unchanged.
#
# WP 1-16 AC F (SPEC-033 M14(g) finder recipe): g8-g10, a6-a7.
#   g8 — `append-card.sh` is byte-identical to its WP 1-08 version (`assert_blob_hash`,
#        shared with g6).
#   g9 — `ship-gate-council.md` §5, extracted by its `## 5.`/`## 6.` markers,
#        is byte-equal to a committed golden extracted from `38bc739`.
#   g10 — `skills/council/engine.sh` holds `M14_VERIFY_TOOL_BUDGET=8` and
#        `INVESTIGATOR_TOOL_BUDGET=5`.
#   a6 — SPEC-033 has a dated 2026-09-28 WP 1-16 row naming M14(g), M14(j),
#        the no-elision rule and the judge caps ("can only lower a
#        confidence"); SPEC-013 has a dated 2026-09-28 WP 1-16 row.
#   a7 — ship-gate-council.md §3b names "finder recipe" and M14(g), and does
#        not hold "RECIPE STEP" (no restatement of the recipe's own steps).
#
# Also covers AC A (a1-a5): SPEC-033 Version History names the review report;
# ship-gate-council.md line 7/8 names the mapper and "not a render helper";
# it cites M14(b)/(i) and does not restate M14(b)'s worst-order string or
# "lowest confidence".
# a5 (WP 1-15 AC A/G): SPEC-033 names WP 1-15, M14(a) and M14(g) in a dated
# row; ship-gate-council.md cites M14(g) with no grammar restatement, no
# metacharacter list, and no `run-all-tests.sh` mention.
#
# Also covers the M14(g) Writers (w1-w4): 06-design.md, 04-kickoff.md,
# 10-qa.md, kickoff/SKILL.md each cite M14(g) and `## Acceptance criteria`.
# w5-w7 (WP 1-15 AC L): 04-kickoff.md and 06-design.md ask writers for a
# per-AC `Verify:` continuation; 10-qa.md reports `verify: null` ACs and
# Verify files that do not call `hermetic_init`.
#
# Every check also runs a bite test: the same check against a mutated temp
# copy of the file it reads, asserting the check FAILS on the mutation.
#
# Machine-check: bash skills/autopilot/test-ship-gate-guardrails.sh (exit 0, all PASS)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$ROOT/tests/lib/skip.sh"
source "$ROOT/tests/lib/hermetic.sh"
source "$ROOT/tests/lib/text.sh"

SPEC="$ROOT/specs/core/SPEC-033-autopilot-policy.md"
SG="$SCRIPT_DIR/ship-gate-council.md"
GOLDEN="$SCRIPT_DIR/fixtures/ship-gate-guardrails/m14d.golden.md"
GOLDEN_M14B="$SCRIPT_DIR/fixtures/ship-gate-guardrails/m14b.golden.md"
VERDICT_SH="$SCRIPT_DIR/ship-gate-verdict.sh"
VERDICT_BLOB="$SCRIPT_DIR/fixtures/ship-gate-guardrails/ship-gate-verdict.blob"
APPEND_CARD_SH="$SCRIPT_DIR/append-card.sh"
APPEND_CARD_BLOB="$SCRIPT_DIR/fixtures/ship-gate-guardrails/append-card.blob"
GOLDEN_SGC_S5="$SCRIPT_DIR/fixtures/ship-gate-guardrails/sgc-s5.golden.md"
ENGINE_SH="$ROOT/skills/council/engine.sh"
SPEC013="$ROOT/specs/core/SPEC-013-adversarial-council-tribunal.md"
W1="$ROOT/skills/orchestrate/steps/06-design.md"
W2="$ROOT/skills/orchestrate/steps/04-kickoff.md"
W3="$ROOT/skills/orchestrate/steps/10-qa.md"
W4="$ROOT/skills/kickoff/SKILL.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

hermetic_init

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ship-gate-guardrails-test.XXXXXX")
cleanup() { rm -rf "$TMP"; hermetic_cleanup; }
trap cleanup EXIT

for f in "$SPEC" "$SG" "$GOLDEN" "$GOLDEN_M14B" "$VERDICT_SH" "$VERDICT_BLOB" "$APPEND_CARD_SH" "$APPEND_CARD_BLOB" "$GOLDEN_SGC_S5" "$ENGINE_SH" "$SPEC013" "$W1" "$W2" "$W3" "$W4"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: fixture/source file missing: $f" >&2
    exit 1
  fi
done


# remove_all_substr <src> <dst> <substring>
# Removes EVERY occurrence of a literal substring across the whole file
# (used for bite tests where the target phrase repeats).
remove_all_substr() {
  local src=$1 dst=$2 s=$3
  awk -v s="$s" '
    {
      line = $0
      out = ""
      while ((i = index(line, s)) > 0) {
        out = out substr(line, 1, i - 1)
        line = substr(line, i + length(s))
      }
      print out line
    }
  ' "$src" > "$dst"
}

# extract_m14d <spec-file>  -- the M14(d) block, (d) line up to (not
# including) the (e) line. Command substitution strips the trailing blank
# line the awk print emits for the blank line just before (e).
extract_m14d() {
  awk '
    /^  - \*\*\(d\) Degraded-run rule/ { grab = 1 }
    grab && /^  - \*\*\(e\)/ { exit }
    grab { print }
  ' "$1"
}

# extract_m14b <spec-file>  -- the M14(b) block, (b) line up to (not
# including) the (c) line (WP 1-15 AC G). Same marker-located, no-fixed-
# line-number style as extract_m14d.
extract_m14b() {
  awk '
    /^  - \*\*\(b\) Per-AC aggregation/ { grab = 1 }
    grab && /^  - \*\*\(c\)/ { exit }
    grab { print }
  ' "$1"
}

# find_m14d_self_verified_line <spec-file>  -- the line number, within
# <spec-file>, of the first line inside the (d)..(e) range (the same
# markers extract_m14d uses) that holds "self-verified". Empty if none.
# No fixed line number: it still works after lines are inserted above the
# block (AC K).
find_m14d_self_verified_line() {
  awk '
    /^  - \*\*\(d\) Degraded-run rule/ { grab = 1 }
    grab && /^  - \*\*\(e\)/ { exit }
    grab && /self-verified/ { print NR; exit }
  ' "$1"
}

# mutate_m14d_self_verified <src> <dst>  -- writes <src> to <dst>, with the
# word at the marker-located self-verified line (find_m14d_self_verified_line)
# altered. A no-op copy if the marker line is not found, so the caller's
# byte-compare still runs (and fails on a missing block, rather than a
# silently-unmutated one).
mutate_m14d_self_verified() {
  local src=$1 dst=$2 ln
  ln=$(find_m14d_self_verified_line "$src") || ln=""
  if [ -z "$ln" ]; then
    cp -- "$src" "$dst" || return 1
    return 0
  fi
  sed -e "${ln}s/self-verified/altered-verified/" "$src" > "$dst" || return 1
}


# assert_blob_hash <file> <blob-fixture> <label> — hashes <file> with
# `git hash-object` and compares it to the committed blob-hash text in
# <blob-fixture>. Also runs the bite test: hashes a copy of <file> with one
# appended byte and confirms that mutated hash diverges from the fixture.
# pass()/fail() as with every other check in this suite. Shared by g6
# (ship-gate-verdict.sh) and g8 (append-card.sh) — WP 1-16 T3 extract,
# replacing two near-identical inline blocks (TL review M6).
assert_blob_hash() {
  local file=$1 blob_fixture=$2 label=$3
  local hash fixture_hash mutfile mut_hash
  hash=$(git -C "$ROOT" hash-object "$file" 2>/dev/null) || hash=""
  fixture_hash=$(cat "$blob_fixture")
  if [ -n "$hash" ] && [ "$hash" = "$fixture_hash" ]; then
    pass "$label byte-identical (blob $fixture_hash)"
  else
    fail "$label hash $hash does not match blob $fixture_hash"
  fi

  mutfile=$(mktemp "$TMP/assert-blob-hash-mut.XXXXXX") || { fail "$label-bite could not create a mutation tempfile"; return 1; }
  cp -- "$file" "$mutfile" || { fail "$label-bite could not copy $file"; return 1; }
  printf '# %s-bite mutation\n' "$label" >> "$mutfile" || fail "$label-bite could not append the mutation byte"
  mut_hash=$(git -C "$ROOT" hash-object "$mutfile" 2>/dev/null) || mut_hash=""
  if [ "$mut_hash" = "$fixture_hash" ]; then
    fail "$label-bite mutated copy still matched the blob fixture"
  else
    pass "$label-bite mutated copy diverges from blob fixture -> check would fail"
  fi
}

# extract_sgc_s5 <ship-gate-council.md path> -- the §5 block, from the
# "## 5." heading line up to (not including) the "## 6." heading line.
extract_sgc_s5() {
  awk '
    /^## 5\./ { grab = 1 }
    grab && /^## 6\./ { exit }
    grab { print }
  ' "$1"
}

# extract_sgc_3b <ship-gate-council.md path> -- the §3b block ("### 3b."
# heading up to, not including, the next "## " top-level heading).
extract_sgc_3b() {
  awk '
    /^### 3b\./ { grab = 1 }
    grab && /^## / { exit }
    grab { print }
  ' "$1"
}

# =============================================================================
# g1 — M14 fires once per attempt, with exactly two cards.
# =============================================================================
G1_SPEC_A="MUST run **exactly one** adversarial council pass"
G1_SPEC_B="**exactly once** per ship-choice attempt"
G1_SPEC_C="attempt therefore records **exactly two**"
G1_SG_A="It fires **exactly once** per ship-choice attempt"
G1_SG_B="reaches the firing condition records **exactly two**"

if has "$SPEC" "$G1_SPEC_A" && has "$SPEC" "$G1_SPEC_B" && has "$SPEC" "$G1_SPEC_C"; then
  pass "g1 SPEC-033: fires once, exactly two cards"
else
  fail "g1 SPEC-033: fires once, exactly two cards — phrase missing"
fi
remove_line_substr "$SPEC" "$TMP/g1-spec-mut.md" "$G1_SPEC_A"
if has "$TMP/g1-spec-mut.md" "$G1_SPEC_A"; then
  fail "g1-bite SPEC-033 mutation did not remove the phrase"
else
  pass "g1-bite SPEC-033 mutation removes 'exactly one' phrase -> check would fail"
fi

if has "$SG" "$G1_SG_A" && has "$SG" "$G1_SG_B"; then
  pass "g1 ship-gate-council.md: fires once, exactly two cards"
else
  fail "g1 ship-gate-council.md: fires once, exactly two cards — phrase missing"
fi
remove_line_substr "$SG" "$TMP/g1-sg-mut.md" "$G1_SG_A"
if has "$TMP/g1-sg-mut.md" "$G1_SG_A"; then
  fail "g1-bite ship-gate-council.md mutation did not remove the phrase"
else
  pass "g1-bite ship-gate-council.md mutation removes 'fires exactly once' -> check would fail"
fi

# =============================================================================
# g2 — BC7 is reused; no ninth BC is added.
# =============================================================================
G2_SPEC_A="MUST NOT introduce a 9th blocking"
G2_SPEC_B="The council pass **reuses BC7** with an alternate"
G2_SG_A="This adds **no** ninth blocking condition"
G2_SG_B="this pass **reuses"

if has "$SPEC" "$G2_SPEC_A" && has "$SPEC" "$G2_SPEC_B"; then
  pass "g2 SPEC-033: BC7 reused, no ninth BC"
else
  fail "g2 SPEC-033: BC7 reused, no ninth BC — phrase missing"
fi
remove_line_substr "$SPEC" "$TMP/g2-spec-mut.md" "$G2_SPEC_A"
if has "$TMP/g2-spec-mut.md" "$G2_SPEC_A"; then
  fail "g2-bite SPEC-033 mutation did not remove the phrase"
else
  pass "g2-bite SPEC-033 mutation removes '9th blocking' -> check would fail"
fi

if has "$SG" "$G2_SG_A" && has "$SG" "$G2_SG_B"; then
  pass "g2 ship-gate-council.md: BC7 reused, no ninth BC"
else
  fail "g2 ship-gate-council.md: BC7 reused, no ninth BC — phrase missing"
fi
remove_line_substr "$SG" "$TMP/g2-sg-mut.md" "$G2_SG_A"
if has "$TMP/g2-sg-mut.md" "$G2_SG_A"; then
  fail "g2-bite ship-gate-council.md mutation did not remove the phrase"
else
  pass "g2-bite ship-gate-council.md mutation removes 'no ninth blocking' -> check would fail"
fi

# =============================================================================
# g3 — no auto-clear, no self-answer past BC7, no auto re-run.
# =============================================================================
G3_SPEC_A="self-answer it, auto-re-run the council at \`full\`, or otherwise proceed"
G3_SPEC_B="no auto-clear, no self-answer past BC7 and no auto re-run"
G3_SG_A="autopilot MUST NOT self-answer it, auto-re-run the council at \`full\`, or"
G3_SG_B="never by auto-clearing BC7"

if has "$SPEC" "$G3_SPEC_A" && has "$SPEC" "$G3_SPEC_B"; then
  pass "g3 SPEC-033: no auto-clear / no self-answer past BC7 / no auto re-run"
else
  fail "g3 SPEC-033: no auto-clear / no self-answer past BC7 / no auto re-run — phrase missing"
fi
remove_line_substr "$SPEC" "$TMP/g3-spec-mut.md" "$G3_SPEC_A"
if has "$TMP/g3-spec-mut.md" "$G3_SPEC_A"; then
  fail "g3-bite SPEC-033 mutation did not remove the phrase"
else
  pass "g3-bite SPEC-033 mutation removes 'auto-re-run' clause -> check would fail"
fi

if has "$SG" "$G3_SG_A" && has "$SG" "$G3_SG_B"; then
  pass "g3 ship-gate-council.md: no auto-clear / no self-answer past BC7 / no auto re-run"
else
  fail "g3 ship-gate-council.md: no auto-clear / no self-answer past BC7 / no auto re-run — phrase missing"
fi
remove_line_substr "$SG" "$TMP/g3-sg-mut.md" "$G3_SG_B"
if has "$TMP/g3-sg-mut.md" "$G3_SG_B"; then
  fail "g3-bite ship-gate-council.md mutation did not remove the phrase"
else
  pass "g3-bite ship-gate-council.md mutation removes 'auto-clearing BC7' -> check would fail"
fi

# =============================================================================
# g4 — the M14(d) degraded rule is unchanged.
# =============================================================================
BLOCK=$(extract_m14d "$SPEC")
if [ -z "$BLOCK" ]; then
  fail "g4 could not extract M14(d) block from SPEC-033"
elif diff <(printf '%s\n' "$BLOCK") "$GOLDEN" >/dev/null 2>&1; then
  pass "g4 SPEC-033 M14(d) block byte-equal to committed golden (base 1898468)"
else
  fail "g4 SPEC-033 M14(d) block differs from golden"
fi
# Bite: mutate one word inside the live spec's (d) block, located by the
# (d)..(e) markers (find_m14d_self_verified_line), not a fixed line number.
mutate_m14d_self_verified "$SPEC" "$TMP/g4-spec-mut.md" || fail "g4-bite could not build mutated copy"
MUT_BLOCK=$(extract_m14d "$TMP/g4-spec-mut.md")
if diff <(printf '%s\n' "$MUT_BLOCK") "$GOLDEN" >/dev/null 2>&1; then
  fail "g4-bite mutated M14(d) block still matched the golden"
else
  pass "g4-bite mutated M14(d) block diverges from golden -> byte-compare would fail"
fi

# g4-bite2: insert one line at the top of a copy of the live spec, confirm
# the marker-located extract still finds the (unmutated) block byte-equal to
# the golden, then confirm the same marker-located mutation still diverges.
# Proves the marker location survives a shifted line count (AC K).
{ printf '%s\n' '<!-- g4-bite2: inserted line -->'; cat -- "$SPEC"; } > "$TMP/g4-bite2-base.md" || fail "g4-bite2 could not build inserted-line copy"
BASE_BLOCK2=$(extract_m14d "$TMP/g4-bite2-base.md")
if diff <(printf '%s\n' "$BASE_BLOCK2") "$GOLDEN" >/dev/null 2>&1; then
  pass "g4-bite2 marker-located extract still matches golden after a line is inserted above the block"
else
  fail "g4-bite2 marker-located extract diverges from golden after a line is inserted above the block"
fi
mutate_m14d_self_verified "$TMP/g4-bite2-base.md" "$TMP/g4-bite2-mut.md" || fail "g4-bite2 could not build mutated copy"
MUT_BLOCK2=$(extract_m14d "$TMP/g4-bite2-mut.md")
if diff <(printf '%s\n' "$MUT_BLOCK2") "$GOLDEN" >/dev/null 2>&1; then
  fail "g4-bite2 mutated block (after insertion) still matched the golden"
else
  pass "g4-bite2 mutated block (after insertion) diverges from golden -> byte-compare would fail"
fi

G4_SG_A="regardless of that self-verified run's own reported confidence"
G4_SG_B="\`decision = halt\`, \`blocking_condition = 7\`, \`bump = null\`, \`confidence = 0\` —"
if has "$SG" "$G4_SG_A" && has "$SG" "$G4_SG_B"; then
  pass "g4 ship-gate-council.md §5: keeps 'regardless of ... confidence' + 'confidence = 0'"
else
  fail "g4 ship-gate-council.md §5: missing degraded-rule phrase"
fi
remove_line_substr "$SG" "$TMP/g4-sg-mut.md" "$G4_SG_A"
if has "$TMP/g4-sg-mut.md" "$G4_SG_A"; then
  fail "g4-bite ship-gate-council.md mutation did not remove the phrase"
else
  pass "g4-bite ship-gate-council.md mutation removes 'regardless of ...' -> check would fail"
fi

# =============================================================================
# g5 — `--council-tier` is the sole flag.
# =============================================================================
G5_SPEC_A="The **sole** permitted flag is"
G5_SG_A="is the **sole** flag M14(a) permits"

if has "$SPEC" "$G5_SPEC_A"; then
  pass "g5 SPEC-033: --council-tier is the sole permitted flag"
else
  fail "g5 SPEC-033: sole-permitted-flag phrase missing"
fi
remove_line_substr "$SPEC" "$TMP/g5-spec-mut.md" "$G5_SPEC_A"
if has "$TMP/g5-spec-mut.md" "$G5_SPEC_A"; then
  fail "g5-bite SPEC-033 mutation did not remove the phrase"
else
  pass "g5-bite SPEC-033 mutation removes 'sole permitted flag' -> check would fail"
fi

if has "$SG" "$G5_SG_A"; then
  pass "g5 ship-gate-council.md: --council-tier is the sole flag (prose)"
else
  fail "g5 ship-gate-council.md: sole-flag phrase missing"
fi
remove_line_substr "$SG" "$TMP/g5-sg-mut.md" "$G5_SG_A"
if has "$TMP/g5-sg-mut.md" "$G5_SG_A"; then
  fail "g5-bite ship-gate-council.md mutation did not remove the phrase"
else
  pass "g5-bite ship-gate-council.md mutation removes 'sole flag' -> check would fail"
fi

# g5b — the §3b `/council` invocation line itself carries no other `--` flag
# outside the quoted claim string.
INVOKE_LINE=$(grep '^/council "' "$SG" || true)
if [ -z "$INVOKE_LINE" ]; then
  fail "g5b could not find the §3b /council invocation line"
else
  # Strip the quoted claim (no embedded double-quotes in that text), then
  # count '--' occurrences in what remains.
  REMAINDER=$(printf '%s' "$INVOKE_LINE" | sed -E 's/^\/council "[^"]*" //')
  N_FLAGS=$(printf '%s' "$REMAINDER" | grep -o -- '--[A-Za-z-]*' | wc -l | tr -d ' ')
  if [ "$N_FLAGS" -eq 1 ] && printf '%s' "$REMAINDER" | grep -q -- '^--council-tier='; then
    pass "g5b §3b invocation line: exactly one flag, --council-tier=<tier>"
  else
    fail "g5b §3b invocation line: expected sole --council-tier flag, got '$REMAINDER'"
  fi
fi
# Bite: append a second flag to a mutated copy and confirm the check fails.
sed -E 's#(--council-tier=<tier>)$#\1 --plan=<x>#' "$SG" > "$TMP/g5b-sg-mut.md"
MUT_LINE=$(grep '^/council "' "$TMP/g5b-sg-mut.md" || true)
MUT_REMAINDER=$(printf '%s' "$MUT_LINE" | sed -E 's/^\/council "[^"]*" //')
MUT_N=$(printf '%s' "$MUT_REMAINDER" | grep -o -- '--[A-Za-z-]*' | wc -l | tr -d ' ')
if [ "$MUT_N" -eq 1 ]; then
  fail "g5b-bite mutated invocation line still counted as one flag"
else
  pass "g5b-bite mutated invocation line (extra --plan flag) -> check would fail"
fi

# =============================================================================
# AC A — revision row names the review report; procedure names the mapper,
# cites M14(b)/(i), and does not restate M14(b).
# =============================================================================
ROW=$(grep '| 2026-09-26 |' "$SPEC" | grep 'WP 1-14' || true)
if [ -n "$ROW" ] && printf '%s' "$ROW" | grep -q -- '\.claude/council/'; then
  pass "a1 SPEC-033 Version History: WP 1-14 row names a .claude/council/ report"
else
  fail "a1 SPEC-033 Version History: WP 1-14 row missing or no .claude/council/ report path"
fi
sed -E 's#\.claude/council/[^`; ]*#REDACTED#' "$SPEC" > "$TMP/a1-spec-mut.md"
MUT_ROW=$(grep '| 2026-09-26 |' "$TMP/a1-spec-mut.md" | grep 'WP 1-14' || true)
if printf '%s' "$MUT_ROW" | grep -q -- '\.claude/council/'; then
  fail "a1-bite mutation did not remove the report path"
else
  pass "a1-bite mutated row loses .claude/council/ path -> check would fail"
fi

LINE7=$(sed -n '7p' "$SG")
LINE8=$(sed -n '8p' "$SG")
if printf '%s' "$LINE7" | grep -q 'ship-gate-verdict\.sh' \
  && printf '%s' "$LINE8" | grep -q 'not a render helper'; then
  pass "a2 ship-gate-council.md line 7/8 names the mapper + 'not a render helper'"
else
  fail "a2 ship-gate-council.md line 7/8 missing mapper name or 'not a render helper'"
fi
remove_line_substr "$SG" "$TMP/a2-sg-mut.md" "not a render helper"
MUT_LINE8=$(sed -n '8p' "$TMP/a2-sg-mut.md")
if printf '%s' "$MUT_LINE8" | grep -q 'not a render helper'; then
  fail "a2-bite mutation did not remove 'not a render helper'"
else
  pass "a2-bite mutated line 8 loses 'not a render helper' -> check would fail"
fi

if has "$SG" "M14(b)" && has "$SG" "M14(i)"; then
  pass "a3 ship-gate-council.md cites M14(b) and M14(i)"
else
  fail "a3 ship-gate-council.md missing M14(b) or M14(i) citation"
fi

if has "$SG" "FABRICATED\`, \`CONTRADICTED\`, \`UNVERIFIED\`" || has "$SG" "lowest confidence"; then
  fail "a4 ship-gate-council.md restates M14(b)'s worst-order string or 'lowest confidence'"
else
  pass "a4 ship-gate-council.md does not restate M14(b) (no worst-order string, no 'lowest confidence')"
fi
# Bite: inject the forbidden restatement and confirm the check now fails.
printf '%s\nFABRICATED`, `CONTRADICTED`, `UNVERIFIED` is the worst order.\n' "$(cat "$SG")" > "$TMP/a4-sg-mut.md"
if has "$TMP/a4-sg-mut.md" "FABRICATED\`, \`CONTRADICTED\`, \`UNVERIFIED\`"; then
  pass "a4-bite injected restatement is detected -> check would fail"
else
  fail "a4-bite injected restatement was not detected"
fi

# =============================================================================
# Writers — 06-design.md, 04-kickoff.md, 10-qa.md, kickoff/SKILL.md each cite
# M14(g) and `## Acceptance criteria`.
# =============================================================================
i=0
for wf in "$W1" "$W2" "$W3" "$W4"; do
  i=$((i + 1))
  name=$(basename "$(dirname "$wf")")/$(basename "$wf")
  if has "$wf" "M14(g)" && has "$wf" '## Acceptance criteria'; then
    pass "w$i $name cites M14(g) and '## Acceptance criteria'"
  else
    fail "w$i $name missing M14(g) or '## Acceptance criteria' citation"
  fi
  remove_all_substr "$wf" "$TMP/w$i-mut.md" "M14(g)"
  if has "$TMP/w$i-mut.md" "M14(g)"; then
    fail "w$i-bite mutation did not remove the M14(g) citation"
  else
    pass "w$i-bite $name mutation removes M14(g) -> check would fail"
  fi
done

# =============================================================================
# w5/w6 — Step 4 (04-kickoff.md) and Step 6 (06-design.md) ask writers to add
# a `Verify:` continuation per technical AC (SPEC-033 M14(g), WP 1-15 AC L).
# =============================================================================
VERIFY_ASK='`Verify: bash <test file>` continuation'

if has "$W2" "$VERIFY_ASK" && has "$W2" "M14(g)"; then
  pass "w5 04-kickoff.md: asks writers for a Verify: continuation, cites M14(g)"
else
  fail "w5 04-kickoff.md: missing the Verify: continuation ask or M14(g) citation"
fi
remove_line_substr "$W2" "$TMP/w5-mut.md" "$VERIFY_ASK"
if has "$TMP/w5-mut.md" "$VERIFY_ASK"; then
  fail "w5-bite mutation did not remove the Verify: continuation ask"
else
  pass "w5-bite 04-kickoff.md mutation removes the Verify: ask -> check would fail"
fi

if has "$W1" "$VERIFY_ASK" && has "$W1" "M14(g)"; then
  pass "w6 06-design.md: asks writers for a Verify: continuation, cites M14(g)"
else
  fail "w6 06-design.md: missing the Verify: continuation ask or M14(g) citation"
fi
remove_line_substr "$W1" "$TMP/w6-mut.md" "$VERIFY_ASK"
if has "$TMP/w6-mut.md" "$VERIFY_ASK"; then
  fail "w6-bite mutation did not remove the Verify: continuation ask"
else
  pass "w6-bite 06-design.md mutation removes the Verify: ask -> check would fail"
fi

# =============================================================================
# w7 — Step 10b (10-qa.md) reports ACs with `verify: null` and Verify files
# missing `hermetic_init` (SPEC-033 M14(g), WP 1-15 AC L).
# =============================================================================
W7_REPORT='`verify: null` in `$SPLIT_JSON`, and each Verify'
W7_HERMETIC='does not call `hermetic_init`, as a report line'

if has "$W3" "$W7_REPORT" && has "$W3" "$W7_HERMETIC" && has "$W3" "M14(g)"; then
  pass "w7 10-qa.md: reports verify:null ACs and non-hermetic Verify files, cites M14(g)"
else
  fail "w7 10-qa.md: missing the verify:null/hermetic_init report line or M14(g) citation"
fi
remove_line_substr "$W3" "$TMP/w7-mut.md" "$W7_HERMETIC"
if has "$TMP/w7-mut.md" "$W7_HERMETIC"; then
  fail "w7-bite mutation did not remove the hermetic_init report clause"
else
  pass "w7-bite 10-qa.md mutation removes 'hermetic_init' report clause -> check would fail"
fi

W7_CASE11='m14-ac-split: case 11:'
W7_DISAMBIG='case 10 and case 11 exit 8'

if has "$W3" "$W7_CASE11" && has "$W3" "$W7_DISAMBIG"; then
  pass "w7 10-qa.md: case 11 picked out by its stderr line, not by rc alone"
else
  fail "w7 10-qa.md: missing the case-11 stderr-line disambiguation from case 10"
fi
remove_line_substr "$W3" "$TMP/w7-case11-mut.md" "$W7_CASE11"
if has "$TMP/w7-case11-mut.md" "$W7_CASE11"; then
  fail "w7-bite mutation did not remove the case-11 stderr-line prefix"
else
  pass "w7-bite 10-qa.md mutation removes the case-11 stderr-line prefix -> check would fail"
fi

# =============================================================================
# a5 (WP 1-15 AC A/G) — SPEC-033 names WP 1-15, M14(a) and M14(g) in a dated
# row; ship-gate-council.md cites M14(g) with no grammar restatement, no
# metacharacter list, and no `run-all-tests.sh` mention.
# =============================================================================
ROW2=$(grep '| 2026-09-27 |' "$SPEC" | grep 'WP 1-15' || true)
if [ -n "$ROW2" ] && printf '%s' "$ROW2" | grep -q 'M14(a)' && printf '%s' "$ROW2" | grep -q 'M14(g)'; then
  pass "a5 SPEC-033: dated row names WP 1-15, M14(a) and M14(g)"
else
  fail "a5 SPEC-033: WP 1-15 row missing or missing M14(a)/M14(g) citation"
fi
remove_all_substr "$SPEC" "$TMP/a5-spec-mut.md" "M14(g)"
MUT_ROW2=$(grep '| 2026-09-27 |' "$TMP/a5-spec-mut.md" | grep 'WP 1-15' || true)
if printf '%s' "$MUT_ROW2" | grep -q 'M14(g)'; then
  fail "a5-bite mutation did not remove the M14(g) citation from the row"
else
  pass "a5-bite mutated row loses M14(g) -> check would fail"
fi

if has "$SG" "M14(g)" && ! has "$SG" "run-all-tests.sh" && ! has "$SG" "A-Z a-z 0-9"; then
  pass "a5 ship-gate-council.md: cites M14(g), no run-all-tests.sh, no metacharacter list"
else
  fail "a5 ship-gate-council.md: missing M14(g) citation, or holds run-all-tests.sh / a metacharacter list"
fi
printf '%s\nrun-all-tests.sh\n' "$(cat "$SG")" > "$TMP/a5-sg-mut.md"
if has "$TMP/a5-sg-mut.md" "run-all-tests.sh"; then
  pass "a5-bite injected 'run-all-tests.sh' mention is detected -> check would fail"
else
  fail "a5-bite injected 'run-all-tests.sh' mention was not detected"
fi


# =============================================================================
# g6 (WP 1-15 AC G) — ship-gate-verdict.sh is byte-identical to cbee656.
# =============================================================================
assert_blob_hash "$VERDICT_SH" "$VERDICT_BLOB" "g6 ship-gate-verdict.sh"

# =============================================================================
# g7 (WP 1-15 AC G) — SPEC-033 M14(b) block, extracted by its (b)..(c)
# markers, is byte-equal to a committed golden extracted from cbee656. The
# M14(d) golden (g4, above) is unchanged.
# =============================================================================
BLOCK_B=$(extract_m14b "$SPEC")
if [ -z "$BLOCK_B" ]; then
  fail "g7 could not extract M14(b) block from SPEC-033"
elif diff <(printf '%s\n' "$BLOCK_B") "$GOLDEN_M14B" >/dev/null 2>&1; then
  pass "g7 SPEC-033 M14(b) block byte-equal to committed golden (base cbee656)"
else
  fail "g7 SPEC-033 M14(b) block differs from golden"
fi
# Bite: mutate one word inside the live spec's (b) block via the same
# literal-substring technique the other checks use, located by grepping for
# a phrase unique to the (b) block.
remove_line_substr "$SPEC" "$TMP/g7-spec-mut.md" "Confidence is the minimum"
MUT_BLOCK_B=$(extract_m14b "$TMP/g7-spec-mut.md")
if diff <(printf '%s\n' "$MUT_BLOCK_B") "$GOLDEN_M14B" >/dev/null 2>&1; then
  fail "g7-bite mutated M14(b) block still matched the golden"
else
  pass "g7-bite mutated M14(b) block diverges from golden -> byte-compare would fail"
fi

# =============================================================================
# g8 (WP 1-16 AC F) — append-card.sh is byte-identical to its WP 1-08 version (re-pinned at merge).
# =============================================================================
assert_blob_hash "$APPEND_CARD_SH" "$APPEND_CARD_BLOB" "g8 append-card.sh"
# =============================================================================
# g9 (WP 1-16 AC F) — ship-gate-council.md §5, extracted by its "## 5." /
# "## 6." markers, is byte-equal to a committed golden extracted from
# 38bc739 (the recipe citation lands after §3b; §5 stays untouched). Uses
# `cmp` on files, not a `$(...)`/diff round-trip, so a trailing-newline-only
# change in §5 is still caught (TL review L5).
# =============================================================================
extract_sgc_s5 "$SG" > "$TMP/g9-live-s5.md"
if [ ! -s "$TMP/g9-live-s5.md" ]; then
  fail "g9 could not extract §5 block from ship-gate-council.md"
elif cmp -s "$TMP/g9-live-s5.md" "$GOLDEN_SGC_S5"; then
  pass "g9 ship-gate-council.md §5 byte-equal to committed golden (base 38bc739)"
else
  fail "g9 ship-gate-council.md §5 differs from golden"
fi
# Bite: mutate one word inside the live §5 block and confirm it diverges.
remove_line_substr "$SG" "$TMP/g9-sg-mut.md" "regardless of that self-verified run's own reported confidence"
extract_sgc_s5 "$TMP/g9-sg-mut.md" > "$TMP/g9-mut-s5.md"
if cmp -s "$TMP/g9-mut-s5.md" "$GOLDEN_SGC_S5"; then
  fail "g9-bite mutated §5 block still matched the golden"
else
  pass "g9-bite mutated §5 block diverges from golden -> byte-compare would fail"
fi

# g9c-bite — a trailing-newline-only change to §5 (no word mutation) MUST
# also diverge under `cmp`, proving L5's fix actually bites (a `diff
# <(printf '%s\n' ...)` round-trip would silently swallow this one).
{ cat -- "$GOLDEN_SGC_S5"; printf '\n'; } > "$TMP/g9c-trailing-nl.md"
if cmp -s "$TMP/g9c-trailing-nl.md" "$GOLDEN_SGC_S5"; then
  fail "g9c-bite an extra trailing newline still compared equal to the golden"
else
  pass "g9c-bite an extra trailing newline diverges from the golden -> cmp would fail"
fi

# =============================================================================
# g10 (WP 1-16 AC F) — engine.sh holds the two M14 tool-budget constants.
# =============================================================================
G10_A="readonly M14_VERIFY_TOOL_BUDGET=8"
G10_B="readonly INVESTIGATOR_TOOL_BUDGET=5"

if has "$ENGINE_SH" "$G10_A" && has "$ENGINE_SH" "$G10_B"; then
  pass "g10 engine.sh: holds both M14 tool-budget constants (8, 5)"
else
  fail "g10 engine.sh: missing one of the M14 tool-budget constants"
fi
remove_line_substr "$ENGINE_SH" "$TMP/g10-mut.sh" "$G10_A"
if has "$TMP/g10-mut.sh" "$G10_A"; then
  fail "g10-bite mutation did not remove the M14_VERIFY_TOOL_BUDGET constant"
else
  pass "g10-bite mutated engine.sh loses M14_VERIFY_TOOL_BUDGET=8 -> check would fail"
fi

# =============================================================================
# a6 (WP 1-16 AC F) — SPEC-033 and SPEC-013 each carry a dated 2026-09-28
# WP 1-16 row naming the recipe, the budget, the no-elision rule and the
# judge caps.
# =============================================================================
ROW3=$(grep '| 2026-09-28 |' "$SPEC" | grep 'WP 1-16' || true)
if [ -n "$ROW3" ] \
  && printf '%s' "$ROW3" | grep -q 'M14(g)' \
  && printf '%s' "$ROW3" | grep -q 'M14(j)' \
  && printf '%s' "$ROW3" | grep -q 'elision' \
  && printf '%s' "$ROW3" | grep -q '79' \
  && printf '%s' "$ROW3" | grep -q 'can only lower a confidence'
then
  pass "a6 SPEC-033: dated WP 1-16 row names M14(g), M14(j), elision, 79 and 'can only lower a confidence'"
else
  fail "a6 SPEC-033: WP 1-16 row missing or missing one of its required citations"
fi
remove_all_substr "$SPEC" "$TMP/a6-spec-mut.md" "can only lower a confidence"
MUT_ROW3=$(grep '| 2026-09-28 |' "$TMP/a6-spec-mut.md" | grep 'WP 1-16' || true)
if printf '%s' "$MUT_ROW3" | grep -q 'can only lower a confidence'; then
  fail "a6-bite mutation did not remove the 'can only lower a confidence' phrase"
else
  pass "a6-bite mutated row loses 'can only lower a confidence' -> check would fail"
fi

ROW4=$(grep '| 2026-09-28 |' "$SPEC013" | grep 'WP 1-16' || true)
if [ -n "$ROW4" ]; then
  pass "a6 SPEC-013: has a dated 2026-09-28 WP 1-16 row"
else
  fail "a6 SPEC-013: missing a dated 2026-09-28 WP 1-16 row"
fi
remove_all_substr "$SPEC013" "$TMP/a6-spec013-mut.md" "WP 1-16"
MUT_ROW4=$(grep '| 2026-09-28 |' "$TMP/a6-spec013-mut.md" | grep 'WP 1-16' || true)
if [ -n "$MUT_ROW4" ]; then
  fail "a6-bite SPEC-013 mutation did not remove the WP 1-16 row"
else
  pass "a6-bite SPEC-013 mutated row loses 'WP 1-16' -> check would fail"
fi


# =============================================================================
# a7 (WP 1-16 AC F) — ship-gate-council.md §3b (only) names "finder recipe"
# and does not restate the recipe's own step headings. Scoped to the §3b
# extract, not the whole file: `M14(g)` alone would pass at base (TL review
# L4 — the citation this AC pins is the new "finder recipe" sentence, which
# did not exist before this WP; `M14(g)` by itself is not new to §3b).
# =============================================================================
extract_sgc_3b "$SG" > "$TMP/a7-live-3b.md"
if [ ! -s "$TMP/a7-live-3b.md" ]; then
  fail "a7 could not extract §3b block from ship-gate-council.md"
elif has "$TMP/a7-live-3b.md" "finder recipe" && ! has "$TMP/a7-live-3b.md" "RECIPE STEP"; then
  pass "a7 ship-gate-council.md §3b: names 'finder recipe', no RECIPE STEP restatement"
else
  fail "a7 ship-gate-council.md §3b: missing 'finder recipe' citation, or restates RECIPE STEP"
fi

# Bite: remove the 'finder recipe' phrase and confirm the §3b extract loses it.
remove_line_substr "$SG" "$TMP/a7-sg-mut.md" "finder recipe"
extract_sgc_3b "$TMP/a7-sg-mut.md" > "$TMP/a7-mut-3b.md"
if has "$TMP/a7-mut-3b.md" "finder recipe"; then
  fail "a7-bite mutation did not remove the 'finder recipe' citation"
else
  pass "a7-bite mutated §3b loses 'finder recipe' -> check would fail"
fi

# Bite: inject a 'RECIPE STEP' restatement INSIDE §3b (not merely appended
# at end of file, which the old whole-file check would have wrongly missed
# once scoped) and confirm the §3b extract catches it.
sed '/^### 3b\./a RECIPE STEP 1' "$SG" > "$TMP/a7-sg-mut2.md"
extract_sgc_3b "$TMP/a7-sg-mut2.md" > "$TMP/a7-mut2-3b.md"
if has "$TMP/a7-mut2-3b.md" "RECIPE STEP"; then
  pass "a7-bite injected 'RECIPE STEP' restatement inside §3b is detected -> check would fail"
else
  fail "a7-bite injected 'RECIPE STEP' restatement inside §3b was not detected"
fi

# =============================================================================
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
