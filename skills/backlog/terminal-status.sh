#!/usr/bin/env bash
# terminal-status.sh — shared status classifier for backlog status strings
# (closed/open, CDT-160; the claim stamp, CDT-646).
#
# Contract home (SPEC-002 D1 / SPEC-009 § Backlog terminal status classification).
# Used by close.sh and reconcile.sh — callers MUST NOT maintain a second copy.
#
# Usage:
#   bash skills/backlog/terminal-status.sh is-closed <status-string>
#     exit 0 = closed (terminal)
#     exit 1 = open (including empty/blank status)
#     exit 64 = usage error (missing/unknown subcommand or missing status arg)
#   bash skills/backlog/terminal-status.sh is-claimed <status-string>
#     exit 0 = claimed (the IN_PROGRESS stamp written by close.sh claim, CDT-646)
#     exit 1 = anything else, including every terminal status
#
# IN_PROGRESS is an OPEN status: is-closed returns 1 for it. is-claimed is the
# one copy of that stamp's matcher — callers MUST NOT inline their own.
set -euo pipefail

usage() {
  printf 'usage: %s is-closed|is-claimed <status-string>\n' "${0##*/}" >&2
  exit 64
}

_normalize() {
  local s
  s=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  s=$(printf '%s' "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s' "$s"
}

# is_closed <status>
# Token-match at start of string (after upper-case + trim). Boundary is EOS or
# a char not in [A-Z0-9]. Unanchored substring match is forbidden (UNDONE open).
is_closed() {
  local s
  s=$(_normalize "$1")
  [ -n "$s" ] || return 1

  case "$s" in
    COMPLETED|COMPLETED[!A-Z0-9]*) return 0 ;;
    DONE|DONE[!A-Z0-9]*)           return 0 ;;
    CLOSED|CLOSED[!A-Z0-9]*)       return 0 ;;
    CANCELLED|CANCELLED[!A-Z0-9]*) return 0 ;;
    CANCELED|CANCELED[!A-Z0-9]*)   return 0 ;;
    FIXED/CLOSED|FIXED/CLOSED[!A-Z0-9]*) return 0 ;;
    FIXED-CLOSED|FIXED-CLOSED[!A-Z0-9]*) return 0 ;;
    "FIXED CLOSED"|"FIXED CLOSED"[!A-Z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_claimed <status> — the IN_PROGRESS stamp written by close.sh claim
# (CDT-646). Same token-match rule as is_closed: the boundary is EOS or a char
# not in [A-Z0-9], so `IN_PROGRESS (ic4)` matches and `IN_PROGRESSX` does not.
is_claimed() {
  local s
  s=$(_normalize "$1")
  [ -n "$s" ] || return 1
  case "$s" in
    IN_PROGRESS|IN_PROGRESS[!A-Z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

[ $# -ge 1 ] || usage
cmd=$1
shift

case "$cmd" in
  is-closed)
    [ $# -ge 1 ] || usage
    if is_closed "$1"; then
      exit 0
    fi
    exit 1
    ;;
  is-claimed)
    [ $# -ge 1 ] || usage
    if is_claimed "$1"; then
      exit 0
    fi
    exit 1
    ;;
  *)
    usage
    ;;
esac
