#!/usr/bin/env bash
# Point this clone at committed githooks/ (bump-class pre-commit on master).
# Safe to re-run. Subprocess only — never source.
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "install-git-hooks: not a git repository" >&2
  exit 64
fi

ROOT=$(git rev-parse --show-toplevel)
HOOK="$ROOT/githooks/pre-commit"
if [ ! -f "$HOOK" ]; then
  echo "install-git-hooks: $HOOK missing" >&2
  exit 1
fi
chmod +x "$HOOK"
git -C "$ROOT" config core.hooksPath githooks
echo "install-git-hooks: core.hooksPath=githooks"
exit 0
