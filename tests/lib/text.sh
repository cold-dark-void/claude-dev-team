#!/usr/bin/env bash
# tests/lib/text.sh — WP 1-08 T5 fix pass: shared static-text test helpers
# (extracted from test-ship-gate-guardrails.sh, the sole pre-existing copy —
# copy-extract rule). Source only, like hermetic.sh and fence.sh: sourcing
# this file has no side effect (zero top-level commands; only function
# definitions below).
#
#   has <file> <substring>
#     Literal substring present in <file> (exit 0) or not (exit 1). A thin
#     wrapper over `grep -F -q`.
#
#   remove_line_substr <src> <dst> <substring>
#     Removes the FIRST line-local occurrence of a literal substring (no
#     regex escaping needed — awk index()/substr() on literal text) and
#     writes the result to <dst>. Used by suites to build one-token
#     mutations for bite tests.
#
# bash 3.2 (no declare -A / mapfile / ${v,,}). awk only, no writes beyond
# the caller-supplied <dst> path. The substring value crosses into awk via
# ENVIRON, never `awk -v` (hazard checklist: -v assignment backslash-
# processes \t \n \\ & / — ENVIRON does not).

has() {
  if [ $# -lt 2 ]; then
    echo "has: usage: has <file> <substring>" >&2
    return 1
  fi
  grep -F -q -- "$2" "$1"
}

remove_line_substr() {
  if [ $# -lt 3 ]; then
    echo "remove_line_substr: usage: remove_line_substr <src> <dst> <substring>" >&2
    return 1
  fi
  local src=$1 dst=$2 s=$3
  env RLS_S="$s" awk '
    BEGIN { s = ENVIRON["RLS_S"]; done = 0 }
    {
      if (!done) {
        i = index($0, s)
        if (i > 0) {
          print substr($0, 1, i - 1) substr($0, i + length(s))
          done = 1
          next
        }
      }
      print
    }
  ' "$src" > "$dst"
}
