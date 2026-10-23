#!/usr/bin/env bash
# resolve-concurrency.sh — merge the Spawn concurrency cap from flag, env, and Model map
# (SPEC-013 CDT-573; SPEC-037 M31–M33). Every Surface calls this helper; do not
# paste a flag > env > map merge into commands.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
#   bash skills/model-map/resolve-concurrency.sh
#   bash skills/model-map/resolve-concurrency.sh --flag <N>
#
# Precedence: --flag N > $COUNCIL_CONCURRENCY > resolve-model.sh --concurrency
# (Model map local > repo > global). An empty-string env counts as unset.
# The env layer is validated on every path that reaches it, including when a
# flag wins, so a flag never hides a malformed COUNCIL_CONCURRENCY from the next
# flagless run (SPEC-013 § Spawn concurrency cap; SPEC-039 M37 precedent). The
# Model map stays lazy: it is read only when the flag and the env are both unset.
# stdout: the cap integer, or empty (unbounded). At most one trailing newline.
# stderr: usage and warnings only.
# exit:   0, or 64 when the flag/env value is not an integer >= 1 (usage),
#         or when the stored map value is invalid (64 from resolve-model.sh
#         propagates; invokers treat 64 as preflight failure, never silent
#         unbounded).
# Extra argv is ignored. Read-only: MUST NOT mkdir or write. The Model map is
# read only through the resolve-model.sh CLI (never sourced, never re-implemented).

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  echo "usage: resolve-concurrency.sh [--flag <N>]" >&2
}

# A cap is a positive decimal integer with no sign, spaces, or leading zeros.
is_cap() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$1" in
    [1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# check_env_layer — validate the COUNCIL_CONCURRENCY layer. Set, non-empty, and
# not a positive integer is a hard fail (exit 64 at the caller): the warning
# names the variable so the operator can fix the export. Returns 0 when the env
# is unset, empty, or a valid cap.
check_env_layer() {
  local v=${COUNCIL_CONCURRENCY:-}
  [ -n "$v" ] || return 0
  is_cap "$v" && return 0
  echo "resolve-concurrency.sh: COUNCIL_CONCURRENCY '$v' is not a positive integer >= 1; fix or unset it" >&2
  usage
  return 1
}

if [ "${1:-}" = "--flag" ]; then
  shift
  if [ -z "${1:-}" ] || ! is_cap "$1"; then
    usage
    exit 64
  fi
  # The flag wins, but a junk env still fails closed (SPEC-039 M37 precedent).
  check_env_layer || exit 64
  printf '%s\n' "$1"
  exit 0
fi

env_val=${COUNCIL_CONCURRENCY:-}
if [ -n "$env_val" ]; then
  check_env_layer || exit 64
  printf '%s\n' "$env_val"
  exit 0
fi

rc=0
out=$(bash "$SCRIPT_DIR/resolve-model.sh" --concurrency) || rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
if [ -n "$out" ] && ! is_cap "$out"; then
  echo "model-map: concurrency '${out}' from map is not a positive integer; failing closed" >&2
  exit 64
fi
if [ -n "$out" ]; then
  printf '%s\n' "$out"
fi
exit 0
