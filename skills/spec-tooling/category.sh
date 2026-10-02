#!/usr/bin/env bash
# Map a spec ID or a specs/<dir>/ path to the Category token.
# Tokens: core, perf, safe, compat, arch.
# Usage: category.sh <id-or-path>
set -euo pipefail

category_of() {
  local raw="$1"
  local dir="" token="" base
  case "$raw" in
    *specs/*)
      dir="${raw#*specs/}"
      dir="${dir%%/*}"
      ;;
  esac
  case "$dir" in
    core) token=core ;;
    performance|perf) token=perf ;;
    safety|safe) token=safe ;;
    compatibility|compat) token=compat ;;
    architecture|arch) token=arch ;;
  esac
  if [ -n "$token" ]; then
    printf '%s\n' "$token"
    return 0
  fi
  base=$(basename -- "$raw")
  base="${base%%-*}"
  case "$base" in
    PERF|perf) token=perf ;;
    SAFE|safe) token=safe ;;
    COMPAT|compat) token=compat ;;
    ARCH|arch) token=arch ;;
    *) token=core ;;
  esac
  printf '%s\n' "$token"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -eq 1 ] || { printf 'usage: category.sh <id-or-path>\n' >&2; exit 64; }
  category_of "$1"
fi
