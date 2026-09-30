#!/usr/bin/env bash
# skills/autopilot/test-flag-matrix.sh — SPEC-033 wp-1-08-autopilot-state AC H.
#
# Table-driven suite (WP 1-08 Task 6) for:
#   - skills/autopilot/parse-flags.sh  (SPEC-033 M16 duplicate + near-miss)
#   - skills/epic/parse-flags.sh       (SPEC-033 M16 near-miss)
#   - skills/autopilot/loc-exclude.sh  (SPEC-033 M16 subdir resolution)
#
# Each row: parser, argv, want rc, want JSON key/value (jq filter, or "-" to
# skip the JSON check). Rows cover: duplicate, bare, empty, `=` form, space
# form, near-miss of the flag's own family, and other-family pass-through.
# Runs no live council; writes only under TMPDIR (hermetic).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

SCRIPT_DIR="$ROOT/skills/autopilot"
AUTOPILOT_PARSE="$SCRIPT_DIR/parse-flags.sh"
EPIC_PARSE="$ROOT/skills/epic/parse-flags.sh"
LOC_EXCLUDE="$SCRIPT_DIR/loc-exclude.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  fail "jq not found; cannot run this suite"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# run_row <label> <script> <want_rc> <want_jq|-> <argv...>
# argv... comes after the fixed args; empty argv is legal (no positionals).
run_row() {
  label=$1; script=$2; want_rc=$3; want_jq=$4
  shift 4
  out=$(bash "$script" "$@" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq "$want_rc" ]; then
    if [ "$want_jq" = "-" ] || [ "$rc" -ne 0 ]; then
      pass "$label rc=$rc"
    elif printf '%s' "$out" | jq -e "$want_jq" >/dev/null 2>&1; then
      pass "$label rc=$rc json-ok"
    else
      fail "$label rc=$rc but JSON did not match: $out"
    fi
  else
    fail "$label rc=$rc (want $want_rc)"
  fi
}

# =============================================================================
# skills/autopilot/parse-flags.sh — SPEC-033 M16
# =============================================================================

# ---- duplicate: --autopilot / --autopilot=* (both orders) -------------------
run_row "ap-dup1 --autopilot=patch --autopilot" "$AUTOPILOT_PARSE" 64 - \
  --autopilot=patch --autopilot
run_row "ap-dup2 --autopilot --autopilot=patch" "$AUTOPILOT_PARSE" 64 - \
  --autopilot --autopilot=patch
run_row "ap-dup3 --autopilot --autopilot (bare+bare)" "$AUTOPILOT_PARSE" 64 - \
  --autopilot --autopilot
run_row "ap-dup4 --autopilot=patch --autopilot=patch (eq+eq same value)" "$AUTOPILOT_PARSE" 64 - \
  --autopilot=patch --autopilot=patch

# ---- duplicate: --council-tier / --council-tier=* ----------------------------
run_row "ap-dup5 second --council-tier=light --council-tier=full" "$AUTOPILOT_PARSE" 64 - \
  --council-tier=light --council-tier=full
run_row "ap-dup6 --council-tier --council-tier (bare+bare)" "$AUTOPILOT_PARSE" 64 - \
  --council-tier --council-tier

# ---- duplicate: --tier / --tier=* --------------------------------------------
run_row "ap-dup7 second --tier=light --tier=full" "$AUTOPILOT_PARSE" 64 - \
  --tier=light --tier=full

# ---- duplicate: --max-loc / --max-loc=* (was last-wins pre-M16) -------------
run_row "ap-dup8 second --max-loc=5 --max-loc=10" "$AUTOPILOT_PARSE" 64 - \
  --max-loc=5 --max-loc=10
run_row "ap-dup9 --max-loc --max-loc (bare+bare)" "$AUTOPILOT_PARSE" 64 - \
  --max-loc --max-loc

# ---- bare / empty forms ------------------------------------------------------
run_row "ap-bare1 bare --council-tier no value" "$AUTOPILOT_PARSE" 64 - \
  --council-tier
run_row "ap-empty1 empty --council-tier=" "$AUTOPILOT_PARSE" 64 - \
  --council-tier=
run_row "ap-bare2 bare --tier no value" "$AUTOPILOT_PARSE" 64 - \
  --tier
run_row "ap-empty2 empty --max-loc=" "$AUTOPILOT_PARSE" 64 - \
  --max-loc=

# ---- `=` form (legal) --------------------------------------------------------
run_row "ap-eq1 --autopilot=patch" "$AUTOPILOT_PARSE" 0 \
  '.enabled == true and .bump == "patch" and .source == "flag"' \
  --autopilot=patch
run_row "ap-eq2 --max-loc=250" "$AUTOPILOT_PARSE" 0 '.max_loc == 250' \
  --max-loc=250

# ---- space form (illegal for these flags) ------------------------------------
run_row "ap-space1 --max-loc 250 (space form illegal)" "$AUTOPILOT_PARSE" 64 - \
  --max-loc 250
run_row "ap-space2 --tier standard (space form illegal)" "$AUTOPILOT_PARSE" 64 - \
  --tier standard

# ---- near-miss of own family -------------------------------------------------
run_row "ap-nearmiss1 --autopliot (typo)" "$AUTOPILOT_PARSE" 64 - \
  --autopliot
run_row "ap-nearmiss2 --max-locs=5 (typo)" "$AUTOPILOT_PARSE" 64 - \
  --max-locs=5
run_row "ap-nearmiss3 --council-tiers=full (typo)" "$AUTOPILOT_PARSE" 64 - \
  --council-tiers=full
run_row "ap-nearmiss4 --tiers=full (typo)" "$AUTOPILOT_PARSE" 64 - \
  --tiers=full

# ---- other-family pass-through -----------------------------------------------
run_row "ap-passthrough1 --worktree" "$AUTOPILOT_PARSE" 0 \
  '.enabled == false and .source == "none"' \
  --worktree
run_row "ap-passthrough2 --resume-ship" "$AUTOPILOT_PARSE" 0 \
  '.enabled == false and .source == "none"' \
  --resume-ship

# =============================================================================
# skills/epic/parse-flags.sh — SPEC-033 M16 (epic rows carry an <EPIC-ID>
# positional; epic-lib.sh dispatches on the first positional)
# =============================================================================

# ---- near-miss of own family --------------------------------------------------
run_row "ep-nearmiss1 --worktre (typo)" "$EPIC_PARSE" 64 - \
  EPIC-7 --worktre
run_row "ep-nearmiss2 --releas patch (typo)" "$EPIC_PARSE" 64 - \
  EPIC-7 --releas patch
run_row "ep-nearmiss3 --worktrees (typo, no EPIC-ID)" "$EPIC_PARSE" 64 - \
  --worktrees

# ---- duplicate (pre-existing rule; still holds) -------------------------------
run_row "ep-dup1 duplicate --worktree" "$EPIC_PARSE" 64 - \
  EPIC-7 --worktree --worktree
run_row "ep-dup2 duplicate --release patch --release patch" "$EPIC_PARSE" 64 - \
  EPIC-7 --worktree --release patch --release patch

# ---- bare / empty --------------------------------------------------------------
run_row "ep-bare1 bare --release no value" "$EPIC_PARSE" 64 - \
  EPIC-7 --worktree --release
run_row "ep-empty1 empty --release=" "$EPIC_PARSE" 64 - \
  EPIC-7 --worktree --release=

# ---- `=` form and space form (both legal for --release) ----------------------
run_row "ep-eq1 --release=patch" "$EPIC_PARSE" 0 \
  '.worktree_enabled == true and .release_bump == "patch"' \
  EPIC-7 --worktree --release=patch
run_row "ep-space1 --release patch (space form canonical)" "$EPIC_PARSE" 0 \
  '.worktree_enabled == true and .release_bump == "patch"' \
  EPIC-7 --worktree --release patch

# ---- other-family pass-through -------------------------------------------------
run_row "ep-passthrough1 --autopilot=patch" "$EPIC_PARSE" 0 \
  '.worktree_enabled == false and .release_bump == null' \
  EPIC-7 --autopilot=patch
run_row "ep-passthrough2 --redecompose" "$EPIC_PARSE" 0 \
  '.worktree_enabled == false and .release_bump == null' \
  EPIC-7 --redecompose

# =============================================================================
# skills/autopilot/loc-exclude.sh — SPEC-033 M16 subdir resolution
# =============================================================================

LOC_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/loc-exclude-fixture.XXXXXX")
(
  cd "$LOC_FIXTURE" || exit 1
  git init -q .
  mkdir -p sub
  printf '%s\n' 'sub/gen.go linguist-generated=true' > .gitattributes
  : > sub/gen.go
) || fail "loc-exclude fixture setup failed"

TOP_RC=0
(cd "$LOC_FIXTURE" && bash "$LOC_EXCLUDE" is-excluded sub/gen.go) >/dev/null 2>&1
TOP_RC=$?
SUB_RC=0
(cd "$LOC_FIXTURE/sub" && bash "$LOC_EXCLUDE" is-excluded sub/gen.go) >/dev/null 2>&1
SUB_RC=$?

if [ "$TOP_RC" -eq 0 ] && [ "$SUB_RC" -eq "$TOP_RC" ]; then
  pass "loc-exclude same repo-relative path gives same rc from top ($TOP_RC) and subdir ($SUB_RC)"
else
  fail "loc-exclude top rc=$TOP_RC sub rc=$SUB_RC (want equal, and 0 for linguist-generated=true)"
fi

rm -rf "$LOC_FIXTURE"

# =============================================================================
# AC H: "skills/autopilot/parse-flags.sh header states the duplicate rule."
# Static check with a planted negative control (hazard checklist: every
# static grep test needs one).
# =============================================================================

header_states_duplicate_rule() {
  # Capture the header first and grep a here-string: `sed | grep -q` under
  # pipefail fails at random when grep exits early and sed gets SIGPIPE.
  local hdr
  hdr=$(sed -n '1,/^set -euo pipefail/p' "$1")
  grep -qi 'duplicate' <<<"$hdr" && grep -q 'exits 64' <<<"$hdr"
}

if header_states_duplicate_rule "$AUTOPILOT_PARSE"; then
  pass "ap-header parse-flags.sh header states the duplicate rule"
else
  fail "ap-header parse-flags.sh header does not state the duplicate rule"
fi

# Negative control: replace the word "duplicate" throughout the header and
# confirm the same check correctly fails on the mutated copy.
NEG=$(mktemp "${TMPDIR:-/tmp}/parse-flags-neg.XXXXXX.sh")
sed -E '1,/^set -euo pipefail/ s/[Dd]uplicate/xxx/g' \
  "$AUTOPILOT_PARSE" > "$NEG"
if header_states_duplicate_rule "$NEG"; then
  fail "ap-header negative control still matched (check does not discriminate)"
else
  pass "ap-header negative control fails without the word duplicate in the header"
fi
rm -f "$NEG"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
