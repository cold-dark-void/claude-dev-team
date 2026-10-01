#!/usr/bin/env bash
# scheduled-exit.sh — write the short scheduled report and release the lock.
# Caller prints the human line. Args: --note TEXT --summary TEXT
# Reads MODE, AUTO, SCHEDULED_LOCK_TOKEN, and the session counters from the environment.
set -u
NOTE=""
SUMMARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --note) NOTE="${2:-}"; shift 2 ;;
    --summary) SUMMARY="${2:-}"; shift 2 ;;
    *) echo "scheduled-exit: unknown arg: $1" >&2; exit 1 ;;
  esac
done
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INVOKER="$SCRIPT_DIR/invoke-scheduled-report.sh"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if [ -x "$INVOKER" ]; then
  bash "$INVOKER" \
    --mode "${MODE:-}" --auto "${AUTO:-}" --mroot "$MROOT" \
    --token "${SCHEDULED_LOCK_TOKEN:-}" \
    --note "$NOTE" --summary "$SUMMARY" \
    --scanned "${SCANNED:-0}" \
    --skipped-inprog "${SKIPPED_INPROG:-0}" \
    --skipped-filter2 "${SKIPPED_FILTER2:-0}" \
    --gated "${GATED_PASS:-0}" --deep "${DEEP_READ:-0}"
fi
