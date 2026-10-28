#!/usr/bin/env bash
# tests/lib/ac-receipt.sh — CDT-595 per-AC run receipts (SPEC-009 § CDT-595).
# Source-only, like skip.sh and check.sh: this file holds function
# definitions and no top-level command, so sourcing has zero side effects.
# The caller owns the counters — set PASS=0 and FAIL=0 before the first call
# and end the suite with ac_finish.
#
#   set_ac <id>            CUR_AC=<id>. <id> must match AC[1-9][0-9]*, else
#                          return 64 (caller bug, not a usage error).
#   want_ac                return 0 when AC_FILTER is empty (full run) or
#                          equals CUR_AC. Wrap each AC block:
#                          set_ac AC7; if want_ac; then ...; fi
#   ok <slug>              stdout "ok <CUR_AC>: <slug>"; PASS++. Empty CUR_AC
#                          is the router-static unlabeled case: PASS++ with no
#                          line.
#   bad <slug> <detail>    stderr "FAIL: <CUR_AC>: <slug>: <detail>"; FAIL++.
#   skip_ac <slug>         stdout "skip <CUR_AC>: <slug>"; touches neither
#                          counter (SPEC-030 R18 skip is not a pass).
#   parse_ac_args "$@"     sets AC_FILTER from --ac <id>. Bare --ac, a second
#                          --ac, --ac AC, --ac foo, --ac AC0, an unknown flag,
#                          and a leftover positional each print one usage line
#                          on stderr and exit 64.
#   ac_finish              with AC_FILTER set and PASS+FAIL = 0 the filter
#                          matched nothing: usage on stderr, exit 64 (this
#                          covers a valid id no check carries, e.g. --ac AC99).
#                          Else print "PASS=<n> FAIL=<m>" as the last stdout
#                          line and exit 0 iff m = 0.
#
# The colon is load-bearing: the investigator AC-label filter
# (skills/council/prompts/investigator.md) matches `ok AC7: slug` and misses
# the bare-space form (CDT-595 T1 spike). Keep slugs to [a-z0-9-] tokens so
# the filter's boundary class [^A-Za-z0-9_] holds. Receipts go to stdout and
# failures to stderr, so `grep -c '^ok '` equals PASS.
#
# AC_RECEIPT_FORCE_FAIL=<slug> turns `ok <slug>` into `bad <slug> planted`.
# The nested hermetic invoke in ticket-class-receipts-test.sh uses it to prove
# the FAIL: shape and the non-zero exit (CDT-595 AC2).
#
# Do not source skip.sh here: that helper prints the `SKIP:` line, which
# judge.md reads as evidence against (SPEC-030). skip_ac is the receipt form.
#
# bash 3.2 (no declare -A / mapfile / local -n / ${v,,}). The AC filter is
# exact string equality on CUR_AC, not the investigator regex.

# _ac_id_ok <id> — return 0 when <id> is AC[1-9][0-9]*. Glob cannot express
# "digits only" in one arm (`AC[1-9][0-9]*` also takes AC12x), so strip the
# prefix and test the remainder.
_ac_id_ok() {
  local id="${1:-}" rest
  case "$id" in AC*) rest="${id#AC}" ;; *) return 1 ;; esac
  [ -n "$rest" ] || return 1
  case "$rest" in 0*) return 1 ;; esac
  [ -z "${rest//[0-9]/}" ]
}

# _ac_usage — one usage line on stderr, then exit 64. <basename> is the
# sourcing suite ($0), not this file.
_ac_usage() {
  printf 'usage: %s [--ac AC<n>]\n' "$(basename -- "$0")" >&2
  exit 64
}

set_ac() {
  local id="${1:-}"
  if ! _ac_id_ok "$id"; then
    return 64
  fi
  CUR_AC="$id"
  return 0
}

want_ac() {
  if [ -z "${AC_FILTER:-}" ]; then
    return 0
  fi
  [ "$AC_FILTER" = "${CUR_AC:-}" ]
}

ok() {
  local slug="${1:-}"
  if [ -n "${AC_RECEIPT_FORCE_FAIL:-}" ] && [ "$slug" = "$AC_RECEIPT_FORCE_FAIL" ]; then
    bad "$slug" planted
    return 0
  fi
  PASS=$(( ${PASS:-0} + 1 ))
  if [ -n "${CUR_AC:-}" ]; then
    printf 'ok %s: %s\n' "$CUR_AC" "$slug" || return 1
  fi
  return 0
}

bad() {
  local slug="${1:-}" detail="${2:-}"
  FAIL=$(( ${FAIL:-0} + 1 ))
  printf 'FAIL: %s: %s: %s\n' "${CUR_AC:-}" "$slug" "$detail" >&2 || return 1
  return 0
}

skip_ac() {
  local slug="${1:-}"
  printf 'skip %s: %s\n' "${CUR_AC:-}" "$slug" || return 1
  return 0
}

parse_ac_args() {
  AC_FILTER=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ac)
        # A trailing --ac must not reach `shift 2` with one argument left:
        # shift fails, the loop never advances, and the suite hangs.
        if [ "$#" -lt 2 ] || [ -n "$AC_FILTER" ] || ! _ac_id_ok "$2"; then
          _ac_usage
        fi
        AC_FILTER="$2"
        shift 2
        ;;
      *)
        _ac_usage
        ;;
    esac
  done
  return 0
}

ac_finish() {
  if [ -n "${AC_FILTER:-}" ] && [ $(( ${PASS:-0} + ${FAIL:-0} )) -eq 0 ]; then
    _ac_usage
  fi
  printf 'PASS=%s FAIL=%s\n' "${PASS:-0}" "${FAIL:-0}" || exit 1
  if [ "${FAIL:-0}" -eq 0 ]; then
    exit 0
  fi
  exit 1
}
