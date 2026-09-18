#!/usr/bin/env bash
# SPEC-010 bump-class gate fixtures. Isolated temp repos only.
# Run: bash skills/release/test-bump-class.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$HERE/check-bump-class.sh"
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
printf '%s\n' '---\nname: audit\ndescription: x\n---\n' >"$REPO/commands/audit.md"
run_in "$REPO"
expect_rc 1 "new command + patch"
expect_contains "commands/audit.md"
expect_contains "1.7.36 -> 1.7.37"
expect_contains "MUST NOT commit/tag/push"
rm -rf "$REPO"

# new command + minor
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
printf '%s\n' '---\nname: audit\ndescription: x\n---\n' >"$REPO/commands/audit.md"
run_in "$REPO"
expect_rc 0 "new command + minor"
rm -rf "$REPO"

# new command + major
REPO=$(make_repo)
set_ver "$REPO" "2.0.0"
printf '%s\n' '---\nname: audit\ndescription: x\n---\n' >"$REPO/commands/audit.md"
run_in "$REPO"
expect_rc 0 "new command + major"
rm -rf "$REPO"

# new command + unchanged version
REPO=$(make_repo)
printf '%s\n' '---\nname: audit\ndescription: x\n---\n' >"$REPO/commands/audit.md"
run_in "$REPO"
expect_rc 1 "new command + none"
expect_contains "1.7.36 -> 1.7.36"
rm -rf "$REPO"

# --commit: committed patch + new command
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
printf '%s\n' '---\nname: audit\ndescription: x\n---\n' >"$REPO/commands/audit.md"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
git -C "$REPO" commit -q -m "feat: v1.7.37 — /audit"
run_in "$REPO" --commit HEAD
expect_rc 1 "--commit new+patch"
rm -rf "$REPO"

# --commit: committed minor + new command
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
printf '%s\n' '---\nname: audit\ndescription: x\n---\n' >"$REPO/commands/audit.md"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
git -C "$REPO" commit -q -m "feat: v1.8.0 — /audit"
run_in "$REPO" --commit HEAD
expect_rc 0 "--commit new+minor"
rm -rf "$REPO"

# --cached: staged new command, version not staged (still 1.7.36 on HEAD)
REPO=$(make_repo)
printf '%s\n' '---\nname: audit\ndescription: x\n---\n' >"$REPO/commands/audit.md"
git -C "$REPO" add commands/audit.md
run_in "$REPO" --cached
expect_rc 1 "--cached new command, version unstaged"
rm -rf "$REPO"

# --cached: staged new command + minor version
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
printf '%s\n' '---\nname: audit\ndescription: x\n---\n' >"$REPO/commands/audit.md"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
run_in "$REPO" --cached
expect_rc 0 "--cached new command + minor staged"
rm -rf "$REPO"

write_skill() {
  local d="$1" name="$2"
  shift 2
  mkdir -p "$d/skills/$name"
  printf '%s\n' "$@" >"$d/skills/$name/SKILL.md"
}

# new flagged skill + patch (B2/B6 — user-invocable: false stays patch-eligible)
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
write_skill "$REPO" engine \
  '---' 'name: engine' 'description: x' 'user-invocable: false' '---'
run_in "$REPO"
expect_rc 0 "new flagged skill + patch"
rm -rf "$REPO"

# large flagged skill + patch (pipefail SIGPIPE on early return)
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
mkdir -p "$REPO/skills/engine"
{
  printf '%s\n' '---' 'name: engine' 'description: |' '  protocol body' 'user-invocable: false' '---'
  i=0
  while [ "$i" -lt 4000 ]; do
    printf 'padding line %s for large flagged skill\n' "$i"
    i=$((i + 1))
  done
} >"$REPO/skills/engine/SKILL.md"
run_in "$REPO"
expect_rc 0 "new large flagged skill + patch"
rm -rf "$REPO"

# new unflagged skill + patch (B2 — lacks user-invocable: false)
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
write_skill "$REPO" shiny \
  '---' 'name: shiny' 'description: x' '---'
run_in "$REPO"
expect_rc 1 "new unflagged skill + patch"
expect_contains "skills/shiny/SKILL.md"
expect_contains "1.7.36 -> 1.7.37"
expect_contains "MUST NOT commit/tag/push"
rm -rf "$REPO"

# new unflagged skill + minor
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
write_skill "$REPO" shiny \
  '---' 'name: shiny' 'description: x' '---'
run_in "$REPO"
expect_rc 0 "new unflagged skill + minor"
rm -rf "$REPO"

# missing frontmatter = unflagged
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
write_skill "$REPO" raw '# no yaml'
run_in "$REPO"
expect_rc 1 "new skill missing frontmatter + patch"
expect_contains "skills/raw/SKILL.md"
rm -rf "$REPO"

# whitespace-tolerant flag (quoted false, extra spaces)
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
write_skill "$REPO" engine \
  '---' 'name: engine' 'description: x' '  user-invocable:  "false"  ' '---'
run_in "$REPO"
expect_rc 0 "new flagged skill whitespace/quotes + patch"
rm -rf "$REPO"

# --commit: unflagged skill + patch
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
write_skill "$REPO" shiny \
  '---' 'name: shiny' 'description: x' '---'
git -C "$REPO" add skills/shiny/SKILL.md .claude-plugin/plugin.json
git -C "$REPO" commit -q -m "feat: v1.7.37 — shiny skill"
run_in "$REPO" --commit HEAD
expect_rc 1 "--commit unflagged skill + patch"
rm -rf "$REPO"

# --cached: flagged skill + patch staged
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
write_skill "$REPO" engine \
  '---' 'name: engine' 'description: x' 'user-invocable: false' '---'
git -C "$REPO" add skills/engine/SKILL.md .claude-plugin/plugin.json
run_in "$REPO" --cached
expect_rc 0 "--cached flagged skill + patch"
rm -rf "$REPO"

# thin command door over a skill already on the baseline + patch
REPO=$(make_repo)
write_skill "$REPO" orchestrate \
  '---' 'name: orchestrate' 'description: x' '---'
git -C "$REPO" add skills/orchestrate/SKILL.md
git -C "$REPO" commit -q -m "skill exists on baseline"
set_ver "$REPO" "1.7.37"
printf '%s\n' '---' 'name: orchestrate' 'description: x' '---' \
  >"$REPO/commands/orchestrate.md"
run_in "$REPO"
expect_rc 0 "wrap existing skill + patch"
rm -rf "$REPO"

# wrap existing skill + unchanged version (not a Surface)
REPO=$(make_repo)
write_skill "$REPO" orchestrate \
  '---' 'name: orchestrate' 'description: x' '---'
git -C "$REPO" add skills/orchestrate/SKILL.md
git -C "$REPO" commit -q -m "skill exists on baseline"
printf '%s\n' '---' 'name: orchestrate' 'description: x' '---' \
  >"$REPO/commands/orchestrate.md"
run_in "$REPO"
expect_rc 0 "wrap existing skill + none"
rm -rf "$REPO"

# --commit: wrap existing skill + patch
REPO=$(make_repo)
write_skill "$REPO" orchestrate \
  '---' 'name: orchestrate' 'description: x' '---'
git -C "$REPO" add skills/orchestrate/SKILL.md
git -C "$REPO" commit -q -m "skill exists on baseline"
set_ver "$REPO" "1.7.37"
printf '%s\n' '---' 'name: orchestrate' 'description: x' '---' \
  >"$REPO/commands/orchestrate.md"
git -C "$REPO" add commands/orchestrate.md .claude-plugin/plugin.json
git -C "$REPO" commit -q -m "fix: v1.7.37 — wrap orchestrate"
run_in "$REPO" --commit HEAD
expect_rc 0 "--commit wrap existing skill + patch"
rm -rf "$REPO"

# --cached: wrap existing skill + patch staged
REPO=$(make_repo)
write_skill "$REPO" orchestrate \
  '---' 'name: orchestrate' 'description: x' '---'
git -C "$REPO" add skills/orchestrate/SKILL.md
git -C "$REPO" commit -q -m "skill exists on baseline"
set_ver "$REPO" "1.7.37"
printf '%s\n' '---' 'name: orchestrate' 'description: x' '---' \
  >"$REPO/commands/orchestrate.md"
git -C "$REPO" add commands/orchestrate.md .claude-plugin/plugin.json
run_in "$REPO" --cached
expect_rc 0 "--cached wrap existing skill + patch"
rm -rf "$REPO"

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
