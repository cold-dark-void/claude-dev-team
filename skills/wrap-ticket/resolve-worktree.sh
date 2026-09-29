#!/usr/bin/env bash
# skills/wrap-ticket/resolve-worktree.sh — one worktree matcher for wrap-ticket
# (SPEC-016 "One worktree matcher (WP 1-06)"; SPEC-009 Wrap-Ticket).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
#   bash resolve-worktree.sh <TICKET-ID>
#
# Prints one absolute worktree path on stdout, or nothing when no worktree
# matches. Exit 0 on a normal lookup (found or not found); exit 64 on a
# missing or invalid <TICKET-ID> (must match ^[A-Za-z0-9_-]+$).
#
# $MROOT resolves from cwd via the standard formula (SPEC-002/SPEC-009):
#   git rev-parse --git-common-dir -> parent dir; else pwd.
#
# Order (first hit wins; SPEC-016 "Caller integration"):
#   1. Epic shared integration tree: skills/epic/epic-lib.sh
#      resolve-child-worktree <TICKET-ID> reports use_shared == true ->
#      its integration_path.
#   2. $MROOT/.worktrees/<TICKET-ID> when that directory exists (new
#      per-ticket convention).
#   3. A legacy worktree from `git worktree list --porcelain`: an entry
#      whose branch line is exactly "branch refs/heads/feat/<ID>", or whose
#      path basename equals <ID> or ends with "-<ID>". No substring match —
#      CDT-1 MUST NOT match CDT-1-2.
#
# bash 3.2 portable: no mapfile, no declare -A, no ${var,,}, no local -n.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EPIC_LIB="$HERE/../epic/epic-lib.sh"

usage_error() {
  printf 'resolve-worktree: usage error: %s\n' "$1" >&2
  exit 64
}

[ "$#" -eq 1 ] || usage_error "need exactly one <TICKET-ID>"
ID="$1"
if [ -z "$ID" ] || ! [[ "$ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  usage_error "invalid <TICKET-ID> (only [A-Za-z0-9_-] allowed): $ID"
fi

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)

# 1. Epic shared integration tree.
DEF='{}'
if [ -f "$EPIC_LIB" ] && command -v jq >/dev/null 2>&1; then
  CHILD_WT=$(bash "$EPIC_LIB" resolve-child-worktree "$ID" 2>/dev/null) || CHILD_WT=""
  USE_SHARED=$(jq -r '.use_shared // false' <<<"${CHILD_WT:-$DEF}" 2>/dev/null) || USE_SHARED="false"
  if [ "$USE_SHARED" = "true" ]; then
    INT_PATH=$(jq -r '.integration_path // empty' <<<"${CHILD_WT:-$DEF}" 2>/dev/null) || INT_PATH=""
    if [ -n "$INT_PATH" ]; then
      printf '%s\n' "$INT_PATH"
      exit 0
    fi
  fi
fi

# 2. New per-ticket convention.
if [ -d "$MROOT/.worktrees/$ID" ]; then
  printf '%s\n' "$MROOT/.worktrees/$ID"
  exit 0
fi

# 3. Legacy worktree — one awk pass over porcelain output. Exact branch
# match, or basename equality/suffix. No grep -w, no substring match. Value
# goes through ENVIRON, never awk -v (a value can hold /, \t, \n, \\, &).
# The first "worktree" record is always $MROOT itself (the main checkout) —
# skip it so a "-<ID>" suffix can never match the main tree (L4).
git -C "$MROOT" worktree list --porcelain 2>/dev/null \
  | RW_ID="$ID" awk '
    BEGIN { id = ENVIRON["RW_ID"]; feat = "refs/heads/feat/" id; suffix = "-" id; found = ""; rec = 0 }
    function is_match(   n, parts, base, slen, blen) {
      n = split(wt, parts, "/")
      base = parts[n]
      if (branch == feat) return 1
      if (base == id) return 1
      slen = length(suffix); blen = length(base)
      if (blen >= slen && substr(base, blen - slen + 1) == suffix) return 1
      return 0
    }
    /^worktree / { rec++; wt = substr($0, 10); branch = "" }
    /^branch /   { branch = substr($0, 8) }
    /^$/ {
      if (rec > 1 && wt != "" && found == "" && is_match()) { found = wt }
      wt = ""
    }
    END {
      if (rec > 1 && wt != "" && found == "" && is_match()) { found = wt }
      if (found != "") print found
    }
  '
exit 0
