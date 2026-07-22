#!/usr/bin/env bash
# plugin-dir.sh — locate a dev-team plugin file/dir under the install cache or dev checkout.
#
# Subcommands:
#   file <relpath>  resolve <relpath> and print its absolute path
#   dir  <relpath>  resolve <relpath> and print the parent dir of the resolved path
#
# Resolution (4-tier; single version-algorithm = pre-release-safe sort -V; never glob-first):
#   0. Optional CLAUDE_PLUGIN_ROOT: if set and $CLAUDE_PLUGIN_ROOT/<relpath> exists, print it.
#      Dead in Bash-tool fences today (hooks/MCP/LSP only; FR #48230) — forward-compat only.
#   1. Dev-checkout fast path: if $MROOT/<relpath> exists, print it.
#   2. Versioned cache: $HOME/.claude/plugins/cache/$SLUG/dev-team/<VER>/<relpath>,
#      where <VER> is the highest versioned subdir via
#      ls | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./'
#      (tilde map so final 1.0.0 outranks retained 1.0.0-pre.N).
#      Real layout (verified): version dirs live directly under dev-team/
#      (e.g. …/dev-team/0.37.4/); there is NO .claude-plugin/ at the
#      dev-team/ level — each <VER> has its own .claude-plugin/plugin.json.
#   3. Find fallback: find … -path '*/dev-team/*/<relpath>'
#      | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./'
#
# Stdout discipline: prints ONLY the resolved absolute path on success.
# All diagnostics go to stderr. Stdout is empty on any non-zero exit.
# Exit codes: 0 = resolved, 3 = not found (no tier matched),
#             64 = usage error (missing/unknown subcommand or empty relpath).

set -euo pipefail

# Sole home of the marketplace slug in code (tier-2 cache path only).
SLUG="cold-dark-void"

# Pre-release-safe version pick: map -pre. → ~pre. so GNU sort -V ranks final
# releases above retained pre-release dirs, then unmap. Load-bearing (CLAUDE_PLUGIN_ROOT
# is dead in Bash fences). Input on stdin; prints the single winner (or empty).
ver_pick() {
  sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./'
}

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

  # Tier 0 (optional, dead in Bash fences today — FR #48230): CLAUDE_PLUGIN_ROOT.
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -e "$CLAUDE_PLUGIN_ROOT/$rel" ]; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT/$rel"
    return 0
  fi

  # Tier 1: dev-checkout fast path.
  resolve_mroot
  if [ -e "$MROOT/$rel" ]; then
    printf '%s\n' "$MROOT/$rel"
    return 0
  fi

  # Tier 2: versioned cache — highest versioned subdir under dev-team/
  # (pre-release-safe ver_pick). Layout is …/dev-team/<VER>/…
  # Guard so a missing cache dir doesn't trip set -e.
  local team_root="$cache/$SLUG/dev-team"
  if [ -d "$team_root" ]; then
    local ver=""
    ver=$(ls -1 "$team_root" 2>/dev/null | ver_pick) || ver=""
    if [ -n "$ver" ]; then
      local cand="$team_root/$ver/$rel"
      if [ -e "$cand" ]; then
        printf '%s\n' "$cand"
        return 0
      fi
    fi
  fi

  # Tier 3: find fallback — highest version wins (pre-release-safe ver_pick).
  # find may legitimately return non-zero (nothing found); guard against set -e.
  local hit=""
  if [ -d "$cache" ]; then
    hit=$(find "$cache" -path "*/dev-team/*/$rel" 2>/dev/null | ver_pick) || hit=""
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
