#!/usr/bin/env bash
#
# autopilot/parse-flags.sh — CDT-111-C4 T1 (Decision #1) — flag+env detection,
# bump resolution, precedence. CDT-126 Task 6 adds --council-tier parsing
# (a second, independent DRI flag on the same invocation — no precedence
# interaction with --autopilot). CDT-206 adds --tier (pipeline cost tier;
# independent of --council-tier; no env).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   parse-flags.sh [<arg>...]
#   Scans positional args for --autopilot / --autopilot=<bump>, for
#   --council-tier=<skip|light|full>, and for --tier=<light|standard|full>.
#   Reads AUTOPILOT env var. --tier has no env equivalent.
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
# Bump vocabulary: /release tokens {patch,minor,major} plus land-no-release
# sentinel master (SPEC-033 M2 / CDT-195). master is flag-only ship intent —
# never a /release version; env NEVER carries it.
#
# --council-tier=<skip|light|full> — CDT-126, SPEC-013 § Council tiering.
# DRI-only override, per-run, never auto-selected, no env-var equivalent
# (unlike --autopilot, there is no ambient "always skip council" mode to
# encode). Requires an `=` value; a bare --council-tier or an out-of-vocabulary
# value is a malformed flag. Last-wins if repeated.
#   --council-tier=<skip|light|full>  -> council_tier=<value>
#   --council-tier absent              -> council_tier=null
#   --council-tier=<junk>, or bare --council-tier with no `=`
#                                       -> exit 64
#
# --tier=<light|standard|full> — CDT-206, SPEC-009 § Orchestrate `--tier`.
# Pipeline cost tier. Independent of --council-tier (neither flag writes the
# other's JSON key). `=` form only; no env. Omit → JSON null (do not coerce
# to standard or full). skip is illegal here. A second --tier / --tier=*
# token is malformed even when values match (stricter than --council-tier).
#   --tier=<light|standard|full>  -> tier=<value>
#   --tier absent                  -> tier=null
#   --tier=<junk>, empty --tier=, bare --tier, case mismatch, or duplicate
#                                       -> exit 64
#
# Prints ONE compact JSON object to stdout (always, on exit 0) — five keys:
#   {"enabled":true|false,"bump":"patch|minor|major|master"|null,"source":"flag|env|none",
#    "council_tier":"skip|light|full"|null,"tier":"light"|"standard"|"full"|null}
#
# Exit codes:
#   0   parsed OK (enabled true or false)
#  64   malformed --autopilot=<bump> (bump not in {patch,minor,major,master}, incl. empty --autopilot=)
#       or malformed --council-tier (value not in {skip,light,full}, incl. bare/empty)
#       or malformed --tier (value not in {light,standard,full}, incl. bare/empty/duplicate)

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

# ---- Scan args for --council-tier=<skip|light|full> (CDT-126) ----------------
CT_SEEN=false
CT_HAS_EQ=false
CT_VALUE=""

# ---- Scan args for --tier=<light|standard|full> (CDT-206) --------------------
TIER_SEEN=false
TIER_HAS_EQ=false
TIER_VALUE=""

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
    --council-tier=*)
      CT_SEEN=true
      CT_HAS_EQ=true
      CT_VALUE="${a#--council-tier=}"
      ;;
    --council-tier)
      CT_SEEN=true
      ;;
    --tier=*)
      if [ "$TIER_SEEN" = true ]; then
        die "--tier specified more than once"
      fi
      TIER_SEEN=true
      TIER_HAS_EQ=true
      TIER_VALUE="${a#--tier=}"
      ;;
    --tier)
      if [ "$TIER_SEEN" = true ]; then
        die "--tier specified more than once"
      fi
      TIER_SEEN=true
      ;;
  esac
done

# ---- Resolve ------------------------------------------------------------------
if [ "$FLAG_SEEN" = true ]; then
  if [ "$FLAG_HAS_EQ" = true ]; then
    case "$FLAG_BUMP" in
      patch|minor|major|master)
        ENABLED=true
        BUMP="$FLAG_BUMP"
        SOURCE="flag"
        ;;
      *)
        die "--autopilot=$FLAG_BUMP: bump must be one of patch, minor, major, master"
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

# ---- Resolve --council-tier (CDT-126) ------------------------------------
if [ "$CT_SEEN" = true ]; then
  if [ "$CT_HAS_EQ" = true ]; then
    case "$CT_VALUE" in
      skip|light|full) ;;
      *) die "--council-tier=$CT_VALUE: tier must be one of skip, light, full" ;;
    esac
  else
    die "--council-tier requires a value: --council-tier=<skip|light|full>"
  fi
  CT_ARG=("--arg" "council_tier" "$CT_VALUE")
  CT_EXPR='$council_tier'
else
  CT_ARG=("--argjson" "council_tier" "null")
  CT_EXPR='$council_tier'
fi

# ---- Resolve --tier (CDT-206) --------------------------------------------
if [ "$TIER_SEEN" = true ]; then
  if [ "$TIER_HAS_EQ" = true ]; then
    case "$TIER_VALUE" in
      light|standard|full) ;;
      *) die "--tier=$TIER_VALUE: tier must be one of light, standard, full" ;;
    esac
  else
    die "--tier requires a value: --tier=<light|standard|full>"
  fi
  TIER_ARG=("--arg" "tier" "$TIER_VALUE")
  TIER_EXPR='$tier'
else
  TIER_ARG=("--argjson" "tier" "null")
  TIER_EXPR='$tier'
fi

jq -cn \
  --argjson enabled "$ENABLED" \
  "${BUMP_ARG[@]}" \
  --arg source "$SOURCE" \
  "${CT_ARG[@]}" \
  "${TIER_ARG[@]}" \
  "{enabled: \$enabled, bump: $BUMP_EXPR, source: \$source, council_tier: $CT_EXPR, tier: $TIER_EXPR}"

exit 0
