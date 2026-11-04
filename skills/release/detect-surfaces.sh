#!/usr/bin/env bash
# SPEC-041 AC8 shared Surface-detection helper: prints newly added
# top-level commands/<name>.md paths, one per line. --no-renames
# throughout, so a rename onto the top level counts as added; the
# --against mode also counts untracked files (git ls-files --others).
# Callers: check-bump-class.sh and the ship-gate veto (M9). Shared —
# do not keep a private copy of this predicate (AC8).
#
# Usage:
#   detect-surfaces.sh --against REF   # worktree diff vs REF + untracked
#   detect-surfaces.sh --cached [REF]  # index vs REF (default HEAD)
#   detect-surfaces.sh --commit REV    # REV vs its parent
#
# Exit: 0 ok · 64 usage
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: detect-surfaces.sh --against REF
       detect-surfaces.sh --cached [REF]
       detect-surfaces.sh --commit REV

Prints newly added top-level commands/<name>.md paths, one per line.
Nested commands/<sub>/*.md and edits to existing commands are not a
new Surface.
EOF
}

die_usage() {
  echo "detect-surfaces.sh: $1" >&2
  usage
  exit 64
}

MODE=""
ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --against|--cached|--commit)
      [ -z "$MODE" ] || die_usage "exactly one of --against/--cached/--commit is required"
      MODE="${1#--}"
      if [ "$MODE" = "cached" ]; then
        # REF is optional for --cached; a following non-flag word is the ref.
        if [ $# -ge 2 ] && [ -n "${2:-}" ] && [[ "$2" != --* ]]; then
          ARG="$2"
          shift
        fi
      else
        [ $# -ge 2 ] && [ -n "${2:-}" ] || die_usage "--$MODE requires a ref"
        ARG="$2"
        shift
      fi
      shift
      ;;
    -h|--help) usage; exit 64 ;;
    --*) die_usage "unknown flag: $1" ;;
    *) die_usage "unexpected argument: $1" ;;
  esac
done

[ -n "$MODE" ] || die_usage "one of --against/--cached/--commit is required"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die_usage "not a git repository"
fi

# True if p is a new top-level command surface: commands/<name>.md (not
# commands/<sub>/<name>.md — nested paths are not a new Surface).
is_surface_path() {
  [[ "$1" =~ ^commands/[^/]+\.md$ ]]
}

case "$MODE" in
  against)
    git rev-parse --verify "$ARG" >/dev/null 2>&1 || die_usage "unresolvable ref: $ARG"
    git diff --no-renames --name-only --diff-filter=A "$ARG" -- commands/ || true
    git ls-files --others --exclude-standard -- commands/ || true
    ;;
  cached)
    REF=${ARG:-HEAD}
    git rev-parse --verify "$REF" >/dev/null 2>&1 || die_usage "unresolvable ref: $REF"
    git diff --cached --no-renames --name-only --diff-filter=A "$REF" -- commands/ || true
    ;;
  commit)
    git rev-parse --verify "${ARG}^{commit}" >/dev/null 2>&1 || die_usage "unresolvable ref: $ARG"
    if git rev-parse --verify "${ARG}^" >/dev/null 2>&1; then
      git diff-tree --no-commit-id --no-renames --name-only --diff-filter=A -r "${ARG}^" "${ARG}" -- commands/ || true
    fi
    ;;
esac | while IFS= read -r p; do
  [ -n "$p" ] || continue
  if is_surface_path "$p"; then
    printf '%s\n' "$p"
  fi
done
