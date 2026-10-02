#!/usr/bin/env bash
# --gate requires --tests. Exit 64 and print the error when it does not.
# Usage: check-gate.sh [args as passed to /spec check]
set -euo pipefail

has_tests=0
has_gate=0
for a in "$@"; do
  case "$a" in
    --tests) has_tests=1 ;;
    --gate|--gate=*) has_gate=1 ;;
  esac
done
if [ "$has_gate" -eq 1 ] && [ "$has_tests" -eq 0 ]; then
  printf 'error: --gate requires --tests\n' >&2
  exit 64
fi
exit 0
