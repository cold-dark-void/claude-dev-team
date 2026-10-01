#!/usr/bin/env bash
# skills/lib/changed-set.sh — paths a review, refute, simplify, or scan must cover.
#
# Subprocess only. Never source.
#
#   bash skills/lib/changed-set.sh [-C dir] paths
#
# Prints repo-root-relative paths, one per line, sorted and unique:
# the merge-base range when one resolves, the unstaged diff, the staged
# diff, and untracked files (ls-files --others --exclude-standard).
# An empty set prints nothing and exits 0.
set -u

cd_dir=""
sub=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      [ "$#" -ge 2 ] || { printf 'changed-set: -C needs a directory\n' >&2; exit 64; }
      cd_dir="$2"
      shift 2
      ;;
    paths) sub="paths"; shift; break ;;
    *) printf 'changed-set: usage: changed-set.sh [-C dir] paths\n' >&2; exit 64 ;;
  esac
done
[ "$sub" = "paths" ] || { printf 'changed-set: usage: changed-set.sh [-C dir] paths\n' >&2; exit 64; }
[ "$#" -eq 0 ] || { printf 'changed-set: unexpected argument: %s\n' "$1" >&2; exit 64; }

# -C is the repo. An inherited GIT_DIR from a linked worktree must not win.
unset GIT_DIR GIT_WORK_TREE

if [ -n "$cd_dir" ]; then
  root=$(git -C "$cd_dir" rev-parse --show-toplevel 2>/dev/null) || exit 2
else
  root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 2
fi

base=$(git -C "$root" merge-base HEAD origin/master 2>/dev/null \
  || git -C "$root" merge-base HEAD origin/main 2>/dev/null \
  || git -C "$root" merge-base HEAD master 2>/dev/null \
  || git -C "$root" merge-base HEAD main 2>/dev/null \
  || true)

{
  if [ -n "$base" ]; then
    git -C "$root" diff --name-only "$base"...HEAD 2>/dev/null || true
  fi
  git -C "$root" diff --name-only 2>/dev/null || true
  git -C "$root" diff --cached --name-only 2>/dev/null || true
  git -C "$root" ls-files --others --exclude-standard 2>/dev/null || true
} | sed '/^$/d' | sort -u
exit 0
