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
cp "$FIX"/*.sh "$REPO"/
chmod +x "$REPO"/*.sh
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


# ---- Case 10 / verify field: valid Verify line -> JSON verify; no Verify
# line -> null (SPEC-033 M14(g) WP 1-15, IC C1) --------------------------
OUT="$(run wp-case10-valid case10-valid-verify.md)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "case10-valid: exits 0"; else fail_msg "case10-valid: exits 0 (got $RC)"; fi
V_A="$(echo "$OUT" | jq -r '.acs[] | select(.id=="A") | .verify')"
if [ "$V_A" = "bash test-widget.sh" ]; then
  ok "case10-valid: AC A verify = the Verify command"
else
  fail_msg "case10-valid: AC A verify (got: $V_A)"
fi
V_B="$(echo "$OUT" | jq -r '.acs[] | select(.id=="B") | .verify')"
if [ "$V_B" = "null" ]; then
  ok "case10-valid: AC B (no Verify line) verify = null"
else
  fail_msg "case10-valid: AC B verify (got: $V_B)"
fi

# ---- Case 10: grammar breaks (3 spaces; a tab) -----------------------------
ERR="$(run wp-case10-3space case10-3space.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]]; then
  ok "case 10: 3-space indent breaks the grammar (exit 8, one stderr line)"
else
  fail_msg "case 10: 3-space indent (rc=$RC, stderr=$ERR)"
fi

ERR="$(run wp-case10-tab case10-tab.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [ "$(echo "$ERR" | wc -l)" -eq 1 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]]; then
  ok "case 10: tab indent breaks the grammar (exit 8, one stderr line)"
else
  fail_msg "case 10: tab indent (rc=$RC, stderr=$ERR)"
fi

# ---- Case 10: each disallowed metacharacter / a quote ---------------------
for bc_ticket in wp-case10-semi wp-case10-pipe wp-case10-amp wp-case10-dollar \
                 wp-case10-backtick wp-case10-lt wp-case10-gt wp-case10-paren \
                 wp-case10-quote; do
  ERR="$(run "$bc_ticket" case10-badchars.md 2>&1 1>/dev/null)"; RC=$?
  if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]]; then
    ok "case 10: $bc_ticket disallowed character breaks the grammar"
  else
    fail_msg "case 10: $bc_ticket (rc=$RC, stderr=$ERR)"
  fi
done

# ---- Case 10: more disallowed metacharacters, and a double space between --
# tokens (F6 rework) ---------------------------------------------------------
for bc_ticket in wp-case10-squote wp-case10-backslash wp-case10-star \
                 wp-case10-tilde wp-case10-doublespace; do
  ERR="$(run "$bc_ticket" case10-badchars2.md 2>&1 1>/dev/null)"; RC=$?
  if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]]; then
    ok "case 10: $bc_ticket disallowed character/spacing breaks the grammar"
  else
    fail_msg "case 10: $bc_ticket (rc=$RC, stderr=$ERR)"
  fi
done

# ---- Case 10: a Verify line before any AC bullet (F6 rework). The line's --
# own grammar is valid; it fails because there is no AC yet to attach it to.
ERR="$(run wp-case10-before-bullet case10-before-bullet.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]] && [[ "$ERR" == *"before any AC bullet"* ]]; then
  ok "case 10: a Verify line before any AC bullet (exit 8)"
else
  fail_msg "case 10: Verify line before any AC bullet (rc=$RC, stderr=$ERR)"
fi

# ---- Case 10: path checks (absolute; ".."; non-suite basename; -----------
# tools/run-all-tests.sh; absent at HEAD) ------------------------------------
ERR="$(run wp-case10-abspath case10-abspath.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]] && [[ "$ERR" == *"AC A"* ]]; then
  ok "case 10: absolute Verify path (exit 8, names AC A)"
else
  fail_msg "case 10: absolute Verify path (rc=$RC, stderr=$ERR)"
fi

ERR="$(run wp-case10-dotdot case10-dotdot.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]]; then
  ok "case 10: '..' segment in Verify path"
else
  fail_msg "case 10: '..' segment (rc=$RC, stderr=$ERR)"
fi

ERR="$(run wp-case10-notsuite case10-notsuite.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]]; then
  ok "case 10: non-suite basename in Verify path"
else
  fail_msg "case 10: non-suite basename (rc=$RC, stderr=$ERR)"
fi

ERR="$(run wp-case10-runalltests case10-runalltests.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]]; then
  ok "case 10: tools/run-all-tests.sh forbidden as a Verify target"
else
  fail_msg "case 10: tools/run-all-tests.sh (rc=$RC, stderr=$ERR)"
fi

ERR="$(run wp-case10-absent case10-absent.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]]; then
  ok "case 10: Verify path absent at HEAD"
else
  fail_msg "case 10: path absent at HEAD (rc=$RC, stderr=$ERR)"
fi

# ---- Case 10: two Verify lines on one AC; a Verify line on a [process] AC -
ERR="$(run wp-case10-dup case10-dup.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]] && [[ "$ERR" == *"AC A"* ]]; then
  ok "case 10: two Verify lines on one AC (exit 8, names AC A)"
else
  fail_msg "case 10: two Verify lines (rc=$RC, stderr=$ERR)"
fi

ERR="$(run wp-case10-process case10-process.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 10:"* ]] && [[ "$ERR" == *"AC A"* ]]; then
  ok "case 10: a [process] AC with a Verify line (exit 8, names AC A)"
else
  fail_msg "case 10: [process] AC with Verify (rc=$RC, stderr=$ERR)"
fi

# ---- Case 10 control: "Verify:" inside bullet text is not a Verify line ---
OUT="$(run wp-case10-notverify case10-notverify.md)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "case 10 control: 'Verify:' inside bullet prose stays valid (exits 0)"
else
  fail_msg "case 10 control: 'Verify:' in bullet prose (got rc=$RC)"
fi

# ---- Case 11: a Verify line + uncommitted tracked-file changes fails -------
# closed; a dirty tracked file with NO Verify line does not (exit 0). -------
OUT="$(run wp-case11-dirty case11-dirty.md)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "case 11: clean worktree with a Verify line exits 0"
else
  fail_msg "case 11: clean worktree (got rc=$RC)"
fi

echo "dirtied by test-m14-ac-split.sh" >> "$REPO/notasuite.sh"
ERR="$(run wp-case11-dirty case11-dirty.md 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 8 ] && [[ "$ERR" == "m14-ac-split: case 11:"* ]] && [[ "$ERR" == *"(ACs A)"* ]]; then
  ok "case 11: dirty tracked file + a Verify line fails closed (exit 8, names AC A)"
else
  fail_msg "case 11: dirty tracked file (rc=$RC, stderr=$ERR)"
fi
git -C "$REPO" checkout -q -- notasuite.sh

OUT="$(run wp-valid-mix valid-mix.md)"; RC=$?
echo "dirtied by test-m14-ac-split.sh, no Verify line in this ticket" >> "$REPO/notasuite.sh"
OUT2="$(run wp-valid-mix valid-mix.md)"; RC2=$?
if [ "$RC2" -eq 0 ] && [ "$OUT2" = "$OUT" ]; then
  ok "case 11: a dirty tracked file with no Verify line anywhere in the run does not fail closed"
else
  fail_msg "case 11: dirty file, no Verify line (rc=$RC2)"
fi
git -C "$REPO" checkout -q -- notasuite.sh

# ---- Old fixtures: byte-identical except the added verify:null ------------
if echo "$OUT" | jq -e '[.acs[].verify] == [null, null, null]' >/dev/null 2>&1; then
  ok "valid-mix: every AC (no Verify line in this fixture) has verify:null"
else
  fail_msg "valid-mix: verify:null on every AC"
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




# dogfood_subsection <ticket> <expected_technical> <expected_process_csv>
# Runs $ROOT's own current split script (not a clone's stale copy) against
# a `git clone -q` of this worktree's HEAD, overlaid with the INDEX's spec
# and every Verify-named file <ticket>'s subsection lists, committed in the
# clone only: /release Step 4.13 runs this suite with the WP's diff
# squash-staged into the INDEX but not yet committed, so a plain clone's
# HEAD (objects only) lacks this subsection and would wrongly fail case 3,
# not case 10 (WP 1-15 Task 11). Reads the INDEX (`git show ":<path>"`),
# not the working tree: a `cp` from the working tree would pass an
# untracked Verify file that the shipped commit will not actually contain
# -- exactly the gap case 10 exists to catch -- and would also pick up
# unstaged edits that will never ship. A path shaped `/...`, `../...`,
# `.../../...` or exactly `..` is skipped and left absent in the clone
# (never used to build a path outside it); the split then rejects it on
# its own terms.
# Asserts: split exits 0; technical-AC count == <expected_technical>;
# [process] ids == <expected_process_csv>; every technical AC has a
# non-null verify. WP 1-16 T3 extract: this replaces the WP 1-15 "AC M"
# block, parameterized so a second WP subsection can reuse it.
dogfood_subsection() {
  local ticket="$1" exp_tech="$2" exp_proc="$3"
  local clone_root spec_rel out rc tech proc nullverify
  clone_root="$(mktemp -d "${TMPDIR:-/tmp}/m14-ac-split-clone.XXXXXX")"
  git clone -q "$ROOT" "$clone_root/clone"
  spec_rel="specs/core/SPEC-033-autopilot-policy.md"
  mkdir -p "$clone_root/clone/$(dirname "$spec_rel")"
  git -C "$ROOT" show ":$spec_rel" > "$clone_root/clone/$spec_rel" 2>/dev/null \
    || rm -f "$clone_root/clone/$spec_rel"
  local vpaths
  vpaths="$(DF_TICKET="### $ticket" awk '
    /^## Acceptance criteria$/ { insec = 1; next }
    insec && !insub && /^## / { insec = 0 }
    insec && !insub && $0 == ENVIRON["DF_TICKET"] { insub = 1; next }
    insub && (/^### / || /^## / || /^---$/) { insub = 0 }
    insub && /^  Verify: bash / { print }
  ' "$clone_root/clone/$spec_rel" 2>/dev/null | sed -E 's/^  Verify: bash ([^ ]+).*/\1/')"
  local vp
  while IFS= read -r vp || [ -n "$vp" ]; do
    [ -n "$vp" ] || continue
    case "$vp" in
      /*|../*|*/../*|..) continue ;;
    esac
    mkdir -p "$clone_root/clone/$(dirname "$vp")"
    git -C "$ROOT" show ":$vp" > "$clone_root/clone/$vp" 2>/dev/null \
      || rm -f "$clone_root/clone/$vp"
  done <<<"$vpaths"
  git -C "$clone_root/clone" add -A
  git -C "$clone_root/clone" commit -q -m "overlay index for $ticket" --allow-empty
  out="$(cd "$clone_root/clone" && bash "$ROOT/skills/council/m14-ac-split.sh" "$ticket" "$spec_rel")"
  rc=$?
  rm -rf "$clone_root"
  if [ "$rc" -eq 0 ]; then
    ok "dogfood $ticket: subsection splits at exit 0"
  else
    fail_msg "dogfood $ticket: subsection splits at exit 0 (got $rc)"
    return
  fi
  tech="$(echo "$out" | jq -r '[.acs[] | select(.process==false)] | length')"
  if [ "$tech" = "$exp_tech" ]; then
    ok "dogfood $ticket: $exp_tech technical ACs"
  else
    fail_msg "dogfood $ticket: $exp_tech technical ACs (got $tech)"
  fi
  proc="$(echo "$out" | jq -r '[.acs[] | select(.process==true) | .id] | join(",")')"
  if [ "$proc" = "$exp_proc" ]; then
    ok "dogfood $ticket: [process] ids $exp_proc"
  else
    fail_msg "dogfood $ticket: [process] ids $exp_proc (got $proc)"
  fi
  nullverify="$(echo "$out" | jq -r '[.acs[] | select(.process==false) | select(.verify==null)] | length')"
  if [ "$nullverify" = "0" ]; then
    ok "dogfood $ticket: every technical AC has a non-null verify"
  else
    fail_msg "dogfood $ticket: every technical AC has a non-null verify (got $nullverify null)"
  fi
}

# ---- AC M (WP 1-15) + WP 1-16: this WP's own SPEC-033 subsections, the ---
# tree about to ship.
dogfood_subsection wp-1-15-m14-verify-evidence 14 O,P
dogfood_subsection wp-1-16-m14-finder-recipe 8 I,J,K,L

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
