#!/usr/bin/env bash
# invoke-scheduled-report.sh — scheduled report + lock release for one fence.
#
# commands/retro.md Steps 2d, 3c, 6a, and 6i call this script. A function
# defined in the Step 1b fence does not exist in those fresh shells (CDT-324).
#
# No-op (exit 0) unless --mode all and --auto 1.
# On the scheduled path: run write-scheduled-report.sh, print "Report: <path>",
# then release scheduled.lock with --token only. It does not read a newer
# run's token out of scheduled.owner. It deletes that file only when the
# file still holds this same token.
# release without a matching token does not delete the lock (scheduled-lock.sh).
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WRITER="$HERE/write-scheduled-report.sh"
LOCK_SH="$HERE/scheduled-lock.sh"

MODE=""
AUTO=""
MROOT=""
NOTE=""
SUMMARY=""
SCANNED=0
SKIPPED_INPROG=0
SKIPPED_FILTER2=0
GATED=0
DEEP=0
APPLIED_FILE=""
FOLLOWUP_FILE=""
DUP_FILE=""
OBS_FILE=""
TOKEN_ARG=""

usage() {
  echo "usage: invoke-scheduled-report.sh --mode MODE --auto 0|1 --mroot PATH [options]" >&2
  exit 1
}

# A value flag needs a value. With one argument left, `shift 2` would not
# move and the parse loop would not end (WP 2-02, CDT-286 [08 F16]).
need_arg() { [ "$2" -ge 2 ] || { echo "invoke-scheduled-report: $1 needs a value" >&2; usage; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)            need_arg "$1" $#; MODE="$2"; shift 2 ;;
    --auto)            need_arg "$1" $#; AUTO="$2"; shift 2 ;;
    --mroot)           need_arg "$1" $#; MROOT="$2"; shift 2 ;;
    --note)            need_arg "$1" $#; NOTE="$2"; shift 2 ;;
    --summary)         need_arg "$1" $#; SUMMARY="$2"; shift 2 ;;
    --scanned)         need_arg "$1" $#; SCANNED="$2"; shift 2 ;;
    --skipped-inprog)  need_arg "$1" $#; SKIPPED_INPROG="$2"; shift 2 ;;
    --skipped-filter2) need_arg "$1" $#; SKIPPED_FILTER2="$2"; shift 2 ;;
    --gated)           need_arg "$1" $#; GATED="$2"; shift 2 ;;
    --deep)            need_arg "$1" $#; DEEP="$2"; shift 2 ;;
    --applied-file)    need_arg "$1" $#; APPLIED_FILE="$2"; shift 2 ;;
    --followup-file)   need_arg "$1" $#; FOLLOWUP_FILE="$2"; shift 2 ;;
    --duplicate-file)  need_arg "$1" $#; DUP_FILE="$2"; shift 2 ;;
    --observations-file) need_arg "$1" $#; OBS_FILE="$2"; shift 2 ;;
    --token)           need_arg "$1" $#; TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)         usage ;;
    *) echo "invoke-scheduled-report: unknown arg: $1" >&2; usage ;;
  esac
done

[ "$MODE" = "all" ] && [ "$AUTO" = "1" ] || exit 0
[ -n "$MROOT" ] || exit 0

if [ ! -x "$WRITER" ]; then
  echo "# retro: write-scheduled-report.sh missing — skip report" >&2
else
  SKIPPED_TOTAL=$((SKIPPED_INPROG + SKIPPED_FILTER2))
  set -- --mroot "$MROOT" --mode all-auto \
    --scanned "$SCANNED" --skipped "$SKIPPED_TOTAL" \
    --gated "$GATED" --deep "$DEEP"
  [ -n "$NOTE" ] && set -- "$@" --note "$NOTE"
  [ -n "$APPLIED_FILE" ] && [ -f "$APPLIED_FILE" ] && set -- "$@" --applied-file "$APPLIED_FILE"
  [ -n "$FOLLOWUP_FILE" ] && [ -f "$FOLLOWUP_FILE" ] && set -- "$@" --followup-file "$FOLLOWUP_FILE"
  [ -n "$DUP_FILE" ] && [ -f "$DUP_FILE" ] && set -- "$@" --duplicate-file "$DUP_FILE"
  [ -n "$OBS_FILE" ] && [ -f "$OBS_FILE" ] && set -- "$@" --observations-file "$OBS_FILE"
  [ -n "$SUMMARY" ] && set -- "$@" --summary "$SUMMARY"
  REPORT_PATH=$(bash "$WRITER" "$@" 2>/dev/null) || REPORT_PATH=""
  if [ -n "$REPORT_PATH" ]; then
    echo "Report: $REPORT_PATH"
  fi
fi

if [ -n "$TOKEN_ARG" ] && [ -x "$LOCK_SH" ]; then
  bash "$LOCK_SH" release "$MROOT" "$TOKEN_ARG" || true
fi
OWNER="$MROOT/.claude/retro/scheduled.owner"
if [ -n "$TOKEN_ARG" ] && [ -f "$OWNER" ]; then
  _cur=$(cat "$OWNER" 2>/dev/null || true)
  if [ "$_cur" = "$TOKEN_ARG" ]; then
    rm -f "$OWNER"
  fi
fi
exit 0
