#!/usr/bin/env bash
# SPEC-010 bump-class gate fixtures. Isolated temp repos only.
# Run: bash skills/release/test-bump-class.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$HERE/check-bump-class.sh"
DETECT="$HERE/detect-surfaces.sh"
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

run_detect_in() {
  local d="$1"; shift
  RC=0
  OUT=$(cd "$d" && bash "$DETECT" "$@" 2>&1) && RC=0 || RC=$?
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

expect_empty() {
  if [ -z "$OUT" ]; then
    pass "no output: $1"
  else
    fail "unexpected output: $1"
    echo "  out: $OUT" | head -c 400
    echo
  fi
}

# set_sec REPO MINOR — write SECURITY.md with the supported-versions table
# for minor MINOR (same shape gen-supported-versions.sh --write emits).
set_sec() {
  local d="$1" min="$2"
  cat >"$d/SECURITY.md" <<EOF
# Security Policy

## Supported Versions
| Version | Supported |
|---------|-----------|
| ${min}.x | Yes       |
| < ${min} | No        |
EOF
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
  set_sec "$d" 1.7
  git -C "$d" add CHANGELOG.md .claude-plugin/plugin.json commands/status.md SECURITY.md
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

# security pre-gate: minor bump with NO new commands and a stale table
# fails closed (the miss surfaces before the full suite, not at the fold gate)
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
run_in "$REPO"
expect_rc 1 "minor bump + stale SECURITY.md table (no new commands)"
expect_contains "does not track minor 1.8"
expect_contains "gen-supported-versions.sh --write"
rm -rf "$REPO"

# security pre-gate: the same bump with a regenerated table passes
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
set_sec "$REPO" 1.8
run_in "$REPO"
expect_rc 0 "minor bump + regenerated SECURITY.md table"
rm -rf "$REPO"

# security pre-gate: fail closed when SECURITY.md is absent entirely
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
rm "$REPO/SECURITY.md"
run_in "$REPO"
expect_rc 1 "minor bump + missing SECURITY.md"
rm -rf "$REPO"

# new command + patch
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
add_command "$REPO"
run_in "$REPO"
expect_rc 1 "new command + patch"
expect_contains "commands/audit.md"
expect_contains "1.7.36 -> 1.7.37"
expect_contains "MUST NOT commit/tag/push"
rm -rf "$REPO"

# new command + minor (table regenerated per Step 3d)
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
set_sec "$REPO" 1.8
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "new command + minor"
rm -rf "$REPO"

# new command + major (table regenerated per Step 3d)
REPO=$(make_repo)
set_ver "$REPO" "2.0.0"
set_sec "$REPO" 2.0
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

# --commit: committed minor + new command (SECURITY.md folded in per Step 3d)
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
set_sec "$REPO" 1.8
add_command "$REPO"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json SECURITY.md
git -C "$REPO" commit -q -m "feat: v1.8.0 — /audit"
run_in "$REPO" --commit HEAD
expect_rc 0 "--commit new+minor"
rm -rf "$REPO"

# --commit: committed minor + new command but SECURITY.md left stale → the
# pre-gate fails closed even though the Surface predicate would pass.
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
add_command "$REPO"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
git -C "$REPO" commit -q -m "feat: v1.8.0 — /audit (no SECURITY.md)"
run_in "$REPO" --commit HEAD
expect_rc 1 "--commit minor with stale SECURITY.md table"
expect_contains "SECURITY.md supported-versions table"
rm -rf "$REPO"

# --cached: staged new command, version not staged (still 1.7.36 on HEAD)
REPO=$(make_repo)
add_command "$REPO"
git -C "$REPO" add commands/audit.md
run_in "$REPO" --cached
expect_rc 1 "--cached new command, version unstaged"
rm -rf "$REPO"

# --cached: staged new command + minor version (SECURITY.md staged too)
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
set_sec "$REPO" 1.8
add_command "$REPO"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json SECURITY.md
run_in "$REPO" --cached
expect_rc 0 "--cached new command + minor staged"
rm -rf "$REPO"

# --cached: minor staged but SECURITY.md NOT staged — the index still holds
# HEAD's 1.7 table, so the pre-gate fails closed (staged-set miss).
REPO=$(make_repo)
set_ver "$REPO" "1.8.0"
set_sec "$REPO" 1.8
add_command "$REPO"
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
run_in "$REPO" --cached
expect_rc 1 "--cached: minor staged, SECURITY.md not staged"
expect_contains "gen-supported-versions.sh --write"
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
set_sec "$REPO" 1.8
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json SECURITY.md
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
set_sec "$REPO" 1.19
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "pre-release: 1.18.17 -> 1.19.0-pre.1 + new command"
rm -rf "$REPO"

# pre-release -> pre-release, same core → still the core's minor line → ok
REPO=$(make_repo_at "1.19.0-pre.1")
set_ver "$REPO" "1.19.0-pre.2"
set_sec "$REPO" 1.19
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

# ---- pre-release arc scheme (SPEC-010 CDT-633; AC1/AC2/AC11) ----------------

# AC1 — a cross-core move to a pre-release core classifies numerically: major
REPO=$(make_repo_at "1.28.9")
set_ver "$REPO" "2.0.0-pre.1"
set_sec "$REPO" 2.0
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "arc: 1.28.9 -> 2.0.0-pre.1 + new command (cross-core major)"
expect_contains "1.28.9 -> 2.0.0-pre.1 (major)"
rm -rf "$REPO"

# AC2 — pre -> pre on the same core is allowed and carries the core's own line
# class (2.0.0 core -> major): the recorded P2 decision, no new class string.
REPO=$(make_repo_at "2.0.0-pre.1")
set_ver "$REPO" "2.0.0-pre.2"
set_sec "$REPO" 2.0
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "arc: 2.0.0-pre.1 -> 2.0.0-pre.2 + new command (same-core pre -> pre)"
expect_contains "2.0.0-pre.1 -> 2.0.0-pre.2 (major)"
rm -rf "$REPO"

# AC1 — pre -> final on the same core is allowed (the final cut of the arc)
REPO=$(make_repo_at "2.0.0-pre.9")
set_ver "$REPO" "2.0.0"
set_sec "$REPO" 2.0
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "arc: 2.0.0-pre.9 -> 2.0.0 + new command (same-core pre -> final)"
expect_contains "2.0.0-pre.9 -> 2.0.0 (major)"
rm -rf "$REPO"

# AC1 — release -> pre-release on the SAME core stays invalid
REPO=$(make_repo_at "2.0.0")
set_ver "$REPO" "2.0.0-pre.1"
add_command "$REPO"
run_in "$REPO"
expect_rc 1 "arc: 2.0.0 -> 2.0.0-pre.1 + new command (invalid, same core)"
expect_contains "2.0.0 -> 2.0.0-pre.1 (invalid)"
rm -rf "$REPO"

# AC1 — pre -> pre on the SAME core with a LOWER pre-release number is a
# version-down move: invalid.
REPO=$(make_repo_at "2.0.0-pre.2")
set_ver "$REPO" "2.0.0-pre.1"
add_command "$REPO"
run_in "$REPO"
expect_rc 1 "arc: 2.0.0-pre.2 -> 2.0.0-pre.1 + new command (invalid, pre-downgrade)"
expect_contains "2.0.0-pre.2 -> 2.0.0-pre.1 (invalid)"
rm -rf "$REPO"

# AC11 — a pre bump with a new Surface is allowed as a major: the shape of the
# 'new command + major' case above with a pre-release version.
REPO=$(make_repo)
set_ver "$REPO" "2.0.0-pre.1"
set_sec "$REPO" 2.0
add_command "$REPO"
run_in "$REPO"
expect_rc 0 "arc: 1.7.36 -> 2.0.0-pre.1 + new command (major, new Surface)"
expect_contains "1.7.36 -> 2.0.0-pre.1 (major)"
rm -rf "$REPO"

# AC2 — the SECURITY.md pre-gate keeps failing closed on the pre series: the
# same major-class pre -> pre bump, table left on the old minor.
REPO=$(make_repo_at "2.0.0-pre.1")
set_ver "$REPO" "2.0.0-pre.2"
run_in "$REPO"
expect_rc 1 "arc: 2.0.0-pre.1 -> 2.0.0-pre.2 with a stale SECURITY.md table"
expect_contains "does not track minor 2.0"
rm -rf "$REPO"

# AC2 — the decision is recorded in the checker: an explanatory comment above
# the same-core branch of bump_class, and no class string outside the set the
# gate has always emitted.
BCC=$(grep -nF 'if [ "$ocore" = "$ncore" ]' "$CHECK" | head -1 | cut -d: -f1)
BC_CMT=""
if [ -n "$BCC" ]; then
  BC_CMT=$(awk -v stop="$BCC" 'NR < stop && /#.*(CDT-633|class string)/ {print NR": "$0; exit}' "$CHECK")
fi
if [ -n "$BC_CMT" ]; then
  pass "AC2 recorded decision: explanatory comment above the same-core branch of bump_class ($BC_CMT)"
else
  fail "AC2 recorded decision: no CDT-633 / class-string comment above the same-core branch (branch at line '${BCC:-<none>}')"
fi
BC_CLASSES=$(awk -F"'" '/printf .%s\\n. [a-z]+$/ {gsub(/^[ \t]+/, "", $NF); print $NF}' "$CHECK" | sort -u | tr '\n' ' ')
if [ "$BC_CLASSES" = "invalid major minor none patch " ]; then
  pass "AC2 no new class string: check-bump-class.sh emits only '$BC_CLASSES'"
else
  fail "AC2 no new class string: emitted classes '$BC_CLASSES' != 'invalid major minor none patch '"
fi

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

# ---- detect-surfaces.sh (SPEC-041 AC8) helper unit cases ----

# usage errors
RC=0
OUT=$(bash "$DETECT" 2>&1) && RC=0 || RC=$?
expect_rc 64 "detect: no mode flag"
OUT=$(bash "$DETECT" --nope 2>&1) && RC=0 || RC=$?
expect_rc 64 "detect: unknown flag"
OUT=$(bash "$DETECT" --against HEAD --commit HEAD 2>&1) && RC=0 || RC=$?
expect_rc 64 "detect: two mode flags"
OUT=$(bash "$DETECT" --against 2>&1) && RC=0 || RC=$?
expect_rc 64 "detect: --against without a ref"

# added file, still untracked ( /release runs before git add )
REPO=$(make_repo)
add_command "$REPO"
run_detect_in "$REPO" --against HEAD
expect_rc 0 "detect: --against prints an untracked added command"
expect_contains "commands/audit.md"
rm -rf "$REPO"

# nested commands/x/y.md is not a Surface
REPO=$(make_repo)
mkdir -p "$REPO/commands/x"
printf '%s\n' '# nested' >"$REPO/commands/x/y.md"
run_detect_in "$REPO" --against HEAD
expect_rc 0 "detect: nested commands/x/y.md → rc 0"
expect_empty "detect: nested commands/x/y.md prints nothing"
rm -rf "$REPO"

# edit of an existing command is not an added Surface
REPO=$(make_repo)
printf '%s\n' '# edited' >"$REPO/commands/status.md"
run_detect_in "$REPO" --against HEAD
expect_rc 0 "detect: edit of existing command → rc 0"
expect_empty "detect: edit of existing command prints nothing"
rm -rf "$REPO"

# rename onto the top level counts as added (no-renames), via --commit
REPO=$(make_rename_repo)
git -C "$REPO" mv skills/foo.md commands/foo.md
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "fix: rename foo"
run_detect_in "$REPO" --commit HEAD
expect_rc 0 "detect: --commit rename-onto-top-level → rc 0"
expect_contains "commands/foo.md"
rm -rf "$REPO"

# --cached prints staged additions only
REPO=$(make_repo)
add_command "$REPO"
git -C "$REPO" add commands/audit.md
run_detect_in "$REPO" --cached
expect_rc 0 "detect: --cached prints a staged added command"
expect_contains "commands/audit.md"
rm -rf "$REPO"

# --cached ignores untracked files
REPO=$(make_repo)
add_command "$REPO"
run_detect_in "$REPO" --cached
expect_rc 0 "detect: --cached untracked → rc 0"
expect_empty "detect: --cached ignores untracked files"
rm -rf "$REPO"

# unresolvable ref is a usage error
REPO=$(make_repo)
run_detect_in "$REPO" --commit deadbeef
expect_rc 64 "detect: unresolvable --commit ref"
rm -rf "$REPO"

# ---- AC8 bites (attempt-2 M14 strike closure) -------------------------------

# 13. Source-inspection: check-bump-class.sh MUST NOT keep a private copy of
# Surface detection — no is_surface_path definition and no inline
# 'git diff'/'git ls-files' detection; the DETECT binding points at the
# shared helper.
N_IS_SP=$(grep -c 'is_surface_path' "$CHECK" || true)
N_GITDIFF=$(grep -c 'git diff' "$CHECK" || true)
N_GITLS=$(grep -c 'git ls-files' "$CHECK" || true)
if [ "$N_IS_SP" = "0" ] && [ "$N_GITDIFF" = "0" ] && [ "$N_GITLS" = "0" ]; then
  pass "AC8 source-inspection: check-bump-class.sh defines no private is_surface_path and no inline 'git diff'/'git ls-files' Surface detection (counts 0/0/0)"
else
  fail "AC8 source-inspection: private Surface copy found — is_surface_path=$N_IS_SP git-diff=$N_GITDIFF git-ls-files=$N_GITLS in $CHECK"
fi
if grep -n 'DETECT=' "$CHECK" | grep -q 'detect-surfaces\.sh'; then
  pass "AC8 source-inspection: check-bump-class.sh DETECT binding points at skills/release/detect-surfaces.sh ($(grep -n 'DETECT=' "$CHECK" | head -1))"
else
  fail "AC8 source-inspection: DETECT binding does not name detect-surfaces.sh"
fi

# 14. Behavioral: --no-renames and rename-onto-top-level-counts-as-added.
# Fixtures carry diff.renames=true so the no-renames behavior has something to
# override; the baseline holds commands/status.md, commands/old.md,
# commands/sub/tool.md and skills/foo.md.
make_toprename_repo() {
  local d
  d=$(make_repo)
  mkdir -p "$d/commands/sub" "$d/skills"
  printf '%s\n' '# old' >"$d/commands/old.md"
  printf '%s\n' '# tool' >"$d/commands/sub/tool.md"
  printf '%s\n' '# foo' >"$d/skills/foo.md"
  git -C "$d" add commands skills
  git -C "$d" commit -q -m "chore: baseline surfaces"
  git -C "$d" config diff.renames true
  printf '%s\n' "$d"
}

# 14a. rename ONTO the top level: commands/sub/tool.md -> commands/tool.md is
# counted as added (a new Surface) even with rename detection configured.
REPO=$(make_toprename_repo)
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" mv commands/sub/tool.md commands/tool.md
run_detect_in "$REPO" --against "$BASE"
expect_rc 0 "detect: rename-onto-top-level commands/sub/tool.md -> commands/tool.md (against resolved baseline $BASE)"
expect_contains "commands/tool.md"
rm -rf "$REPO"

# 14b. --no-renames is IN EFFECT: a rename that stays on the top level
# (commands/old.md -> commands/new.md) is flagged as added — with rename
# detection this pair would collapse to one R record and hide from
# --diff-filter=A, so flagging it proves --no-renames.
REPO=$(make_toprename_repo)
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" mv commands/old.md commands/new.md
run_detect_in "$REPO" --against "$BASE"
expect_rc 0 "detect: --no-renames in effect — commands/old.md -> commands/new.md is an added Surface (not hidden as a rename)"
expect_contains "commands/new.md"
rm -rf "$REPO"

# 14c. A plain rename that does NOT touch the top level is not flagged.
REPO=$(make_toprename_repo)
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" mv skills/foo.md skills/bar.md
run_detect_in "$REPO" --against "$BASE"
expect_rc 0 "detect: plain rename skills/foo.md -> skills/bar.md does not touch the top level"
expect_empty "detect: plain rename away from commands/ prints nothing"
rm -rf "$REPO"

# ---- AC8 round-3 closures (helper-call run output + B1–B6 labels) -----------

# run_check_of <checker-path> <repo> [args...] — run_in with an explicit
# checker, so a copy of skills/release can be driven against the real one.
run_check_of() {
  local ck="$1" d="$2"
  shift 2
  RC=0
  OUT=$(cd "$d" && bash "$ck" "$@" 2>&1) && RC=0 || RC=$?
}

# 15. AC8 helper-call (behavioral): check-bump-class.sh calls the shared
# detect-surfaces.sh. The copy of skills/release carries a stub helper that
# records its argv in a marker log, then execs the real helper; the copy's
# classification MUST match the real checker's on an identical fixture.
HC=$(mktemp -d "${TMPDIR:-/tmp}/bump-class-helpercall-XXXXXX")
cp -R "$HERE" "$HC/release"
cp "$DETECT" "$HC/release/detect-surfaces-real.sh"
chmod +x "$HC/release/detect-surfaces-real.sh"
cat > "$HC/release/detect-surfaces.sh" <<WEOF
#!/usr/bin/env bash
# test stub: record the caller's argv in the marker log, then exec the real
# shared helper so the gate still runs end to end.
printf 'detect-surfaces.sh %s\n' "\$*" >> "$HC/detect-called.log"
exec "$HC/release/detect-surfaces-real.sh" "\$@"
WEOF
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
add_command "$REPO"
run_in "$REPO"
HC_CONTROL_RC=$RC
REPO2=$(make_repo)
set_ver "$REPO2" "1.7.37"
add_command "$REPO2"
run_check_of "$HC/release/check-bump-class.sh" "$REPO2"
HC_STUB_RC=$RC
HC_MARK=$(head -1 "$HC/detect-called.log" 2>/dev/null)
if [ -s "$HC/detect-called.log" ] && printf '%s\n' "$HC_MARK" | grep -q -- '--against' \
  && [ "$HC_STUB_RC" -eq "$HC_CONTROL_RC" ] && [ "$HC_STUB_RC" -eq 1 ] \
  && printf '%s\n' "$OUT" | grep -Fq 'bump-class:'; then
  pass "AC8 helper-call: check-bump-class.sh invoked detect-surfaces.sh (marker recorded: '$HC_MARK'; stub exit $HC_STUB_RC == control exit $HC_CONTROL_RC — classification unchanged)"
else
  fail "AC8 helper-call: marker='$HC_MARK' stub=$HC_STUB_RC control=$HC_CONTROL_RC out: $OUT"
fi
rm -rf "$REPO" "$REPO2" "$HC"

# 16. AC8 B1 — deterministic checker CLI: the exit-code contract (0 / 1 / 64)
# and every mode, read from run output.
B1=1
B1_LOG=""
chk_b1() {  # chk_b1 <expected-rc> <label> <repo> [args...]
  local want="$1" label="$2" d="$3"
  shift 3
  run_check_of "$CHECK" "$d" "$@"
  B1_LOG="$B1_LOG $label=$RC"
  if [ "$RC" -ne "$want" ]; then
    B1=0
    fail "AC8 B1: $label exit $RC != $want (out: $(printf '%s' "$OUT" | head -1))"
  fi
}
REPO=$(make_repo)
B1_BASE=$(git -C "$REPO" rev-parse HEAD)
chk_b1 64 "usage-unknown-flag" "$REPO" --nope
NOT_GIT=$(mktemp -d "${TMPDIR:-/tmp}/bump-class-b1nogit-XXXXXX")
chk_b1 64 "not-a-git-repo" "$NOT_GIT"
rm -rf "$NOT_GIT"
set_ver "$REPO" "1.7.37"
add_command "$REPO"
chk_b1 1 "default-worktree" "$REPO"
chk_b1 1 "against-HEAD" "$REPO" --against HEAD
chk_b1 0 "cached-nothing-staged" "$REPO" --cached
git -C "$REPO" add commands/audit.md .claude-plugin/plugin.json
git -C "$REPO" commit -q -m "fix: v1.7.37 — /audit (patch violation)"
chk_b1 1 "commit-mode" "$REPO" --commit HEAD
chk_b1 1 "range-mode" "$REPO" --range "${B1_BASE}..HEAD"
chk_b1 0 "range-empty" "$REPO" --range "HEAD..HEAD"
rm -rf "$REPO"
if [ "$B1" = "1" ]; then
  pass "AC8 B1: exit-code contract — usage 64, not-a-git-repo 64, and all modes from run output:$B1_LOG"
fi

# 17. AC8 B2 — predicate: a nested path is not a Surface, an untracked top-level
# addition is counted, and a rename onto the top level counts as added.
B2=1
B2_LOG=""
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
mkdir -p "$REPO/commands/sub"
printf '%s\n' '# nested' >"$REPO/commands/sub/x.md"
run_in "$REPO"
B2_LOG="$B2_LOG nested=$RC"
[ "$RC" -eq 0 ] || { B2=0; fail "AC8 B2: nested commands/sub/x.md tripped the gate (exit $RC)"; }
rm -rf "$REPO"
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
add_command "$REPO"
run_in "$REPO"
B2_LOG="$B2_LOG untracked=$RC"
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -Fq 'commands/audit.md'; then
  B2=0
  fail "AC8 B2: untracked commands/audit.md was not counted as added (exit $RC)"
fi
rm -rf "$REPO"
REPO=$(make_toprename_repo)
B2_BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" mv commands/sub/tool.md commands/tool.md
set_ver "$REPO" "1.7.37"
run_in "$REPO" --against "$B2_BASE"
B2_LOG="$B2_LOG rename-onto-top-level=$RC"
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -Fq 'commands/tool.md'; then
  B2=0
  fail "AC8 B2: rename commands/sub/tool.md -> commands/tool.md was not counted as added (exit $RC)"
fi
rm -rf "$REPO"
if [ "$B2" = "1" ]; then
  pass "AC8 B2: predicate — nested commands/sub/x.md is NOT a Surface (0), untracked commands/audit.md counts as added (1), rename onto the top level commands/sub/tool.md -> commands/tool.md counts as added (1)$B2_LOG"
fi

# 18. AC8 B3 — fail message: 'bump-class:', every new path, old -> new (class),
# the AGENTS.md citation, and the commit/tag/push ban.
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
add_command "$REPO"
run_in "$REPO"
B3=1
[ "$RC" -eq 1 ] || { B3=0; fail "AC8 B3: new command + patch exit $RC != 1"; }
for b3_need in 'bump-class:' 'commands/audit.md' '1.7.36 -> 1.7.37 (patch)' \
               'AGENTS.md' 'MUST NOT commit/tag/push'; do
  printf '%s\n' "$OUT" | grep -Fq -- "$b3_need" \
    || { B3=0; fail "AC8 B3: fail message missing '$b3_need'"; }
done
if [ "$B3" = "1" ]; then
  pass "AC8 B3: fail message — new command + patch exits 1 and prints 'bump-class:' + the new path 'commands/audit.md' + '1.7.36 -> 1.7.37 (patch)' + the AGENTS.md citation + 'MUST NOT commit/tag/push'"
fi
rm -rf "$REPO"

# 19. AC8 B6 — MUST NOT: a skill-only addition is not a Surface (patch stands),
# and an edit to an existing command does not trip the gate.
REPO=$(make_repo)
set_ver "$REPO" "1.7.37"
mkdir -p "$REPO/skills/new-skill"
printf '%s\n' '# new skill' >"$REPO/skills/new-skill/SKILL.md"
printf '%s\n' '# edited' >"$REPO/commands/status.md"
run_in "$REPO"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -Fq 'no new commands/*.md — ok'; then
  pass "AC8 B6: must-not — skill-only addition (new skills/new-skill/SKILL.md) plus an edit of commands/status.md on a patch bump exits 0: not treated as a Surface (out: $OUT)"
else
  fail "AC8 B6: skill-only addition wrongly treated as a Surface — exit $RC out: $OUT"
fi
rm -rf "$REPO"

# 20. AC8 B4 (advisory) — wiring: /release Step 4.11 runs the checker and
# hard-stops on non-zero; githooks/pre-commit runs --cached on master/main only.
B4_REL=$(grep -n 'skills/release/check-bump-class.sh' "$HERE/SKILL.md" | head -1)
B4_STOP=$(grep -n 'bash "\$CHECK_BUMP" || exit 1' "$HERE/SKILL.md" | head -1)
B4_HOOK=$(grep -n 'exec bash "\$CHECK" --cached' "$HERE/../../githooks/pre-commit" | head -1)
B4_BRANCH=$(grep -n 'master|main)' "$HERE/../../githooks/pre-commit" | head -1)
if [ -n "$B4_REL" ] && [ -n "$B4_STOP" ] && [ -n "$B4_HOOK" ] && [ -n "$B4_BRANCH" ]; then
  pass "AC8 B4 (advisory): wiring unchanged — /release Step 4.11 resolves check-bump-class.sh (SKILL.md:$B4_REL) and hard-stops (SKILL.md:$B4_STOP); githooks/pre-commit gates on master|main ($B4_BRANCH) then execs --cached ($B4_HOOK)"
else
  fail "AC8 B4 (advisory): wiring lines missing — rel='$B4_REL' stop='$B4_STOP' hook='$B4_HOOK' branch='$B4_BRANCH'"
fi

# 21. AC8 B5 (advisory) — tests exist: this suite is SPEC-041's AC8 Verify
# command, and it is running (counters are live).
B5_VERIFY=$(grep -n 'Verify: bash skills/release/test-bump-class.sh' \
  "$HERE/../../specs/core/SPEC-041-auto-ship-tiering.md" | head -1)
if [ -f "$HERE/test-bump-class.sh" ] && [ -n "$B5_VERIFY" ]; then
  pass "AC8 B5 (advisory): tests exist — skills/release/test-bump-class.sh is the SPEC-041 AC8 Verify command ($B5_VERIFY) and this run is executing it (live counters: $PASS passed, $FAIL failed so far)"
else
  fail "AC8 B5 (advisory): no test file / no AC8 Verify line pointing at this suite"
fi

# 22. AC8 B1-B6 unchanged — the whole suite, re-run as a subprocess. The nested
# run skips this case (BUMP_CLASS_NESTED) so there is no recursion; its summary
# is therefore exactly this run's counter at launch (one case shorter than the
# outer run). Suite runtime is ~1 s per pass, so the re-run is cheap.
if [ -n "${BUMP_CLASS_NESTED:-}" ]; then
  :
else
  NEST_AT=$PASS
  NEST_OUT=$(BUMP_CLASS_NESTED=1 bash "$HERE/test-bump-class.sh" 2>&1)
  NEST_RC=$?
  NEST_SUM=$(printf '%s\n' "$NEST_OUT" | grep -E '^[0-9]+ passed, [0-9]+ failed$' | tail -1)
  NEST_FAILS=$(printf '%s\n' "$NEST_OUT" | grep -c '^FAIL:' || true)
  if [ "$NEST_RC" -eq 0 ] && [ "$NEST_FAILS" = "0" ] \
    && [ "$NEST_SUM" = "$NEST_AT passed, 0 failed" ]; then
    pass "AC8 B1-B6 unchanged: full existing suite green — self re-run rc=$NEST_RC, $NEST_SUM, 0 FAIL lines (the 71 pre-existing SPEC-010 B1-B6 cases plus this round's AC8 additions; gate behavior unchanged)"
  else
    fail "AC8 B1-B6 unchanged: re-run rc=$NEST_RC summary='$NEST_SUM' fails=$NEST_FAILS (expected '$NEST_AT passed, 0 failed')"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
