#!/usr/bin/env bash
# plugin-dir.sh — locate a dev-team plugin file/dir under the install cache or dev checkout.
#
# Subcommands:
#   file <relpath>  resolve <relpath> and print its absolute path
#   dir  <relpath>  resolve <relpath> and print the parent dir of the resolved path
#
# Resolution (3-tier, single version-algorithm = sort -V; never glob-first):
#   1. Dev-checkout fast path: if $MROOT/<relpath> exists, print it.
#   2. Versioned cache: $HOME/.claude/plugins/cache/$SLUG/dev-team/<VER>/<relpath>,
#      where <VER> is read from that cache's .claude-plugin/plugin.json.
#   3. Find fallback: find $HOME/.claude/plugins/cache -path '*/dev-team/*/<relpath>'
#      | sort -V | tail -1 (highest installed version).
#
# Stdout discipline: prints ONLY the resolved absolute path on success.
# All diagnostics go to stderr. Stdout is empty on any non-zero exit.
# Exit codes: 0 = resolved, 3 = not found (no tier matched),
#             64 = usage error (missing/unknown subcommand or empty relpath).

set -euo pipefail

# Sole home of the marketplace slug in code (tier-2 cache path only).
SLUG="cold-dark-void"

resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

# resolve <relpath> — echo the absolute resolved path on success (exit 0),
# or return 3 if no tier matched. Diagnostics to stderr only.
resolve() {
  local rel="$1"
  local cache="$HOME/.claude/plugins/cache"

  # Tier 1: dev-checkout fast path.
  resolve_mroot
  if [ -e "$MROOT/$rel" ]; then
    printf '%s\n' "$MROOT/$rel"
    return 0
  fi

  # Tier 2: versioned cache — read <VER> from the cache's plugin.json.
  # Guard the substitution so a missing manifest doesn't trip set -e.
  local manifest="$cache/$SLUG/dev-team/.claude-plugin/plugin.json"
  if [ -f "$manifest" ]; then
    local ver=""
    if command -v jq >/dev/null 2>&1; then
      ver=$(jq -r '.version // empty' "$manifest" 2>/dev/null) || ver=""
    fi
    if [ -z "$ver" ]; then
      ver=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" 2>/dev/null \
              | head -1 | sed 's/.*"\([^"]*\)"$/\1/') || ver=""
    fi
    if [ -n "$ver" ]; then
      local cand="$cache/$SLUG/dev-team/$ver/$rel"
      if [ -e "$cand" ]; then
        printf '%s\n' "$cand"
        return 0
      fi
    fi
  fi

  # Tier 3: find fallback — highest version wins (sort -V | tail -1).
  # find/grep may legitimately return non-zero (nothing found); guard against set -e.
  local hit=""
  if [ -d "$cache" ]; then
    hit=$(find "$cache" -path "*/dev-team/*/$rel" 2>/dev/null | sort -V | tail -1) || hit=""
  fi
  if [ -n "$hit" ]; then
    printf '%s\n' "$hit"
    return 0
  fi

  echo "plugin-dir: not found: $rel" >&2
  return 3
}

cmd_file() {
  local rel="${1:-}"
  if [ -z "$rel" ]; then
    echo "file: missing <relpath>" >&2
    exit 64
  fi
  local out
  if out=$(resolve "$rel"); then
    printf '%s\n' "$out"
    exit 0
  fi
  exit 3
}

cmd_dir() {
  local rel="${1:-}"
  if [ -z "$rel" ]; then
    echo "dir: missing <relpath>" >&2
    exit 64
  fi
  local out
  if out=$(resolve "$rel"); then
    dirname "$out"
    exit 0
  fi
  exit 3
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    file) cmd_file "$@" ;;
    dir)  cmd_dir  "$@" ;;
    *)
      echo "usage: plugin-dir.sh {file|dir} <relpath>" >&2
      exit 64
      ;;
  esac
}

main "$@"
