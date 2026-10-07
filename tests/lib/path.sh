#!/usr/bin/env bash
# tests/lib/path.sh — canonical path form for suite assertions (CDT-502-C3 T2).
# Source only: zero top-level commands, like hermetic.sh / check.sh.
#
# macOS compares two spellings of one location: a trailing-slash TMPDIR
# yields `T//hermetic` strings while `cd`+git yield `T/hermetic`, and the
# `/var` prefix is a symlink to `/private/var`. path_canon resolves BOTH
# through one mechanism — `cd` + `pwd -P` — so both sides of a comparison
# are canonical before they are compared. bash 3.2/BSD safe: no declare -A,
# no mapfile, no GNU-only tools.
#
#   path_canon PATH
#     Prints PATH in physical form: symlinks resolved, `//` and trailing
#     slashes collapsed. Works for directories, files, dangling symlinks,
#     and not-yet-existing paths (the deepest existing ancestor is
#     canonicalized and the remainder appended). Returns non-zero for an
#     empty argument or when no existing ancestor can be entered.
#     Relative paths are resolved against the caller's cwd.
#
# Normalize BOTH sides of a comparison; never strip one side's prefix.
# For a path embedded in tool output (SQL text, `path=` lines, JSON),
# extract it first, then canon both sides.

path_canon() {
  local p dir base rest d out
  p=$1
  [ -n "$p" ] || return 1
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do
    p=${p%/}
  done
  if [ "$p" = "/" ]; then
    printf '/\n'
    return 0
  fi
  case $p in
    */*) dir=${p%/*} base=${p##*/} ;;
    *)   dir=. base=$p ;;
  esac
  [ -n "$dir" ] || dir=/
  if [ -d "$p" ]; then
    out=$(CDPATH= cd -- "$p" 2>/dev/null && pwd -P) || return 1
    printf '%s\n' "$out"
    return 0
  fi
  # Leaf is a plain file, a dangling symlink, or missing: canonicalize the
  # deepest existing ancestor and re-append the remainder.
  rest=""
  d=$dir
  while [ ! -d "$d" ]; do
    case $d in
      "/") return 1 ;;
      */*) rest="/${d##*/}$rest"; d=${d%/*}; [ -n "$d" ] || d=/ ;;
      *)   rest="/$d$rest"; d=. ;;
    esac
  done
  out=$(CDPATH= cd -- "$d" 2>/dev/null && pwd -P) || return 1
  out=${out%/}
  printf '%s\n' "$out$rest/$base"
}
