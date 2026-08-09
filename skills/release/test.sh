#!/usr/bin/env bash
# SPEC-010 staged-path hard gate harness (CDT-189 AC-9 / S8).
# Isolated temp git repos only — never the live worktree index.
# Run: bash skills/release/test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$HERE/check-staged-paths.sh"
PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

run_in_repo() { # run_in_repo <repo> -- <check-args...>
  local d="$1"; shift
  [ "$1" = "--" ] && shift
  RC=0
  OUT=$(cd "$d" && bash "$CHECK" "$@" 2>&1) && RC=0 || RC=$?
}

run_check() { # run_check <expected_exit> [args...]  — cwd = live tree OK for usage-only
  local want="$1"; shift
  RC=0
  OUT=$(bash "$CHECK" "$@" 2>&1) && RC=0 || RC=$?
  if [ "$RC" -eq "$want" ]; then
    pass "exit $want (${*:-no-args})"
  else
    fail "exit $RC != $want for: ${*:-no-args}"
    echo "  out: $OUT" | head -c 500
    echo
  fi
}

expect_contains() { # expect_contains <needle>
  if printf '%s\n' "$OUT" | grep -Fq -- "$1"; then
    pass "output contains: $1"
  else
    fail "output missing: $1"
    echo "  out: $OUT" | head -c 500
    echo
  fi
}

expect_rc() { # expect_rc <want> <label>
  if [ "$RC" -eq "$1" ]; then
    pass "$2 → $1"
  else
    fail "$2 exit $RC != $1: $OUT"
  fi
}

# --- temp git fixture helpers ---
make_repo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/release-gate-XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  git -C "$d" commit -q --allow-empty -m "init"
  printf '%s\n' "$d"
}

stage_pair() {
  local d="$1"
  mkdir -p "$d/.claude-plugin"
  printf '### v0.0.1\n\n- test\n' >"$d/CHANGELOG.md"
  printf '{"name":"t","version":"0.0.1"}\n' >"$d/.claude-plugin/plugin.json"
  git -C "$d" add CHANGELOG.md .claude-plugin/plugin.json
}

stage_file() {
  local d="$1" rel="$2" body="${3:-x}"
  local dir
  dir=$(dirname -- "$rel")
  if [ "$dir" != "." ]; then
    mkdir -p "$d/$dir"
  fi
  printf '%s\n' "$body" >"$d/$rel"
  git -C "$d" add -- "$rel"
}

write_file() {
  local d="$1" rel="$2" body="${3:-x}"
  local dir
  dir=$(dirname -- "$rel")
  if [ "$dir" != "." ]; then
    mkdir -p "$d/$dir"
  fi
  printf '%s\n' "$body" >"$d/$rel"
}

index_snapshot() {
  git -C "$1" diff --cached --name-only | sort
}

# ---------------------------------------------------------------------------
# Usage edges (S1 / S6)
# ---------------------------------------------------------------------------
run_check 64
expect_contains "--intended"

run_check 64 --no-such-flag
expect_contains "unknown flag"

# not a git repo
NOT_GIT=$(mktemp -d "${TMPDIR:-/tmp}/release-gate-nogit-XXXXXX")
RC=0
OUT=$(cd "$NOT_GIT" && bash "$CHECK" --intended foo 2>&1) && RC=0 || RC=$?
expect_rc 64 "not-a-git-repo"
rm -rf "$NOT_GIT"

# ---------------------------------------------------------------------------
# AC-9: pair + allowed path staged → 0
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/release/SKILL.md" "skill body"
run_in_repo "$REPO" -- --intended skills/release/SKILL.md
expect_rc 0 "pair+allowed"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# AC-9: pair + foreign path → 1, foreign listed, no index mutation
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/release/SKILL.md" "skill body"
stage_file "$REPO" "secrets/noise.txt" "leak"
BEFORE=$(index_snapshot "$REPO")
run_in_repo "$REPO" -- --intended skills/release/SKILL.md
expect_rc 1 "pair+foreign"
expect_contains "staged-path hard gate"
expect_contains "secrets/noise.txt"
if printf '%s\n' "$OUT" | grep -Eqi 'MUST NOT proceed|commit/tag/push'; then
  pass "forbids commit/tag/push"
else
  fail "missing no-commit wording in: $OUT"
fi
AFTER=$(index_snapshot "$REPO")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "no index mutation on fail"
else
  fail "index changed: before=[$BEFORE] after=[$AFTER]"
fi
if git -C "$REPO" diff --cached --name-only | grep -Fq -- "secrets/noise.txt"; then
  pass "foreign still staged after fail"
else
  fail "gate unstaged foreign path"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# AC-9: foreign on --allow-extra → 0
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/release/SKILL.md" "skill body"
stage_file "$REPO" "docs/extra.md" "extra"
run_in_repo "$REPO" -- --intended skills/release/SKILL.md --allow-extra docs/extra.md
expect_rc 0 "allow-extra admits extra"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# AC-9: unstaged foreign dirty only → 0 for this gate
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/release/SKILL.md" "skill body"
write_file "$REPO" "dirty/untracked-or-modified.txt" "not staged"
# dirty worktree on already-staged CHANGELOG (index unchanged)
printf '### v0.0.1\n\n- test\n- dirty worktree\n' >"$REPO/CHANGELOG.md"
run_in_repo "$REPO" -- --intended skills/release/SKILL.md
expect_rc 0 "unstaged dirty ignored"
if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  pass "worktree still dirty (gate ignored it)"
else
  fail "expected dirty worktree for fixture"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# Empty staged → 0 (S4)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
run_in_repo "$REPO" -- --intended skills/release/SKILL.md
expect_rc 0 "empty staged"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# Pair-only (no product intended paths) → 0 when only pair staged
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
run_in_repo "$REPO" -- --intended
expect_rc 0 "pair-only --intended (no paths)"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
