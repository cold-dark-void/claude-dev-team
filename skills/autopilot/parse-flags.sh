#!/usr/bin/env bash
#
# autopilot/parse-flags.sh — CDT-111-C4 T1 (Decision #1) — flag+env detection,
# bump resolution, precedence.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   parse-flags.sh [<arg>...]
#   Scans positional args for --autopilot / --autopilot=<bump>.
#   Reads AUTOPILOT env var.
# Env:
#   AUTOPILOT   unset|0|"" = off ; 1|true = on (bump stays null — env NEVER carries a bump)
#
# Resolution (flag wins over env; encodes FINAL #3):
#   --autopilot=<bump> present, <bump> legal  -> enabled/bump/source=flag
#   bare --autopilot present                  -> enabled/null/source=flag
#   --autopilot=<junk> (illegal/empty)        -> exit 64 (wins over env, no silent fallback)
#   no flag, AUTOPILOT in {1,true}            -> enabled/null/source=env
#   no flag, AUTOPILOT unset/0/other          -> disabled/null/source=none
#
# Bump vocabulary is borrowed from /release (SPEC-033 M2) — only membership in
# {patch,minor,major} is checked here; this script does not define/extend it.
#
# Prints ONE compact JSON object to stdout (always, on exit 0):
#   {"enabled":true|false,"bump":"patch|minor|major"|null,"source":"flag|env|none"}
#
# Exit codes:
#   0   parsed OK (enabled true or false)
#  64   malformed --autopilot=<bump> (bump not in {patch,minor,major}, incl. empty --autopilot=)

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: parse-flags.sh [<arg>...]'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

# ---- jq guard ----------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  die "jq not found; cannot compute parse-flags result"
fi

# ---- Scan args for --autopilot / --autopilot=<bump> --------------------------
FLAG_SEEN=false
FLAG_BUMP=""       # raw value after '=' when present
FLAG_HAS_EQ=false  # whether '=' form was used at all

for a in "$@"; do
  case "$a" in
    --autopilot=*)
      FLAG_SEEN=true
      FLAG_HAS_EQ=true
      FLAG_BUMP="${a#--autopilot=}"
      ;;
    --autopilot)
      FLAG_SEEN=true
      ;;
  esac
done

# ---- Resolve ------------------------------------------------------------------
if [ "$FLAG_SEEN" = true ]; then
  if [ "$FLAG_HAS_EQ" = true ]; then
    case "$FLAG_BUMP" in
      patch|minor|major)
        ENABLED=true
        BUMP="$FLAG_BUMP"
        SOURCE="flag"
        ;;
      *)
        die "--autopilot=$FLAG_BUMP: bump must be one of patch, minor, major"
        ;;
    esac
  else
    ENABLED=true
    BUMP=""
    SOURCE="flag"
  fi
else
  case "${AUTOPILOT:-}" in
    1|true)
      ENABLED=true
      BUMP=""
      SOURCE="env"
      ;;
    *)
      ENABLED=false
      BUMP=""
      SOURCE="none"
      ;;
  esac
fi

if [ -n "$BUMP" ]; then
  BUMP_ARG=("--arg" "bump" "$BUMP")
  BUMP_EXPR='$bump'
else
  BUMP_ARG=("--argjson" "bump" "null")
  BUMP_EXPR='$bump'
fi

jq -cn \
  --argjson enabled "$ENABLED" \
  "${BUMP_ARG[@]}" \
  --arg source "$SOURCE" \
  "{enabled: \$enabled, bump: $BUMP_EXPR, source: \$source}"

exit 0
