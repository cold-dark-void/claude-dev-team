#!/usr/bin/env bash
# terminal-status.sh — shared closed/open classifier for backlog status strings (CDT-160).
#
# Contract home (SPEC-002 D1 / SPEC-009 § Backlog terminal status classification).
# Used by close.sh and reconcile.sh — callers MUST NOT maintain a second copy.
#
# Usage:
#   bash skills/backlog/terminal-status.sh is-closed <status-string>
#     exit 0 = closed (terminal)
#     exit 1 = open (including empty/blank status)
#     exit 64 = usage error (missing/unknown subcommand or missing status arg)
set -euo pipefail

usage() {
  printf 'usage: %s is-closed <status-string>\n' "${0##*/}" >&2
  exit 64
}

# is_closed <status>
# Token-match at start of string (after upper-case + trim). Boundary is EOS or
# a char not in [A-Z0-9]. Unanchored substring match is forbidden (UNDONE open).
is_closed() {
  local s
  s=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  s=$(printf '%s' "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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
  *)
    usage
    ;;
esac
