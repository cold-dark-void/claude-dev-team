#!/usr/bin/env bash
#
# autopilot/budget-check.sh — SPEC-033 BC6 (run-budget) + wall-clock helper.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   budget-check.sh <iteration> <run_start_epoch>
# Env:
#   AUTOPILOT_ITERATION_CAP   (default 25)
#   AUTOPILOT_WALLCLOCK_CAP   (default 2700)   # seconds
#
# Computes wall_clock_s = $(date +%s) - run_start_epoch.
# breached = (iteration >= iteration_cap) || (wall_clock_s >= wall_clock_cap_s).
#
# Prints ONE compact JSON object to stdout (always, on valid input):
#   {"wall_clock_s":N,"iteration":N,"iteration_cap":25,"wall_clock_cap_s":2700,
#    "breached":true|false,"blocking_condition":6|null,"reason":"iteration|wall_clock|both|none"}
#
# Dual signal: exit code for scripted branching, JSON on stdout so the caller
# can read wall_clock_s (needed for append-card.sh arg 11 regardless of breach).
#
# Deliberate grep-style convention: breach is a nonzero exit (6). A future
# `set -e` caller that wants to continue past a breach must `|| true`-guard
# the call.
#
# Exit codes:
#   0   within budget
#   6   breached (mnemonic: BC6)
#  64   usage/validation error (non-numeric arg, run_start_epoch > now, wrong argc)

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: budget-check.sh <iteration> <run_start_epoch>'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

# ---- Usage ------------------------------------------------------------------
[ $# -ne 2 ] && die "budget-check.sh requires exactly 2 arguments (got $#)"

ITERATION="$1"
RUN_START_EPOCH="$2"

# ---- Numeric validation (non-negative integers only) ------------------------
case "$ITERATION" in
  ''|*[!0-9]*) die "iteration '$ITERATION' must be a non-negative integer" ;;
esac
case "$RUN_START_EPOCH" in
  ''|*[!0-9]*) die "run_start_epoch '$RUN_START_EPOCH' must be a non-negative integer" ;;
esac

NOW=$(date +%s)
[ "$RUN_START_EPOCH" -gt "$NOW" ] && die "run_start_epoch '$RUN_START_EPOCH' is in the future (now=$NOW)"

# ---- jq guard ----------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  die "jq not found; cannot compute budget-check result"
fi

# ---- Compute -----------------------------------------------------------------
WALL_CLOCK_S=$((NOW - RUN_START_EPOCH))
ITERATION_CAP=${AUTOPILOT_ITERATION_CAP:-25}
WALL_CLOCK_CAP_S=${AUTOPILOT_WALLCLOCK_CAP:-2700}

ITERATION_BREACH=false
[ "$ITERATION" -ge "$ITERATION_CAP" ] && ITERATION_BREACH=true

WALLCLOCK_BREACH=false
[ "$WALL_CLOCK_S" -ge "$WALL_CLOCK_CAP_S" ] && WALLCLOCK_BREACH=true

if [ "$ITERATION_BREACH" = true ] && [ "$WALLCLOCK_BREACH" = true ]; then
  REASON="both"
elif [ "$ITERATION_BREACH" = true ]; then
  REASON="iteration"
elif [ "$WALLCLOCK_BREACH" = true ]; then
  REASON="wall_clock"
else
  REASON="none"
fi

if [ "$REASON" = "none" ]; then
  BREACHED=false
  BLOCKING_CONDITION_JSON="null"
else
  BREACHED=true
  BLOCKING_CONDITION_JSON="6"
fi

jq -cn \
  --argjson wall_clock_s "$WALL_CLOCK_S" \
  --argjson iteration "$ITERATION" \
  --argjson iteration_cap "$ITERATION_CAP" \
  --argjson wall_clock_cap_s "$WALL_CLOCK_CAP_S" \
  --argjson breached "$BREACHED" \
  --argjson blocking_condition "$BLOCKING_CONDITION_JSON" \
  --arg reason "$REASON" \
  '{
    wall_clock_s: $wall_clock_s,
    iteration: $iteration,
    iteration_cap: $iteration_cap,
    wall_clock_cap_s: $wall_clock_cap_s,
    breached: $breached,
    blocking_condition: $blocking_condition,
    reason: $reason
  }'

if [ "$BREACHED" = true ]; then
  exit 6
fi
exit 0
