#!/usr/bin/env bash
# parse-args.sh — the one /retro argument parser (WP 2-02, rv-w1-46 / CDT-297).
#
# Pure CLI — never sourced. Takes the words of the /retro command line and
# prints shell assignments on stdout, each value quoted with printf %q:
#
#   MODE=single|all  AUTO=0|1  WHY=0|1  EXPLICIT_SID=<word>
#   HOST=claude|grok|all|<empty>  HOST_EXPLICIT=0|1
#
# Usage in a /retro fence (commands/retro.md Steps 1 and 2):
#   PARSED=$(bash "$PARSE_ARGS" "$@") || exit 1
#   eval "$PARSED"
#
# Exit: 0 parsed; 1 error (one line on stderr, nothing on stdout).
# An unknown --flag is reported on stderr ("Unknown flag") and skipped.
# Rules (SPEC-012 / CDT-156 OQ3):
#   --all and <session-id> are mutually exclusive.
#   --host takes claude|grok|all (also --host=<v>); a bare --all implies
#   --host all.
set -u

MODE="single"
AUTO=0
WHY=0
EXPLICIT_SID=""
HOST=""
HOST_EXPLICIT=0
prev_host=0

for arg in "$@"; do
  if [ "$prev_host" = "1" ]; then
    case "$arg" in
      claude|grok|all) HOST="$arg"; HOST_EXPLICIT=1; prev_host=0; continue ;;
      *) echo "error: --host expects claude|grok|all, got: $arg" >&2; exit 1 ;;
    esac
  fi
  case "$arg" in
    --all)  MODE="all" ;;
    --auto) AUTO=1 ;;
    --why)  WHY=1 ;;
    --host) prev_host=1 ;;
    --host=*)
      hv="${arg#--host=}"
      case "$hv" in
        claude|grok|all) HOST="$hv"; HOST_EXPLICIT=1 ;;
        *) echo "error: --host expects claude|grok|all, got: $hv" >&2; exit 1 ;;
      esac
      ;;
    --*)    echo "Unknown flag: $arg" >&2 ;;
    *)      EXPLICIT_SID="$arg" ;;
  esac
done

if [ "$prev_host" = "1" ]; then
  echo "error: --host requires a value (claude|grok|all)" >&2
  exit 1
fi
# bare --all without --host => --host all
if [ "$MODE" = "all" ] && [ "$HOST_EXPLICIT" = "0" ]; then
  HOST="all"
fi
if [ "$MODE" = "all" ] && [ -n "$EXPLICIT_SID" ]; then
  echo "error: --all and <session-id> are mutually exclusive" >&2
  exit 1
fi

for name in MODE AUTO WHY EXPLICIT_SID HOST HOST_EXPLICIT; do
  printf '%s=%q\n' "$name" "${!name}" || exit 1
done
