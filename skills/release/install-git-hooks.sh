#!/usr/bin/env bash
# Point this clone at committed githooks/ (bump-class pre-commit on master,
# master-tag pre-push on the default branch). Safe to re-run.
# Subprocess only — never source.
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "install-git-hooks: not a git repository" >&2
  exit 64
fi

ROOT=$(git rev-parse --show-toplevel)
missing=0
for name in pre-commit pre-push; do
  HOOK="$ROOT/githooks/$name"
  if [ ! -f "$HOOK" ]; then
    echo "install-git-hooks: $HOOK missing" >&2
    missing=1
    continue
  fi
  chmod +x "$HOOK"
done
[ "$missing" -eq 0 ] || exit 1

cur=$(git -C "$ROOT" config --get core.hooksPath || true)
if [ -n "$cur" ] && [ "$cur" != "githooks" ]; then
  echo "install-git-hooks: warning: core.hooksPath was '$cur'; hooks there no longer run" >&2
fi

# Absolute git-common-dir hooks/ — not `--git-path hooks`, which follows
# core.hooksPath and would report githooks/ once we set it below.
GIT_COMMON_DIR=$(git -C "$ROOT" rev-parse --git-common-dir)
case "$GIT_COMMON_DIR" in
  /*) : ;;
  *) GIT_COMMON_DIR="$ROOT/$GIT_COMMON_DIR" ;;
esac
LEGACY_HOOKS_DIR="$GIT_COMMON_DIR/hooks"
if [ -d "$LEGACY_HOOKS_DIR" ]; then
  for f in "$LEGACY_HOOKS_DIR"/*; do
    [ -f "$f" ] || continue
    base=$(basename -- "$f")
    case "$base" in
      *.sample) continue ;;
    esac
    echo "install-git-hooks: warning: $f no longer runs (core.hooksPath=githooks)" >&2
  done
fi

git -C "$ROOT" config core.hooksPath githooks
echo "install-git-hooks: core.hooksPath=githooks"
exit 0
