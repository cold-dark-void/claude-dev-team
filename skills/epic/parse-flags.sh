#!/usr/bin/env bash
#
# epic/parse-flags.sh — CDT-141-C1 (SPEC-025 M14)
# Parse --worktree + --release <bump> for /epic. Own parser — do NOT extend
# skills/autopilot/parse-flags.sh (orthogonal; AC8).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   parse-flags.sh [<arg>...]
#   Scans argv for --worktree / --release; leaves other flags alone
#   (--autopilot, --no-context-discipline, --redecompose, …).
#
# Resolution:
#   bare --worktree                         -> worktree_enabled=true
#   --worktree absent                       -> worktree_enabled=false
#   --worktree=* / value form               -> exit 64
#   --release <bump>  (space; canonical)    -> release_bump=<bump>
#   --release=<bump>  (alias)               -> release_bump=<bump>
#   --release absent                        -> release_bump=null
#   --release without --worktree            -> exit 64
#   bare --release / empty / bad bump       -> exit 64
#   --release each|end                      -> exit 64
#   --bump / --land / --seal (any form)     -> exit 64
#   duplicate --worktree or --release       -> exit 64
#   flags with status|complete|block|unblock (first non-flag positional)
#                                           -> exit 64
#
# Prints ONE compact JSON object on exit 0:
#   {"worktree_enabled":true|false,"release_bump":"patch|minor|major"|null}
#
# Exit codes:
#   0   parsed OK
#  64   usage / illegal combo / malformed flag

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: parse-flags.sh [<arg>...]'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

if ! command -v jq >/dev/null 2>&1; then
  die "jq not found; cannot compute parse-flags result"
fi

WT_SEEN=false
WT_ENABLED=false
REL_SEEN=false
REL_BUMP=""
first_positional=""

# Index walk so --release can consume the next argv (space form).
i=0
n=$#
# shellcheck disable=SC2124
args=("$@")

while [ "$i" -lt "$n" ]; do
  a="${args[$i]}"
  case "$a" in
    --worktree=*)
      die "--worktree takes no value (bare flag only); got $a"
      ;;
    --worktree)
      if [ "$WT_SEEN" = true ]; then
        die "duplicate --worktree"
      fi
      WT_SEEN=true
      WT_ENABLED=true
      i=$((i + 1))
      ;;
    --release=*)
      if [ "$REL_SEEN" = true ]; then
        die "duplicate --release"
      fi
      REL_SEEN=true
      REL_BUMP="${a#--release=}"
      i=$((i + 1))
      ;;
    --release)
      if [ "$REL_SEEN" = true ]; then
        die "duplicate --release"
      fi
      REL_SEEN=true
      i=$((i + 1))
      if [ "$i" -ge "$n" ]; then
        die "--release requires a value: patch|minor|major"
      fi
      next="${args[$i]}"
      case "$next" in
        -*)
          die "--release requires a value: patch|minor|major"
          ;;
      esac
      REL_BUMP="$next"
      i=$((i + 1))
      ;;
    --bump|--bump=*|--land|--land=*|--seal|--seal=*)
      die "rejected flag: $a (unsupported; use --worktree and/or --release <bump>)"
      ;;
    --*)
      # Other flags (autopilot, redecompose, no-context-discipline, …) — ignore.
      i=$((i + 1))
      ;;
    *)
      if [ -z "$first_positional" ]; then
        first_positional="$a"
      fi
      i=$((i + 1))
      ;;
  esac
done

if [ "$REL_SEEN" = true ]; then
  case "$REL_BUMP" in
    patch|minor|major) ;;
    each|end)
      die "--release $REL_BUMP rejected; bump must be patch|minor|major"
      ;;
    "")
      die "--release requires a value: patch|minor|major"
      ;;
    *)
      die "--release $REL_BUMP: bump must be one of patch, minor, major"
      ;;
  esac
  if [ "$WT_ENABLED" != true ]; then
    die "--release requires --worktree"
  fi
fi

case "$first_positional" in
  status|complete|block|unblock)
    if [ "$WT_SEEN" = true ] || [ "$REL_SEEN" = true ]; then
      die "--worktree/--release not valid with $first_positional"
    fi
    ;;
esac

if [ -n "$REL_BUMP" ]; then
  jq -cn \
    --argjson worktree_enabled "$WT_ENABLED" \
    --arg release_bump "$REL_BUMP" \
    '{worktree_enabled:$worktree_enabled, release_bump:$release_bump}'
else
  jq -cn \
    --argjson worktree_enabled "$WT_ENABLED" \
    '{worktree_enabled:$worktree_enabled, release_bump:null}'
fi

exit 0
