#!/usr/bin/env bash
# tests/lib/assert.sh — shared typed asserts for the orchestrate/init test
# family (CDT-293 [06 E5]). One canonical copy replaces the assert_eq /
# assert_ne / assert_contains / assert_not_contains / assert_match / assert_rc
# / assert_file / assert_not_file / assert_dir definitions that were copied
# (and drifting) across the per-suite files. Argument order is fixed:
#
#   assert_eq|assert_ne|assert_rc        <label> <got> <want>
#   assert_contains|assert_not_contains  <label> <hay> <needle>   (fixed string)
#   assert_match                         <label> <got> <regex>
#   assert_file|assert_not_file|assert_dir <label> <path>
#
# Source-only, like check.sh: sourcing has zero side effects. The caller owns
# the counters — set PASS=0 and FAIL=0 before the first call and end with
# `[ "$FAIL" -eq 0 ]`. Output: "  ok  <label>" / "  FAIL <label>: ...".
# bash 3.2 (no declare -A / mapfile).

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  ok  $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $label: got=[$got] want=[$want]"
  fi
}

assert_ne() {
  local label="$1" got="$2" want_not="$3"
  if [ "$got" != "$want_not" ]; then
    PASS=$((PASS + 1)); echo "  ok  $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $label: got=[$got] want !=[$want_not]"
  fi
}

assert_contains() {
  local label="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ok  $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $label: missing [$needle]"
  fi
}

assert_not_contains() {
  local label="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1)); echo "  FAIL $label: unexpectedly has [$needle]"
  else
    PASS=$((PASS + 1)); echo "  ok  $label"
  fi
}

assert_match() {
  local label="$1" got="$2" pattern="$3"
  if printf '%s\n' "$got" | grep -qE -- "$pattern"; then
    PASS=$((PASS + 1)); echo "  ok  $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $label: [$got] does not match /$pattern/"
  fi
}

assert_rc() {
  local label="$1" got="$2" want="$3"
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS + 1)); echo "  ok  $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $label: rc=$got want=$want"
  fi
}

assert_file() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $label: missing $path"
  fi
}

assert_not_file() {
  local label="$1" path="$2"
  if [ ! -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $label: unexpected file $path"
  fi
}

assert_dir() {
  local label="$1" path="$2"
  if [ -d "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $label: missing dir $path"
  fi
}
