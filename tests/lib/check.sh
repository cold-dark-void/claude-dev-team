#!/usr/bin/env bash
# tests/lib/check.sh — WP 1-12 TL fix: shared PASS/FAIL line helpers for test
# suites (extracted from the three wp-1-12-fence-state fence suites — copy-
# extract rule). Source only, like hermetic.sh, fence.sh and text.sh: sourcing
# this file has no side effect (zero top-level commands; only function
# definitions below). The caller owns the counters: set `pass=0; fail=0`
# before the first call, and end with `[ "$fail" -eq 0 ]`.
#
#   pass_line <label>     prints "PASS: <label>" and increments $pass
#   fail_line <label>     prints "FAIL: <label>" and increments $fail
#   check <label> <cmd...>
#     Runs <cmd...>; exit 0 -> pass_line, anything else -> fail_line. The
#     command's own output is not suppressed.
#
# bash 3.2 (no declare -A / mapfile / ${v,,}).

pass_line() { echo "PASS: $1"; pass=$((pass + 1)); }
fail_line() { echo "FAIL: $1"; fail=$((fail + 1)); }

check() {
  local label="$1"
  shift
  if "$@"; then pass_line "$label"; else fail_line "$label"; fi
}
