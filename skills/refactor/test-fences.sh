#!/usr/bin/env bash
# skills/refactor/test-fences.sh — SPEC-015 / SPEC-030 R23+ (CDT-356 [10 F10]).
# Runs the Step 1b bash fences of skills/refactor/SKILL.md, extracted with
# tests/lib/fence.sh, in fresh shells inside a fixture git repo.
#
#   Step 1b (b)  the affected-path guard before `git log`
#   Step 1b (c)  the same guard before the test-file scan
#
# A relative path is relative to the worktree root and must be kept. An
# out-of-tree path, a path that shares only the root's name prefix, a `..` path
# and an empty path must be rejected, and `git log` must never see an empty
# pathspec (`fatal: empty string is not a valid pathspec`).
#
# The suite proves that it bites: the same relative-path case, run on the
# Step 1b text of v1.18.32 (fixtures/step1b-before.md), makes git fatal.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh). SKILL_MD may name
# another revision of SKILL.md; default is this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="${SKILL_MD:-$ROOT/skills/refactor/SKILL.md}"
OLD_MD="$ROOT/skills/refactor/fixtures/step1b-before.md"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
hermetic_init

pass=0
fail=0

WORK="$HERMETIC_ROOT/work"
REPO="$WORK/repo"
SIBLING="$WORK/repo-evil"
OUTSIDE="$WORK/elsewhere"
mkdir -p "$REPO/src" "$REPO/docs" "$SIBLING" "$OUTSIDE"

# ---- fixture repo: src/a.txt with two commits, a test file beside it -------
git -C "$REPO" init -q . || { echo "FAIL: git init"; exit 1; }
printf 'one\n' > "$REPO/src/a.txt"
printf 'package src\n' > "$REPO/src/foo_test.go"
printf 'package docs\n' > "$REPO/docs/bar_test.go"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "add a" || { echo "FAIL: first commit"; exit 1; }
printf 'two\n' >> "$REPO/src/a.txt"
git -C "$REPO" commit -q -am "touch a" || { echo "FAIL: second commit"; exit 1; }
printf 'x\n' > "$SIBLING/a.txt"
printf 'x\n' > "$OUTSIDE/evil_test.txt"

# ---- extract a fence by content --------------------------------------------
# pick_fence <md> <needle> — the first bash fence under "## Step 1b" that holds <needle>
pick_fence() {
  local md="$1" needle="$2" n=1 text
  while [ "$n" -le 12 ]; do
    text="$(fence_nth "$md" "## Step 1b" "$n")" || return 1
    case "$text" in *"$needle"*) printf '%s\n' "$text"; return 0 ;; esac
    n=$((n + 1))
  done
  return 1
}

# run_fence <fence-text> <raw-path> <out-prefix> [<cwd>] — substitute the placeholder, run in
# a fresh bash with cwd = the fixture repo root (or <cwd>). Sets RUN_RC (fence_exec); stdout and stderr
# land in <out-prefix>.out and <out-prefix>.err.
run_fence() {
  local text="$1" val="$2" prefix="$3" cwd="${4:-$REPO}"
  text="${text//<affected-path>/$val}"
  fence_exec "$prefix" "$cwd" "$text"
}

outs() { cat "$1.out"; }
errs() { cat "$1.err"; }
no_fatal() { ! grep -q 'fatal' "$1.err"; }

GITLOG_FENCE="$(pick_fence "$SKILL_MD" 'git log --oneline')" || GITLOG_FENCE=""
FIND_FENCE="$(pick_fence "$SKILL_MD" 'Could not identify affected path — skip test scan')" || FIND_FENCE=""
OLD_GITLOG_FENCE="$(pick_fence "$OLD_MD" 'git log --oneline')" || OLD_GITLOG_FENCE=""
OLD_FIND_FENCE="$(pick_fence "$OLD_MD" 'Could not identify affected path — skip test scan')" || OLD_FIND_FENCE=""
for pair in "git log fence:$GITLOG_FENCE" "test scan fence:$FIND_FENCE" "old git log fence:$OLD_GITLOG_FENCE" "old test scan fence:$OLD_FIND_FENCE"; do
  if [ -n "${pair#*:}" ]; then pass_line "structural: ${pair%%:*} extracted"
  else fail_line "structural: ${pair%%:*} extracted (zero fences)"; fi
done

# ---- (b) the git log fence --------------------------------------------------
# A relative path is kept: git log lists the two commits of src/a.txt, rc 0, no fatal.
run_fence "$GITLOG_FENCE" 'src/a.txt' "$WORK/b-rel"
check "(b) relative path: fence exits 0" test "$RUN_RC" -eq 0
check "(b) relative path: git log lists the commit that touched the file" grep -q 'touch a' "$WORK/b-rel.out"
check "(b) relative path: git log lists the older commit too" grep -q 'add a' "$WORK/b-rel.out"
check "(b) relative path: no git fatal" no_fatal "$WORK/b-rel"

# An absolute path inside the tree is kept as well.
run_fence "$GITLOG_FENCE" "$REPO/src/a.txt" "$WORK/b-abs"
check "(b) in-tree absolute path: git log lists the commit" grep -q 'touch a' "$WORK/b-abs.out"
check "(b) in-tree absolute path: no git fatal" no_fatal "$WORK/b-abs"

# Out-of-tree: rejected, git log is skipped, no fatal, the fence still exits 0.
run_fence "$GITLOG_FENCE" "$OUTSIDE/evil_test.txt" "$WORK/b-out"
check "(b) out-of-tree path: fence exits 0" test "$RUN_RC" -eq 0
check "(b) out-of-tree path: git log is skipped (no commit line)" bash -c '! grep -q "touch a" "$1.out"' _ "$WORK/b-out"
check "(b) out-of-tree path: says git log was skipped" grep -q 'git log skipped' "$WORK/b-out.out"
check "(b) out-of-tree path: no git fatal" no_fatal "$WORK/b-out"

# A sibling directory that shares the root's name as a prefix is out of tree.
run_fence "$GITLOG_FENCE" "$SIBLING/a.txt" "$WORK/b-sib"
check "(b) sibling of the root (shared name prefix): rejected, git log skipped" grep -q 'git log skipped' "$WORK/b-sib.out"
check "(b) sibling of the root: no git fatal" no_fatal "$WORK/b-sib"

# Traversal and an empty path keep their messages and never reach git as an empty pathspec.
run_fence "$GITLOG_FENCE" '../elsewhere/evil_test.txt' "$WORK/b-dot"
check "(b) traversal path: rejected with the existing message" grep -q 'Path traversal detected' "$WORK/b-dot.out"
check "(b) traversal path: no git fatal" no_fatal "$WORK/b-dot"
run_fence "$GITLOG_FENCE" '' "$WORK/b-empty"
check "(b) empty path: rejected with the existing message" grep -q 'Could not identify affected path' "$WORK/b-empty.out"
check "(b) empty path: no git fatal" no_fatal "$WORK/b-empty"
check "(b) empty path: fence exits 0" test "$RUN_RC" -eq 0

# ---- (c) the test scan fence ------------------------------------------------
# Run from $REPO/docs, which holds bar_test.go, so the path scan (src/) and a
# scan of the current directory tell apart. The project-wide fallback lists
# every test file once.
#   relative src/a.txt  -> path scan lists src/foo_test.go: foo_test.go twice
#                          (path scan + fallback), bar_test.go once (fallback)
#   out-of-tree path    -> no path scan at all: each file once (fallback only)
count_in() { grep -c -- "$2" "$1.out" || true; }
run_fence "$FIND_FENCE" 'src/a.txt' "$WORK/c-rel" "$REPO/docs"
check "(c) relative path: fence exits 0" test "$RUN_RC" -eq 0
check "(c) relative path: the path scan reads src/ (foo_test.go listed twice)" test "$(count_in "$WORK/c-rel" foo_test.go)" -eq 2
check "(c) relative path: the current directory is not scanned (bar_test.go once)" test "$(count_in "$WORK/c-rel" bar_test.go)" -eq 1
run_fence "$FIND_FENCE" "$OUTSIDE/evil_test.txt" "$WORK/c-out" "$REPO/docs"
check "(c) out-of-tree path: the outside directory is not scanned" bash -c '! grep -q "evil_test" "$1.out"' _ "$WORK/c-out"
check "(c) out-of-tree path: no path scan (foo_test.go once, bar_test.go once)" test "$(count_in "$WORK/c-out" foo_test.go)$(count_in "$WORK/c-out" bar_test.go)" = "11"

# ---- bite: the v1.18.32 text drops a relative path and git fatals -----------
run_fence "$OLD_GITLOG_FENCE" 'src/a.txt' "$WORK/old-rel"
check "bite (b): on the v1.18.32 text a relative path reaches git as an empty pathspec" grep -q 'fatal: empty string is not a valid pathspec' "$WORK/old-rel.err"
check "bite (b): on the v1.18.32 text the relative path is not kept (no commit line)" bash -c '! grep -q "touch a" "$1.out"' _ "$WORK/old-rel"
run_fence "$OLD_FIND_FENCE" 'src/a.txt' "$WORK/old-c-rel" "$REPO/docs"
check "bite (c): on the v1.18.32 text a relative path scans the current directory, not src/" test "$(count_in "$WORK/old-c-rel" foo_test.go)$(count_in "$WORK/old-c-rel" bar_test.go)" = "12"

echo "---"
echo "refactor fence tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
