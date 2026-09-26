#!/usr/bin/env bash
# SPEC-010 bump-class gate fixtures. Isolated temp repos only.
# Run: bash skills/release/test-bump-class.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$HERE/check-bump-class.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

run_in() {
  local d="$1"; shift
  RC=0
  OUT=$(cd "$d" && bash "$CHECK" "$@" 2>&1) && RC=0 || RC=$?
}

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

make_repo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/bump-class-XXXXXX")
  git -C "$d" init -q -b master
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  mkdir -p "$d/.claude-plugin" "$d/commands"
  printf '{"name":"t","version":"1.7.36"}\n' >"$d/.claude-plugin/plugin.json"
  printf '%s\n' '### v1.7.36' >"$d/CHANGELOG.md"
  printf '%s\n' '# existing' >"$d/commands/status.md"
  git -C "$d" add CHANGELOG.md .claude-plugin/plugin.json commands/status.md
  git -C "$d" commit -q -m "fix: v1.7.36 — baseline"
  printf '%s\n' "$d"
}

set_ver() {
  printf '{"name":"t","version":"%s"}\n' "$2" >"$1/.claude-plugin/plugin.json"
}

# make_repo_at VER — like make_repo, but the baseline commit carries VER
# instead of 1.7.36.
make_repo_at() {
  local ver="$1" d
  d=$(make_repo)
  set_ver "$d" "$ver"
  git -C "$d" add .claude-plugin/plugin.json
  git -C "$d" commit -q -m "fix: v$ver — baseline bump"
  printf '%s\n' "$d"
}

add_command() {
  printf '%s\n' '---' 'name: audit' 'description: x' '---' >"$1/commands/audit.md"
}

# make_rename_repo — baseline repo plus a committed skills/foo.md, with
# diff.renames=true set so the --no-renames flag has something to override.
make_rename_repo() {
  local d
  d=$(make_repo)
  mkdir -p "$d/skills"
  printf '%s\n' '# foo' >"$d/skills/foo.md"
  git -C "$d" add skills/foo.md
  git -C "$d" commit -q -m "chore: add skills/foo.md"
  git -C "$d" config diff.renames true
  printf '%s\n' "$d"
}

# usage
RC=0
OUT=$(bash "$CHECK" --nope 2>&1) && RC=0 || RC=$?
expect_rc 64 "unknown flag"
expect_contains "unknown flag"

NOT_GIT=$(mktemp -d "${TMPDIR:-/tmp}/bump-class-nogit-XXXXXX")
RC=0
OUT=$(cd "$NOT_GIT" && bash "$CHECK" 2>&1) && RC=0 || RC=$?
expect_rc 64 "not-a-git-repo"
rm -rf "$NOT_GIT"

# no new command + patch
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
printf '%s\n' '# existing edited' >"$REPO/commands/status.md"
run_in "$REPO"
expect_rc 0 "edit-existing + patch"

# new command + patch
set_ver "$REPO" "1.7.37"
add_command "$REPO"
run_in "$REPO"
expect_rc 1 "new command + patch"
expect_contains "commands/audit.md"
expect_contains "1.7.36 -> 1.7.37"
expect_contains "MUST NOT commit/tag/push"
rm -rf "$REPO"

# new command + minor
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "new command + minor"
rm -rf "$REPO"

# new command + major
REPO=$(make_repo)
set_ver "$REPO" "2.0.0"
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "new command + major"
rm -rf "$REPO"

# new command + unchanged version
REPO=$(make_repo)
add_command "$REPO"
run_in "$REPO"
expect_rc 1 "new command + none"
expect_contains "1.7.36 -> 1.7.36"
rm -rf "$REPO"

# --commit: committed patch + new command
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
add_command "$REPO"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
git -C "$REPO" commit -q -m "feat: v1.7.37 — /audit"
run_in "$REPO" --commit HEAD
expect_rc 1 "--commit new+patch"
rm -rf "$REPO"

# --commit: committed minor + new command
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
add_command "$REPO"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
git -C "$REPO" commit -q -m "feat: v1.8.0 — /audit"
run_in "$REPO" --commit HEAD
expect_rc 0 "--commit new+minor"
rm -rf "$REPO"

# --cached: staged new command, version not staged (still 1.7.36 on HEAD)
REPO=$(make_repo)
add_command "$REPO"
git -C "$REPO" add commands/audit.md
run_in "$REPO" --cached
expect_rc 1 "--cached new command, version unstaged"
rm -rf "$REPO"

# --cached: staged new command + minor version
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
add_command "$REPO"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
run_in "$REPO" --cached
expect_rc 0 "--cached new command + minor staged"
rm -rf "$REPO"

# --cached: index-vs-worktree divergence. plugin.json is staged UNCHANGED
# (still HEAD's baseline -- no bump in the index); only the worktree copy
# is bumped to minor, and that worktree edit is never staged. The commit
# this index would produce carries no real version bump, so this MUST
# violate (class "none"). A checker that fell back to reading the
# worktree file whenever plugin.json had no staged diff of its own would
# instead see the worktree's minor bump and wrongly pass -- a pre-commit
# hook bypass (the dev bumped the version in the editor but forgot
# `git add`). Confirmed against the pre-WP script (fbfe91d): that script
# returns 0 (wrongly "ok") on this exact fixture.
REPO=$(make_repo)
add_command "$REPO"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
set_ver "$REPO" "1.8.0"
run_in "$REPO" --cached
expect_rc 1 "--cached: plugin.json staged unchanged, worktree-only minor bump"
expect_contains "1.7.36 -> 1.7.36 (none)"
rm -rf "$REPO"

# Reverse: plugin.json genuinely staged at minor; the worktree is then
# edited back down to patch, unstaged. --cached must still see the staged
# minor bump -- the worktree-only downgrade MUST NOT flip this to a
# violation.
REPO=$(make_repo)
add_command "$REPO"
set_ver "$REPO" "1.8.0"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
set_ver "$REPO" "1.7.37"
run_in "$REPO" --cached
expect_rc 0 "--cached: staged minor bump, worktree-only patch downgrade"
rm -rf "$REPO"

# rename: skills/foo.md -> commands/foo.md, patch bump, each mode. The repo
# has diff.renames=true, so a clean detection would call it a rename (no
# new Surface). --no-renames must still see it as an added path.

# --commit mode
REPO=$(make_rename_repo)
git -C "$REPO" mv skills/foo.md commands/foo.md
set_ver "$REPO" "1.7.37"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "fix: v1.7.37 — rename foo"
run_in "$REPO" --commit HEAD
expect_rc 1 "rename --commit + patch (diff.renames=true)"
rm -rf "$REPO"

# --cached mode
REPO=$(make_rename_repo)
git -C "$REPO" mv skills/foo.md commands/foo.md
set_ver "$REPO" "1.7.37"
git -C "$REPO" add -A
run_in "$REPO" --cached
expect_rc 1 "rename --cached + patch (diff.renames=true)"
rm -rf "$REPO"

# --against HEAD (default/worktree mode)
REPO=$(make_rename_repo)
git -C "$REPO" mv skills/foo.md commands/foo.md
set_ver "$REPO" "1.7.37"
run_in "$REPO" --against HEAD
expect_rc 1 "rename --against HEAD + patch (diff.renames=true)"
rm -rf "$REPO"

# pre-release classification (SPEC-010 B2)

# release -> pre-release of the next minor core + new command → ok
REPO=$(make_repo_at "1.18.17")
set_ver "$REPO" "1.19.0-pre.1"
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "pre-release: 1.18.17 -> 1.19.0-pre.1 + new command"
rm -rf "$REPO"

# pre-release -> pre-release, same core → still the core's minor line → ok
REPO=$(make_repo_at "1.19.0-pre.1")
set_ver "$REPO" "1.19.0-pre.2"
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "pre-release: 1.19.0-pre.1 -> 1.19.0-pre.2 + new command"
rm -rf "$REPO"

# release -> pre-release of the next patch core + new command → violation
REPO=$(make_repo_at "1.18.17")
set_ver "$REPO" "1.18.18-pre.1"
add_command "$REPO"
run_in "$REPO"
expect_rc 1 "pre-release: 1.18.17 -> 1.18.18-pre.1 + new command (patch core)"
rm -rf "$REPO"

# release -> pre-release of the SAME core → invalid
REPO=$(make_repo_at "1.19.0")
set_ver "$REPO" "1.19.0-pre.1"
add_command "$REPO"
run_in "$REPO"
expect_rc 1 "pre-release: 1.19.0 -> 1.19.0-pre.1 (invalid, same core)"
expect_contains "(invalid)"
rm -rf "$REPO"

# nested commands/sub/y.md is not a top-level Surface
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
mkdir -p "$REPO/commands/sub"
printf '%s\n' '# nested' >"$REPO/commands/sub/y.md"
run_in "$REPO"
expect_rc 0 "nested commands/sub/y.md + patch — not a top-level surface"
rm -rf "$REPO"

# --range: two commits, first violates (new command + patch), second
# benign — proves --commit HEAD alone is blind to the earlier violation.
REPO=$(make_repo)
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
set_ver "$REPO" "1.7.37"
add_command "$REPO"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
git -C "$REPO" commit -q -m "fix: v1.7.37 — /audit (violation)"
FIRST_SHORT=$(git -C "$REPO" rev-parse --short HEAD)
printf '%s\n' '# tweak' >"$REPO/CHANGELOG.md"
git -C "$REPO" add CHANGELOG.md
git -C "$REPO" commit -q -m "chore: v1.7.37 — changelog tweak"

run_in "$REPO" --range "${BASE_SHA}..HEAD"
expect_rc 1 "--range covers the earlier violating commit"
expect_contains "$FIRST_SHORT"

run_in "$REPO" --commit HEAD
expect_rc 0 "--commit HEAD alone is blind to the earlier violation"

# a merge commit in the range is skipped, not treated as a failure itself
git -C "$REPO" checkout -qb side
printf '%s\n' 'x' >"$REPO/x.txt"
git -C "$REPO" add x.txt
git -C "$REPO" commit -q -m "chore: side"
git -C "$REPO" checkout -q master
git -C "$REPO" merge -q --no-ff side -m "merge: side"
run_in "$REPO" --range "${BASE_SHA}..HEAD"
expect_rc 1 "--range with a merge commit present still reports the real violation"

run_in "$REPO" --range "HEAD..HEAD"
expect_rc 0 "--range empty range"
expect_contains "empty range — ok"

run_in "$REPO" --range "foo"
expect_rc 64 "--range without .. is a usage error"

run_in "$REPO" --range "${BASE_SHA}..HEAD" --commit HEAD
expect_rc 64 "--range and --commit are mutually exclusive"

run_in "$REPO" --range "deadbeef..HEAD"
expect_rc 64 "--range with an unresolvable base"

rm -rf "$REPO"

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
