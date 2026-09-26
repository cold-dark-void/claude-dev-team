#!/usr/bin/env bash
# Test suite for skills/council/m14-ac-split.sh (SPEC-033 M14(g)/(h),
# SPEC-013 Phase 1 "M14 per-AC split", WP 1-14 interface contract C1).
# Fixtures: skills/council/fixtures/m14-ac-split/*.md.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/skills/council/m14-ac-split.sh"
FIX="$ROOT/skills/council/fixtures/m14-ac-split"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

fail=0
pass=0
ok() { echo "OK: $1"; pass=$((pass + 1)); }
fail_msg() { echo "FAIL: $1"; fail=$((fail + 1)); }

REPO="$HERMETIC_ROOT/repo"
mkdir -p "$REPO"
git init -q "$REPO"
cp "$FIX"/*.md "$REPO"/
git -C "$REPO" add -A
git -C "$REPO" commit -q -m fixtures

run() {  # run <ticket_id> <path> -- runs $SCRIPT from inside $REPO
  ( cd "$REPO" && bash "$SCRIPT" "$1" "$2" )
}

# ---- Valid mix: continuations, [process], two ticket subsections, --- ------
OUT="$(run wp-valid-mix valid-mix.md)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "valid-mix exits 0"; else fail_msg "valid-mix exits 0 (got $RC)"; fi
if [ "$(echo "$OUT" | jq -r '.ticket_id')" = "wp-valid-mix" ]; then
  ok "valid-mix ticket_id"
else
  fail_msg "valid-mix ticket_id (got: $(echo "$OUT" | jq -r '.ticket_id'))"
fi
if [ "$(echo "$OUT" | jq -r '.ac_source')" = "valid-mix.md" ]; then
  ok "valid-mix ac_source"
else
  fail_msg "valid-mix ac_source"
fi
IDS="$(echo "$OUT" | jq -r '.acs[].id' | paste -sd, -)"
if [ "$IDS" = "A,B,C" ]; then
  ok "valid-mix picks only its own subsection's ACs, in order (A,B,C)"
else
  fail_msg "valid-mix ids (got: $IDS)"
fi
PROC="$(echo "$OUT" | jq -r '[.acs[] | select(.process==true) | .id] | join(",")')"
if [ "$PROC" = "B" ]; then
  ok "valid-mix marks only B as [process]"
else
  fail_msg "valid-mix process ids (got: $PROC)"
fi
A_LINE="$(echo "$OUT" | jq -r '.acs[] | select(.id=="A") | .line')"
EXPECT_A_LINE="$(grep -n '^- \*\*A\.\*\* the diff adds a widget' "$FIX/valid-mix.md" | tail -1 | cut -d: -f1)"
if [ "$A_LINE" = "$EXPECT_A_LINE" ]; then
  ok "valid-mix AC A line number ($A_LINE)"
else
  fail_msg "valid-mix AC A line number (got $A_LINE, want $EXPECT_A_LINE)"
fi
if echo "$OUT" | jq -e '.acs | length == 3' >/dev/null; then
  ok "valid-mix acs length == 3"
else
  fail_msg "valid-mix acs length"
fi

# ---- Working-tree edit is not visible: only HEAD is read -------------------
echo "- **Z.** an uncommitted edit that MUST NOT appear" >> "$REPO/valid-mix.md"
OUT2="$(run wp-valid-mix valid-mix.md)"; RC2=$?
if [ "$RC2" -eq 0 ] && [ "$OUT2" = "$OUT" ]; then
  ok "working-tree edit is invisible (reads HEAD only)"
else
  fail_msg "working-tree edit is invisible (rc=$RC2, output changed: $([ "$OUT2" = "$OUT" ] && echo no || echo yes))"
fi
git -C "$REPO" checkout -q -- valid-mix.md

# ---- Case 1: path absent at HEAD / absolute / ".." -------------------------
ERR="$(run wp-valid-mix does-not-exist.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ] && [[ "$ERR" == "m14-ac-split: case 1:"* ]]; then
  ok "case 1: path absent at HEAD (exit 8, one stderr line)"
else
  fail_msg "case 1: path absent at HEAD (rc=$RC, stderr=$ERR)"
fi

ERR="$(run wp-valid-mix /etc/passwd 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ]; then
  ok "case 1: absolute path (exit 8, one stderr line)"
else
  fail_msg "case 1: absolute path (rc=$RC, stderr=$ERR)"
fi

ERR="$(run wp-valid-mix ../escape.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ]; then
  ok "case 1: '..' segment (exit 8, one stderr line)"
else
  fail_msg "case 1: '..' segment (rc=$RC, stderr=$ERR)"
fi

# ---- Case 2: missing "## Acceptance criteria" heading ----------------------
ERR="$(run wp-anything case2-no-heading.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ]; then
  ok "case 2: missing heading (exit 8, one stderr line)"
else
  fail_msg "case 2: missing heading (rc=$RC, stderr=$ERR)"
fi

# ---- Case 3: missing "### <ticket_id>" subsection ---------------------------
ERR="$(run wp-case3-missing case3-no-subsection.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ]; then
  ok "case 3: missing subsection (exit 8, one stderr line)"
else
  fail_msg "case 3: missing subsection (rc=$RC, stderr=$ERR)"
fi

# ---- Case 4: zero AC bullets in the subsection ------------------------------
ERR="$(run wp-case4 case4-zero-bullets.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ]; then
  ok "case 4: zero AC bullets (exit 8, one stderr line)"
else
  fail_msg "case 4: zero AC bullets (rc=$RC, stderr=$ERR)"
fi

# ---- Case 5: an invalid line (not blank/bullet/continuation) --------------
ERR="$(run wp-case5 case5-invalid-line.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ]; then
  ok "case 5: invalid line (exit 8, one stderr line)"
else
  fail_msg "case 5: invalid line (rc=$RC, stderr=$ERR)"
fi

# ---- Case 6: duplicate AC ids (stderr names the ids) ------------------------
ERR="$(run wp-case6 case6-dup-ids.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ] && [[ "$ERR" == *"A"* ]]; then
  ok "case 6: duplicate ids (exit 8, one stderr line naming the id)"
else
  fail_msg "case 6: duplicate ids (rc=$RC, stderr=$ERR)"
fi

# ---- Case 7: zero technical ACs remain --------------------------------------
ERR="$(run wp-case7 case7-all-process.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ]; then
  ok "case 7: zero technical ACs remain (exit 8, one stderr line)"
else
  fail_msg "case 7: zero technical ACs remain (rc=$RC, stderr=$ERR)"
fi

# ---- Case 8: a [process] AC fails guard 1 (stderr names the guard-1 id) ----
ERR="$(run wp-case8 case8-guard1-fail.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ] && [[ "$ERR" == *"A"* ]]; then
  ok "case 8: guard 1 fails (exit 8, one stderr line naming the id)"
else
  fail_msg "case 8: guard 1 fails (rc=$RC, stderr=$ERR)"
fi

# ---- Argv misuse: exit 64 ----------------------------------------------------
set +e
bash "$SCRIPT" >/dev/null 2>/dev/null; RC=$?
if [ "$RC" -eq 64 ]; then ok "argv misuse (0 args) exits 64"; else fail_msg "argv misuse (0 args) exits 64 (got $RC)"; fi

set +e
bash "$SCRIPT" only-one-arg >/dev/null 2>/dev/null; RC=$?
if [ "$RC" -eq 64 ]; then ok "argv misuse (1 arg) exits 64"; else fail_msg "argv misuse (1 arg) exits 64 (got $RC)"; fi

set +e
bash "$SCRIPT" a b c >/dev/null 2>/dev/null; RC=$?
if [ "$RC" -eq 64 ]; then ok "argv misuse (3 args) exits 64"; else fail_msg "argv misuse (3 args) exits 64 (got $RC)"; fi

# ---- Dogfood: this repo's own SPEC-033 AC subsection for this WP -----------
# Copies the real worktree's SPEC-033 (read-only source) into this test's own
# temp git repo and commits it there, so the check is hermetic: it does not
# depend on the enclosing repo's HEAD (e.g. /release Step 4.13 runs this
# suite with a release squash-staged but not yet committed, so HEAD is the
# prior release and lacks the "## Acceptance criteria" section).
cp "$ROOT/specs/core/SPEC-033-autopilot-policy.md" "$REPO/SPEC-033-autopilot-policy.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m spec-033
DF_OUT="$(run wp-1-14-m14-ship-gate-evidence SPEC-033-autopilot-policy.md)"
DF_RC=$?
if [ "$DF_RC" -eq 0 ]; then
  ok "dogfood: SPEC-033 wp-1-14-m14-ship-gate-evidence subsection exits 0"
else
  fail_msg "dogfood: exits 0 (got $DF_RC)"
fi
DF_IDS="$(echo "$DF_OUT" | jq -r '.acs[].id' | paste -sd, -)"
if [ "$DF_IDS" = "A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T" ]; then
  ok "dogfood: ids A through T, in document order"
else
  fail_msg "dogfood: ids (got: $DF_IDS)"
fi
DF_PROC="$(echo "$DF_OUT" | jq -r '[.acs[] | select(.process==true) | .id] | join(",")')"
if [ "$DF_PROC" = "I,Q,R,S" ]; then
  ok "dogfood: [process] ids I, Q, R, S"
else
  fail_msg "dogfood: process ids (got: $DF_PROC)"
fi
if echo "$DF_OUT" | jq -e '.acs | length == 20' >/dev/null; then
  ok "dogfood: 20 ACs total"
else
  fail_msg "dogfood: AC count"
fi

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
