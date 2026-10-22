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

if [ "${1:-}" = "--flag" ]; then
  shift
  if [ -z "${1:-}" ] || ! is_cap "$1"; then
    usage
    exit 64
  fi
  printf '%s\n' "$1"
  exit 0
fi

env_val=${COUNCIL_CONCURRENCY:-}
if [ -n "$env_val" ]; then
  if ! is_cap "$env_val"; then
    usage
    exit 64
  fi
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
