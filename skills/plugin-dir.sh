#!/usr/bin/env bash
# plugin-dir.sh — locate a dev-team plugin file/dir under dev checkout, marketplace, or install cache.
#
# Subcommands:
#   file   <relpath>  resolve <relpath> and print its absolute path
#   dir    <relpath>  resolve <relpath> and print the parent dir of the resolved path
#   root              resolve plugin root (dir containing skills/plugin-dir.sh)
#   verify            dogfood/operator gate: print root + tier + version + STM marker;
#                     exit 0 if STM (or non-handoff root); exit 2 if legacy shadowed
#                     by a same-version STM source (marketplace/dev); exit 3 not found
#
# Resolution (load-bearing; pre-release-safe sort -V; never glob-first):
#   0. Optional CLAUDE_PLUGIN_ROOT: if set and $CLAUDE_PLUGIN_ROOT/<relpath> exists.
#      Dead in Bash-tool fences today (hooks/MCP/LSP only; FR #48230) — also the
#      operator force path (AC-3) without reinstall / "delete cache only".
#   1. Dev worktree (show-toplevel): if $WTROOT/<relpath> exists — worktree-correct
#      so feat/* dogfood is not shadowed by the main checkout via git-common-dir.
#   2. Dev main checkout (git-common-dir MROOT): only if different from WTROOT and
#      $MROOT/<relpath> exists.
#   3. Marketplace clone vs versioned cache (CDT-82):
#      - marketplace: ~/.claude/plugins/marketplaces/* with skills/plugin-dir.sh + agents/pm.md
#      - cache: ~/.claude/plugins/cache/$SLUG/dev-team/<VER>/ (highest ver_pick)
#      Pick highest version (pre-release-safe). Same version string: prefer STM
#      source (marketplace/dev) over legacy cache — never silently soft-continue
#      on frozen legacy five-extractor when marketplace/dev has --events (AC-2).
#   4. Find fallback: find … -path '*/dev-team/*/<relpath>' | ver_pick
#
# Stdout discipline (file/dir/root): prints ONLY the resolved absolute path on success.
# verify: multi-line status on stdout. Diagnostics to stderr. Stdout empty on fail
# for file/dir/root. Exit: 0 ok, 2 shadow/legacy gate fail (verify), 3 not found,
# 64 usage.

set -euo pipefail

# Sole home of the marketplace slug in code (tier-cache path only).
SLUG="cold-dark-void"

# Pre-release-safe version pick: map -pre. → ~pre. so GNU sort -V ranks final
# releases above retained pre-release dirs, then unmap. Load-bearing.
ver_pick() {
  sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./'
}

# Compare two version strings: echo -1 / 0 / 1 (a<b / a==b / a>b) via ver_pick.
ver_cmp() {
  local a="$1" b="$2"
  if [ "$a" = "$b" ]; then
    printf '0\n'
    return 0
  fi
  local win
  win=$(printf '%s\n%s\n' "$a" "$b" | ver_pick)
  if [ "$win" = "$a" ]; then
    printf '1\n'
  else
    printf -- '-1\n'
  fi
}

resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

resolve_wtroot() {
  WTROOT=""
  if WTROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    :
  else
    WTROOT=""
  fi
}

# plugin_version <root> — read .claude-plugin/plugin.json version (empty if missing).
plugin_version() {
  local root="$1"
  local pj="$root/.claude-plugin/plugin.json"
  if [ ! -f "$pj" ]; then
    printf '\n'
    return 0
  fi
  # Avoid python dependency in the hot path: sed out "version": "X"
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pj" | head -1
}

# stm_marker <plugin-root> — stm | legacy | unknown | none
# STM handoff (CDT-79): prepass finalize takes --events.
# Legacy five-extractor: prepass finalize takes --sections only.
stm_marker() {
  local root="$1"
  local prepass="$root/skills/handoff/prepass.sh"
  if [ ! -f "$prepass" ]; then
    printf 'none\n'
    return 0
  fi
  if grep -q -- '--events' "$prepass" 2>/dev/null; then
    printf 'stm\n'
    return 0
  fi
  if grep -q -- '--sections' "$prepass" 2>/dev/null; then
    printf 'legacy\n'
    return 0
  fi
  printf 'unknown\n'
}

# marketplace_roots — print absolute marketplace plugin roots that look like dev-team.
marketplace_roots() {
  local d
  for d in "$HOME"/.claude/plugins/marketplaces/*/; do
    [ -d "$d" ] || continue
    if [ -f "${d}skills/plugin-dir.sh" ] && [ -f "${d}agents/pm.md" ]; then
      printf '%s\n' "${d%/}"
    fi
  done
}

# cache_team_root
cache_team_root() {
  printf '%s\n' "$HOME/.claude/plugins/cache/$SLUG/dev-team"
}

# highest_cache_ver — ver_pick under team_root, or empty
highest_cache_ver() {
  local team_root
  team_root=$(cache_team_root)
  if [ ! -d "$team_root" ]; then
    printf '\n'
    return 0
  fi
  ls -1 "$team_root" 2>/dev/null | ver_pick || true
}

# emit_path <path> [tier] [note] — stdout path; optional stderr trace
emit_path() {
  local path="$1"
  local tier="${2:-}"
  local note="${3:-}"
  if [ -n "${PDH_TRACE:-}" ] && [ -n "$tier" ]; then
    echo "plugin-dir: tier=$tier path=$path${note:+ $note}" >&2
  fi
  printf '%s\n' "$path"
}

# resolve <relpath> — echo absolute path; return 0/3
resolve() {
  local rel="$1"
  local cache="$HOME/.claude/plugins/cache"

  # Tier 0: operator force / CLAUDE_PLUGIN_ROOT (AC-3).
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -e "$CLAUDE_PLUGIN_ROOT/$rel" ]; then
    emit_path "$CLAUDE_PLUGIN_ROOT/$rel" "force" "root=$CLAUDE_PLUGIN_ROOT marker=$(stm_marker "$CLAUDE_PLUGIN_ROOT")"
    return 0
  fi

  # Tier 1: current worktree (show-toplevel) — dogfood feat/* correctly.
  resolve_wtroot
  if [ -n "$WTROOT" ] && [ -e "$WTROOT/$rel" ]; then
    emit_path "$WTROOT/$rel" "worktree" "root=$WTROOT marker=$(stm_marker "$WTROOT")"
    return 0
  fi

  # Tier 2: main checkout via git-common-dir (when WTROOT lacked the relpath).
  # Covers: cwd inside a non-plugin worktree linked to a plugin main, or bare
  # main checkout when show-toplevel already matched (tier 1 returned).
  resolve_mroot
  if [ -n "$MROOT" ] && [ -e "$MROOT/$rel" ]; then
    emit_path "$MROOT/$rel" "dev-main" "root=$MROOT marker=$(stm_marker "$MROOT")"
    return 0
  fi

  # Tier 3: marketplace vs versioned cache (CDT-82 same-version STM preference).
  local mp_root="" mp_ver="" mp_path=""
  local cand
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if [ -e "$cand/$rel" ]; then
      mp_root="$cand"
      mp_path="$cand/$rel"
      mp_ver=$(plugin_version "$cand")
      break
    fi
  done < <(marketplace_roots)

  local team_root ver cache_path cache_root=""
  team_root=$(cache_team_root)
  ver=""
  if [ -d "$team_root" ]; then
    ver=$(ls -1 "$team_root" 2>/dev/null | ver_pick) || ver=""
  fi
  if [ -n "$ver" ]; then
    cache_path="$team_root/$ver/$rel"
    if [ -e "$cache_path" ]; then
      cache_root="$team_root/$ver"
    else
      cache_path=""
    fi
  fi

  if [ -n "$mp_path" ] && [ -n "$cache_path" ]; then
    local cmp mp_mark cache_mark
    # Missing version → treat as equal only if both empty; else prefer side with ver.
    if [ -z "$mp_ver" ] && [ -z "$ver" ]; then
      cmp=0
    elif [ -z "$mp_ver" ]; then
      cmp=-1
    elif [ -z "$ver" ]; then
      cmp=1
    else
      cmp=$(ver_cmp "$mp_ver" "$ver")
    fi
    mp_mark=$(stm_marker "$mp_root")
    cache_mark=$(stm_marker "$cache_root")

    if [ "$cmp" -gt 0 ]; then
      emit_path "$mp_path" "marketplace" "ver=$mp_ver marker=$mp_mark"
      return 0
    fi
    if [ "$cmp" -lt 0 ]; then
      # Cache strictly newer — still refuse silent legacy soft-continue when a
      # same-version... (not same). Use cache, but prefer STM if cache legacy
      # and marketplace is STM *at equal content concern* — only when equal.
      emit_path "$cache_path" "cache" "ver=$ver marker=$cache_mark"
      return 0
    fi
    # Same version string: prefer STM over legacy (AC-2 / OQ-1 / OQ-2).
    if [ "$mp_mark" = "stm" ] && [ "$cache_mark" = "legacy" ]; then
      echo "plugin-dir: same-version shadow: prefer marketplace STM over cache legacy (both ${mp_ver:-unknown})" >&2
      echo "plugin-dir: marketplace=$mp_root marker=stm" >&2
      echo "plugin-dir: cache=$cache_root marker=legacy" >&2
      emit_path "$mp_path" "marketplace" "ver=$mp_ver marker=stm shadow-skip-cache"
      return 0
    fi
    if [ "$cache_mark" = "stm" ] && [ "$mp_mark" = "legacy" ]; then
      emit_path "$cache_path" "cache" "ver=$ver marker=stm"
      return 0
    fi
    # Equal flavor: prefer marketplace over cache (OQ-1).
    echo "plugin-dir: same-version: prefer marketplace over cache (ver=${mp_ver:-unknown} marker=$mp_mark)" >&2
    emit_path "$mp_path" "marketplace" "ver=$mp_ver marker=$mp_mark"
    return 0
  fi

  if [ -n "$mp_path" ]; then
    emit_path "$mp_path" "marketplace" "ver=$mp_ver marker=$(stm_marker "$mp_root")"
    return 0
  fi
  if [ -n "$cache_path" ]; then
    emit_path "$cache_path" "cache" "ver=$ver marker=$(stm_marker "$cache_root")"
    return 0
  fi

  # Tier 4: find fallback — highest version wins (pre-release-safe ver_pick).
  local hit=""
  if [ -d "$cache" ]; then
    hit=$(find "$cache" -path "*/dev-team/*/$rel" 2>/dev/null | ver_pick) || hit=""
  fi
  if [ -n "$hit" ]; then
    emit_path "$hit" "find"
    return 0
  fi

  echo "plugin-dir: not found: $rel" >&2
  return 3
}

# plugin_root_of <abs-file-path> — walk up to root that has skills/plugin-dir.sh
plugin_root_of() {
  local p="$1"
  local d
  d=$(cd "$(dirname "$p")" && pwd)
  while [ "$d" != "/" ]; do
    if [ -f "$d/skills/plugin-dir.sh" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    d=$(dirname "$d")
  done
  return 1
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

cmd_root() {
  local out
  if out=$(resolve "skills/plugin-dir.sh"); then
    dirname "$(dirname "$out")"
    exit 0
  fi
  exit 3
}

# verify — print resolved root + tier + version + STM marker (AC-4/AC-6).
# Exit 0: STM or no handoff prepass (non-handoff roots OK).
# Exit 2: resolved legacy while another same-version STM root exists (shadow).
# Exit 3: not found.
cmd_verify() {
  local out root mark ver tier=""
  if ! out=$(resolve "skills/plugin-dir.sh"); then
    echo "plugin-dir verify: FAIL not found" >&2
    exit 3
  fi
  root=$(cd "$(dirname "$out")/.." && pwd)
  mark=$(stm_marker "$root")
  ver=$(plugin_version "$root")

  # Infer tier from path (best-effort for operator display).
  case "$root" in
    "${CLAUDE_PLUGIN_ROOT:-__none__}") tier="force" ;;
    *)
      resolve_wtroot
      resolve_mroot
      if [ -n "$WTROOT" ] && [ "$root" = "$WTROOT" ]; then
        tier="worktree"
      elif [ "$root" = "$MROOT" ]; then
        tier="dev-main"
      elif printf '%s' "$root" | grep -q '/plugins/marketplaces/'; then
        tier="marketplace"
      elif printf '%s' "$root" | grep -q '/plugins/cache/'; then
        tier="cache"
      else
        tier="other"
      fi
      ;;
  esac

  printf 'plugin-dir verify: root=%s\n' "$root"
  printf 'plugin-dir verify: tier=%s\n' "$tier"
  printf 'plugin-dir verify: version=%s\n' "${ver:-unknown}"
  printf 'plugin-dir verify: stm_marker=%s\n' "$mark"

  if [ "$mark" = "stm" ]; then
    printf 'plugin-dir verify: OK STM engine (--events)\n'
    exit 0
  fi

  if [ "$mark" = "none" ] || [ "$mark" = "unknown" ]; then
    # No handoff prepass — not a CDT-82 handoff gate failure.
    printf 'plugin-dir verify: OK (no handoff prepass / unknown)\n'
    exit 0
  fi

  # Legacy resolved — check for a same-version STM peer we should have preferred.
  local peer_stm="" peer_root="" peer_ver="" cand
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if [ "$(stm_marker "$cand")" = "stm" ]; then
      peer_root="$cand"
      peer_ver=$(plugin_version "$cand")
      peer_stm=1
      break
    fi
  done < <(marketplace_roots)

  if [ -z "$peer_stm" ]; then
    resolve_wtroot
    if [ -n "$WTROOT" ] && [ "$(stm_marker "$WTROOT")" = "stm" ]; then
      peer_root="$WTROOT"
      peer_ver=$(plugin_version "$WTROOT")
      peer_stm=1
    fi
  fi

  if [ -n "$peer_stm" ]; then
    # Same-version or any peer STM while we picked legacy = shadow failure (AC-2).
    if [ -z "$ver" ] || [ -z "$peer_ver" ] || [ "$ver" = "$peer_ver" ] || [ "$(ver_cmp "$ver" "$peer_ver")" -le 0 ]; then
      echo "plugin-dir verify: FAIL legacy root shadowed by STM source" >&2
      echo "plugin-dir verify: legacy_root=$root marker=legacy ver=${ver:-unknown}" >&2
      echo "plugin-dir verify: stm_root=$peer_root marker=stm ver=${peer_ver:-unknown}" >&2
      echo "plugin-dir verify: force: export CLAUDE_PLUGIN_ROOT=<stm_root>  # AC-3, no full reinstall" >&2
      exit 2
    fi
  fi

  printf 'plugin-dir verify: WARN legacy engine (--sections); no STM peer found\n'
  exit 0
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    file)   cmd_file "$@" ;;
    dir)    cmd_dir  "$@" ;;
    root)   cmd_root "$@" ;;
    verify) cmd_verify "$@" ;;
    *)
      echo "usage: plugin-dir.sh {file|dir|root|verify} [relpath]" >&2
      exit 64
      ;;
  esac
}

main "$@"
