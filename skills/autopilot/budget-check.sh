#!/usr/bin/env bash
#
# autopilot/budget-check.sh — SPEC-033 BC6 (run-budget) + wall-clock helper.
# CDT-224 / M9b: argc 2 | argc 4 | derive.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   budget-check.sh <iteration> <run_start_epoch>
#   budget-check.sh <iteration> <run_start_epoch> <iteration_cap> <wall_clock_cap_s>
#   budget-check.sh derive <tasks> <projected_loc> <waves>
#
# Env (argc=2 only; empty = unset → static M 25/2700; junk non-integer → 64):
#   AUTOPILOT_ITERATION_CAP   (default 25)
#   AUTOPILOT_WALLCLOCK_CAP   (default 2700)   # seconds
# Argc=4 uses argv caps verbatim (MUST NOT re-read env).
# derive uses the raw S/M/L table (MUST NOT read env).
# MUST NOT write/export AUTOPILOT_ITERATION_CAP or AUTOPILOT_WALLCLOCK_CAP.
#
# Check path: wall_clock_s = $(date +%s) - run_start_epoch.
# breached = (iteration >= iteration_cap) || (wall_clock_s >= wall_clock_cap_s).
#
# Check stdout: ONE compact JSON object, 7 keys:
#   {"wall_clock_s":N,"iteration":N,"iteration_cap":N,"wall_clock_cap_s":N,
#    "breached":true|false,"blocking_condition":6|null,"reason":"iteration|wall_clock|both|none"}
#
# derive stdout: {tier,iteration_cap,wall_clock_cap_s,signals:{tasks,projected_loc,waves}}
#
# Dual signal: exit code for scripted branching, JSON on stdout so the caller
# can read wall_clock_s (needed for append-card.sh arg 11 regardless of breach).
#
# Deliberate grep-style convention: breach is a nonzero exit (6). A future
# `set -e` caller that wants to continue past a breach must `|| true`-guard
# the call.
#
# Exit codes:
#   0   within budget (check) / derived (derive)
#   6   breached (mnemonic: BC6)
#  64   usage/validation error (non-numeric arg, run_start_epoch > now, wrong argc)

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: budget-check.sh <iteration> <run_start_epoch> [<iteration_cap> <wall_clock_cap_s>]
       budget-check.sh derive <tasks> <projected_loc> <waves>'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

require_nnint() {
  case "$2" in
    ''|*[!0-9]*) die "$1 '$2' must be a non-negative integer" ;;
  esac
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    die "jq not found; cannot compute budget-check result"
  fi
}

# ---- derive (raw table; MUST NOT read AUTOPILOT_*_CAP) ----------------------
if [ "${1:-}" = "derive" ]; then
  [ $# -eq 4 ] || die "derive requires exactly 3 arguments after 'derive' (got $(($# - 1)))"
  TASKS="$2"
  PROJECTED_LOC="$3"
  WAVES="$4"
  require_nnint tasks "$TASKS"
  require_nnint projected_loc "$PROJECTED_LOC"
  require_nnint waves "$WAVES"
  require_jq
  # L first, then S, else M. Auto-tune MUST NOT grant >40 / >4500.
  if [ "$TASKS" -ge 6 ] || [ "$PROJECTED_LOC" -gt 1000 ] || [ "$WAVES" -ge 3 ]; then
    TIER=L
    ITERATION_CAP=40
    WALL_CLOCK_CAP_S=4500
  elif [ "$TASKS" -le 3 ] && [ "$PROJECTED_LOC" -le 300 ] && [ "$WAVES" -eq 1 ]; then
    TIER=S
    ITERATION_CAP=10
    WALL_CLOCK_CAP_S=1200
  else
    TIER=M
    ITERATION_CAP=25
    WALL_CLOCK_CAP_S=2700
  fi
  jq -cn \
    --arg tier "$TIER" \
    --argjson iteration_cap "$ITERATION_CAP" \
    --argjson wall_clock_cap_s "$WALL_CLOCK_CAP_S" \
    --argjson tasks "$TASKS" \
    --argjson projected_loc "$PROJECTED_LOC" \
    --argjson waves "$WAVES" \
    '{
      tier: $tier,
      iteration_cap: $iteration_cap,
      wall_clock_cap_s: $wall_clock_cap_s,
      signals: {tasks: $tasks, projected_loc: $projected_loc, waves: $waves}
    }'
  exit 0
fi

# ---- check argc 2 | 4 (argc=3 stays 64) -------------------------------------
case $# in
  2|4) ;;
  *) die "budget-check.sh requires 2 or 4 arguments, or derive (got $#)" ;;
esac

ITERATION="$1"
RUN_START_EPOCH="$2"
require_nnint iteration "$ITERATION"
require_nnint run_start_epoch "$RUN_START_EPOCH"

if [ $# -eq 4 ]; then
  # Verbatim freeze. MUST NOT re-read AUTOPILOT_*_CAP.
  ITERATION_CAP="$3"
  WALL_CLOCK_CAP_S="$4"
  require_nnint iteration_cap "$ITERATION_CAP"
  require_nnint wall_clock_cap_s "$WALL_CLOCK_CAP_S"
else
  ITERATION_CAP=25
  if [ -n "${AUTOPILOT_ITERATION_CAP:-}" ]; then
    require_nnint AUTOPILOT_ITERATION_CAP "$AUTOPILOT_ITERATION_CAP"
    ITERATION_CAP="$AUTOPILOT_ITERATION_CAP"
  fi
  WALL_CLOCK_CAP_S=2700
  if [ -n "${AUTOPILOT_WALLCLOCK_CAP:-}" ]; then
    require_nnint AUTOPILOT_WALLCLOCK_CAP "$AUTOPILOT_WALLCLOCK_CAP"
    WALL_CLOCK_CAP_S="$AUTOPILOT_WALLCLOCK_CAP"
  fi
fi

NOW=$(date +%s)
[ "$RUN_START_EPOCH" -gt "$NOW" ] && die "run_start_epoch '$RUN_START_EPOCH' is in the future (now=$NOW)"

require_jq

WALL_CLOCK_S=$((NOW - RUN_START_EPOCH))

ITERATION_BREACH=false
[ "$ITERATION" -ge "$ITERATION_CAP" ] && ITERATION_BREACH=true

WALLCLOCK_BREACH=false
[ "$WALL_CLOCK_S" -ge "$WALL_CLOCK_CAP_S" ] && WALLCLOCK_BREACH=true

case "${ITERATION_BREACH}:${WALLCLOCK_BREACH}" in
  true:true)  REASON="both" ;;
  true:false) REASON="iteration" ;;
  false:true) REASON="wall_clock" ;;
  *)          REASON="none" ;;
esac

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
