#!/usr/bin/env bash
# Blind-review file list from the linked worktree (WTROOT), not MROOT.
# Usage: blind-file-list.sh [target]
# Prints absolute paths, one per line. Empty list exits 1.
# git ls-files errors are not hidden. An untracked --target falls through to find.
set -euo pipefail

WTROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "council: blind file list: git rev-parse --show-toplevel failed" >&2
  exit 1
}

TARGET=${1-}

filter_excludes() {
  grep -vE '\.(lock|min\.js|min\.css|pb\.go|pb\.py|svg)$' \
    | grep -v 'node_modules/' \
    | grep -v 'dist/' \
    | grep -v 'vendor/' \
    || true
}

# Fixed-string match. An unescaped regex would treat '.' as any character.
drop_git() {
  grep -vF '.git/' || true
}

to_abs() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      /*) printf '%s\n' "$line" ;;
      *) printf '%s\n' "$WTROOT/$line" ;;
    esac
  done
}

tmp=$(mktemp "${TMPDIR:-/tmp}/council-blind.XXXXXX") || {
  echo "council: blind file list: mktemp failed" >&2
  exit 1
}
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT

git_list() {
  local spec=$1
  : >"$tmp" || return 1
  if ! git -C "$WTROOT" ls-files -z -- "$spec" >"$tmp"; then
    echo "council: blind file list: git ls-files failed" >&2
    return 1
  fi
  tr '\0' '\n' <"$tmp" | sed '/^$/d'
}

raw=""
if [ -n "$TARGET" ]; then
  raw=$(git_list "$TARGET") || exit 1
  if [ -z "$raw" ]; then
    search="$WTROOT/$TARGET"
    if [ ! -e "$search" ]; then
      echo "council: blind file list empty: target not found: $TARGET" >&2
      exit 1
    fi
    raw=$(find "$search" -type f -print0 | tr '\0' '\n' | sed '/^$/d' | drop_git)
  fi
else
  raw=$(git_list "$WTROOT") || exit 1
fi

if [ -z "$raw" ]; then
  echo "council: blind file list empty" >&2
  exit 1
fi

out=$(printf '%s\n' "$raw" | filter_excludes | sed '/^$/d')
if [ -z "$out" ]; then
  echo "council: blind file list empty" >&2
  exit 1
fi
printf '%s\n' "$out" | to_abs
