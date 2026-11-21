#!/usr/bin/env bash
# SPEC-010 CDT-655 pre-release keyword guard tests: refuse-pre-keyword.sh
# refuses patch/minor/major on a pre-release version and passes on a final
# one; wiring asserted in /release Step 1, autopilot end-state §5-release,
# and the SPEC-010 `### CDT-655` AC subsection.
# Isolated temp git repos only — never the live tree. Run: bash skills/release/test-refuse-pre-keyword.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$REPO_ROOT/tests/lib/hermetic.sh"
hermetic_init

GUARD="$HERE/refuse-pre-keyword.sh"

PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

expect_rc() {
  if [ "$RC" -eq "$1" ]; then
    pass "$2 → $1"
  else
    fail "$2 exit $RC != $1: $OUT"
  fi
}

expect_contains() {
  if printf '%s\n' "$OUT" | grep -Fq -- "$1"; then
    pass "output contains: $1"
  else
    fail "output missing: $1"
    echo "  out: $OUT" | head -c 400
    echo
  fi
}

run_guard() { # run_guard <repo-dir> <args...>
  RC=0
  OUT=$(cd "$1" && bash "$GUARD" "${@:2}" 2>&1) && RC=0 || RC=$?
}

run_guard_here() { # run_guard_here <cwd> <args...> — cwd need not be a repo
  RC=0
  OUT=$(cd "$1" 2>/dev/null && bash "$GUARD" "${@:2}" 2>&1) && RC=0 || RC=$?
}

make_repo() { # make_repo <version>
  local d ver="$1"
  d=$(mktemp -d "${TMPDIR:-/tmp}/pre-keyword-XXXXXX")
  git -C "$d" init -q -b master
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  mkdir -p "$d/.claude-plugin"
  printf '{\n  "name": "dev-team",\n  "version": "%s"\n}\n' "$ver" >"$d/.claude-plugin/plugin.json"
  printf 'x\n' >"$d/f.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm baseline
  printf '%s\n' "$d"
}

# --- c1: pre-release version refuses every bump keyword -------------------
PRE_REPO=$(make_repo "2.0.0-pre.2")
for kw in patch minor major; do
  run_guard "$PRE_REPO" "$kw"
  expect_rc 1 "pre 2.0.0-pre.2 + $kw refuses"
  expect_contains "CDT-655"
  expect_contains "explicit version"
done

# --- c2: v-prefixed pre version refuses too -------------------------------
run_guard "$PRE_REPO" v2.0.0-pre.2 2>/dev/null || true
# (a keyword is never v-prefixed — the v-strip case is covered by the fixture below)

V_PRE_REPO=$(make_repo "v2.0.0-pre.1")
run_guard "$V_PRE_REPO" patch
expect_rc 1 "v2.0.0-pre.1 + patch refuses (v prefix stripped)"
expect_contains "2.0.0-pre.1"

# --- c3: final version passes every keyword -------------------------------
FINAL_REPO=$(make_repo "2.1.1")
for kw in patch minor major; do
  run_guard "$FINAL_REPO" "$kw"
  expect_rc 0 "final 2.1.1 + $kw passes"
done

# --- c4: pre→final boundary is the caller's job, not the guard's ----------
# The guard only judges the CURRENT version string; 2.0.0-pre.9 refusing is
# correct even though the eventual pre→final cut is legitimate (explicit
# version there).

# --- c5: usage errors → 64 ------------------------------------------------
run_guard "$FINAL_REPO"
expect_rc 64 "no args → 64"
run_guard "$FINAL_REPO" patch extra
expect_rc 64 "two args → 64"
run_guard "$FINAL_REPO" bogus
expect_rc 64 "bad keyword → 64"
NOT_A_REPO=$(mktemp -d "${TMPDIR:-/tmp}/pre-keyword-norepo-XXXXXX")
run_guard_here "$NOT_A_REPO" patch
expect_rc 64 "non-repo cwd → 64"

# --- c6: unreadable plugin.json → 64 --------------------------------------
EMPTY_REPO=$(make_repo "2.1.1")
rm "$EMPTY_REPO/.claude-plugin/plugin.json"
run_guard "$EMPTY_REPO" patch
expect_rc 64 "missing plugin.json → 64"

# --- c7: wiring — /release Step 1 rule 2 names the guard and halts --------
if grep -qF 'refuse-pre-keyword.sh' "$REPO_ROOT/skills/release/SKILL.md"; then
  pass "SKILL.md Step 1 wires refuse-pre-keyword.sh"
else
  fail "SKILL.md Step 1 does not wire refuse-pre-keyword.sh"
fi
if grep -qE 'refuse-pre-keyword\.sh.*\|\| (exit|halt)' "$REPO_ROOT/skills/release/SKILL.md" \
  || grep -B2 -A2 'refuse-pre-keyword.sh' "$REPO_ROOT/skills/release/SKILL.md" | grep -q 'exit'; then
  pass "SKILL.md halts the release on the guard's refusal"
else
  fail "SKILL.md guard fence does not halt on refusal"
fi

# --- c8: wiring — end-state §5-release guards before /release -------------
if grep -qF 'refuse-pre-keyword.sh' "$REPO_ROOT/skills/autopilot/end-state.md"; then
  pass "end-state.md §5-release wires refuse-pre-keyword.sh"
else
  fail "end-state.md §5-release does not wire refuse-pre-keyword.sh"
fi

# --- c9: wiring — SPEC-010 CDT-655 AC subsection --------------------------
if grep -q '^### CDT-655$' "$REPO_ROOT/specs/core/SPEC-010-code-review-release.md"; then
  pass "SPEC-010 carries ### CDT-655"
else
  fail "SPEC-010 missing ### CDT-655"
fi
if grep -qF 'Verify: bash skills/release/test-refuse-pre-keyword.sh' \
  "$REPO_ROOT/specs/core/SPEC-010-code-review-release.md"; then
  pass "SPEC-010 CDT-655 Verify points at this suite"
else
  fail "SPEC-010 CDT-655 Verify line missing"
fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
