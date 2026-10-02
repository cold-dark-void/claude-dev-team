#!/usr/bin/env bash
#
# autopilot/loc-exclude.sh — SPEC-033 M15 arms 1–2 (CDT-223).
# Counted-LOC exclusion helper.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   loc-exclude.sh is-excluded <path>
#   loc-exclude.sh filter
# <path> is repo-relative. Arm 1 runs one
# `git -C <worktree-root> check-attr --stdin linguist-generated`
# against the worktree that contains the cwd (git rev-parse --show-toplevel),
# not against a different checkout. `filter` reads one path per line on stdin
# and classifies every path in that single check-attr. `is-excluded` is the
# one-path form of the same check.
#
# Exit (is-excluded):
#   0   excluded (do not count)
#   1   count
#  64   usage
# Exit (filter): 0 and one "<path><TAB>0|1" line per input path (0 excluded,
# 1 count); 64 usage. Empty stdin prints nothing and exits 0.
#
# MUST NOT exit 2 (would kill an orchestrate run). Fail-open on git check-attr
# errors (treat as unspecified). Missing/malformed .gitattributes → arm 1 empty;
# arm 2 still runs.
#
# Arm 1: git check-attr linguist-generated reports set or true
#        (false / unspecified do not exclude via this arm).
# Arm 2: built-in lockfile basenames, basename *.snap, vendored prefixes
#        vendor/ third_party/ node_modules/ after stripping leading ./
#        (path equals the prefix or starts with prefix/). Mid-path
#        src/vendor/x does NOT match. *.pb.go / *_gen.* are NOT built-in.
#
# Arm 3 (SPEC-009 specs/tests) stays with the CALLER — this helper does NOT
# classify test files.

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: loc-exclude.sh is-excluded <path> | loc-exclude.sh filter'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

# arm2_hit <rel> — rel has leading ./ stripped. return 0 if built-in exclude.
arm2_hit() {
  local rel="$1" base
  base="${rel##*/}"
  case "$base" in
    package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lock|bun.lockb|Cargo.lock|composer.lock|Gemfile.lock|poetry.lock|Pipfile.lock|uv.lock|flake.lock|go.sum|*.snap)
      return 0
      ;;
  esac
  case "$rel" in
    vendor|vendor/*|third_party|third_party/*|node_modules|node_modules/*)
      return 0
      ;;
  esac
  return 1
}

strip_dot_slash() {
  local rel="$1"
  while [ "${rel#./}" != "$rel" ]; do
    rel="${rel#./}"
  done
  printf '%s' "$rel"
}

# Worktree root of the cwd. Empty when git cannot resolve one.
resolve_repo_top() {
  REPO_TOP=""
  if command -v git >/dev/null 2>&1; then
    REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_TOP=""
  fi
}

# One check-attr --stdin for every index in NEED (indexes into PATHS).
# On success, sets results[i]=0 when linguist-generated is set or true.
# Fail-open: a git error leaves those results unchanged (caller preset them to 1).
apply_attr_batch() {
  local out="" i idx n=0 aline
  [ -n "${REPO_TOP:-}" ] || return 0
  [ "${#NEED[@]}" -gt 0 ] || return 0
  out=$(
    for i in "${NEED[@]}"; do
      printf '%s\n' "${PATHS[$i]}"
    done | git -C "$REPO_TOP" check-attr --stdin linguist-generated 2>/dev/null
  ) || return 0
  [ -n "$out" ] || return 0
  while IFS= read -r aline || [ -n "$aline" ]; do
    idx="${NEED[$n]}"
    case "${aline##*: }" in
      set|true) RESULTS[$idx]=0 ;;
    esac
    n=$((n + 1))
  done <<< "$out"
}

cmd_is_excluded() {
  local path="$1" rel
  rel=$(strip_dot_slash "$path")
  if arm2_hit "$rel"; then
    exit 0
  fi
  resolve_repo_top
  PATHS=("$path")
  RESULTS=(1)
  NEED=(0)
  apply_attr_batch
  exit "${RESULTS[0]}"
}

cmd_filter() {
  local line rel i
  PATHS=()
  while IFS= read -r line || [ -n "$line" ]; do
    PATHS+=("$line")
  done
  RESULTS=()
  NEED=()
  resolve_repo_top
  if [ "${#PATHS[@]}" -gt 0 ]; then
    for i in "${!PATHS[@]}"; do
      rel=$(strip_dot_slash "${PATHS[$i]}")
      if arm2_hit "$rel"; then
        RESULTS[$i]=0
      else
        RESULTS[$i]=1
        NEED+=("$i")
      fi
    done
  fi
  apply_attr_batch
  if [ "${#PATHS[@]}" -gt 0 ]; then
    for i in "${!PATHS[@]}"; do
      printf '%s\t%s\n' "${PATHS[$i]}" "${RESULTS[$i]}"
    done
  fi
  exit 0
}

# ---- Usage ------------------------------------------------------------------
case "${1:-}" in
  is-excluded)
    [ $# -eq 2 ] || die "loc-exclude.sh requires: is-excluded <path> (got $# args)"
    [ -n "$2" ] || die "path must be non-empty"
    cmd_is_excluded "$2"
    ;;
  filter)
    [ $# -eq 1 ] || die "filter reads paths on stdin (got extra args)"
    cmd_filter
    ;;
  *)
    if [ $# -eq 0 ]; then
      die "loc-exclude.sh requires: is-excluded <path> (got 0 args)"
    fi
    die "unknown command '$1' (want is-excluded or filter)"
    ;;
esac
