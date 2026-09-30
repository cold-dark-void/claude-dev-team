#!/usr/bin/env bash
# step0.sh — /release Step 0: epic release=end guard (SPEC-025 CDT-141-C4).
#
# Resolves a REF (explicit ticket/epic env, else derived from the branch or
# worktree name), then asserts via skills/epic/epic-lib.sh that /release is
# allowed for that REF. Skips (exit 0) when there is nothing to guard: no
# REF, an unusable REF charset, or no $MROOT/.claude/epics directory.
#
# Exit: 0 ok/skipped · 64 usage | detached HEAD | not a repo | assert failed
#       69 jq missing (with an epics dir present)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: step0.sh [--epic-lib PATH] [-h|--help]

/release Step 0: epic release=end guard.

env:
  RELEASE_TICKET | EPIC_RELEASE_END | EPIC_ID   explicit REF (first non-empty wins)
  EPIC_ROOT                                     MROOT override (as epic-lib.sh)
  EPIC_ALLOW_SEAL_RELEASE                        passed through to epic-lib.sh (honored only
                                                 while the epic is seal-staged)

Exit 0 ok or skipped (no ticket/epic ref, unusable ref, or no epics dir).
Exit 64 usage, detached HEAD, not a git repository, or the release=end guard
failed. Exit 69 jq is missing while an epics dir is present.
EOF
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EPIC_LIB="$HERE/../epic/epic-lib.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --epic-lib)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "step0: --epic-lib requires a path" >&2; exit 64; }
      EPIC_LIB="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "step0: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "step0: not a git repository" >&2
  exit 64
fi

if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
  echo "release: detached HEAD — check out the release branch, then re-run /release (nothing changed)" >&2
  exit 64
fi

BR=$(git symbolic-ref --short HEAD)

REF="${RELEASE_TICKET:-}"
if [ -z "$REF" ]; then
  REF="${EPIC_RELEASE_END:-}"
fi
if [ -z "$REF" ]; then
  REF="${EPIC_ID:-}"
fi

if [ -z "$REF" ]; then
  if [ "$BR" = "master" ] || [ "$BR" = "main" ]; then
    REF=""
  elif [[ "$BR" =~ ^feat/epic-(.+)$ ]]; then
    REF="${BASH_REMATCH[1]}"
  elif [[ "$BR" =~ ^feat/(.+)$ ]]; then
    REF="${BASH_REMATCH[1]}"
  else
    BASE=$(basename -- "$(git rev-parse --show-toplevel)")
    if [[ "$BASE" =~ ^epic-(.+)$ ]]; then
      REF="${BASH_REMATCH[1]}"
    else
      REF="$BASE"
    fi
  fi
fi

if [ -z "$REF" ]; then
  echo "step0: epic guard skipped: no ticket or epic ref (branch $BR)" >&2
  exit 0
fi

if [[ ! "$REF" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "step0: epic guard skipped: '$REF' is not an epic or ticket id" >&2
  exit 0
fi

if [ -n "${EPIC_ROOT:-}" ]; then
  MROOT="$EPIC_ROOT"
else
  _gc=$(git rev-parse --git-common-dir)
  MROOT=$(cd "$(dirname "$_gc")" && pwd)
fi

if [ ! -d "$MROOT/.claude/epics" ]; then
  echo "step0: epic guard skipped: no $MROOT/.claude/epics" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "release: jq is required to read epic state in $MROOT/.claude/epics — install jq, then re-run /release (nothing changed)" >&2
  exit 69
fi

if ! bash "$EPIC_LIB" assert-release-allowed "$REF"; then
  exit 64
fi

bash "$EPIC_LIB" gap-callout "$REF" || true

exit 0
