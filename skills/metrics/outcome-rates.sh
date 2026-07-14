#!/usr/bin/env bash
#
# metrics/outcome-rates.sh — SPEC-026 M5 advisory rates helper.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   outcome-rates.sh <agent> <task_class> [--json]
#
# Reads $MROOT/.claude/metrics/outcomes.jsonl (all-time), filters records where
# agent and task_class match and task_class is non-null. Skips malformed lines.
# Computes n, escalated_count, escalated_rate, mean_review_cycles (null cycles
# excluded from the mean denominator).
#
# When n ≥ MIN_SAMPLES (OUTCOME_MIN_SAMPLES or 5) AND (rate ≥ 0.5 OR mean ≥ 2.0)
# and an M8-legal alternative exists, prints one Advisory: line to stdout.
#
# Cold start / no jq / missing-empty ledger / below threshold / no legal alt:
# empty stdout, exit 0 (silence). Failures never block orchestration.
#
# --json: emit machine-readable rates for tests even when advisory is false:
#   {n, escalated_count, escalated_rate, mean_review_cycles, advisory, alt}
#
# Exit codes:
#   0   success or silence (always non-fatal for orchestration)
#  64   usage error

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

# ---- Usage ------------------------------------------------------------------
JSON_MODE=0
AGENT=""
TASK_CLASS=""

usage() {
  echo "error: outcome-rates.sh requires <agent> <task_class> [--json]" >&2
  echo "Usage: outcome-rates.sh <agent> <task_class> [--json]" >&2
  exit 64
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [ -z "$AGENT" ]; then
        AGENT="$1"
      elif [ -z "$TASK_CLASS" ]; then
        TASK_CLASS="$1"
      else
        usage
      fi
      shift
      ;;
  esac
done

if [ -z "$AGENT" ] || [ -z "$TASK_CLASS" ]; then
  usage
fi

# ---- jq guard (M9) ----------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# ---- resolve_mroot ----------------------------------------------------------
resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

# ---- M8 alt selection -------------------------------------------------------
# ic4 → ic5; ic5 → ic4 unless impl-novel; local → Claude; else none.
select_alt() {
  local agent="$1" task_class="$2"
  case "$agent" in
    ic4)
      printf '%s' "ic5"
      ;;
    ic5)
      if [ "$task_class" = "impl-novel" ]; then
        printf '%s' ""
      else
        printf '%s' "ic4"
      fi
      ;;
    local)
      printf '%s' "Claude"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

# ---- MIN_SAMPLES (OQ5) ------------------------------------------------------
MIN_SAMPLES="${OUTCOME_MIN_SAMPLES:-5}"
case "$MIN_SAMPLES" in
  ''|*[!0-9]*) MIN_SAMPLES=5 ;;
esac

resolve_mroot
LEDGER="$MROOT/.claude/metrics/outcomes.jsonl"
ALT="$(select_alt "$AGENT" "$TASK_CLASS")"

# Missing / empty ledger → cold-start silence (M7); --json still reports zeros.
if [ ! -f "$LEDGER" ] || [ ! -s "$LEDGER" ]; then
  if [ "$JSON_MODE" -eq 1 ]; then
    jq -cn \
      --argjson n 0 \
      --argjson escalated_count 0 \
      --argjson escalated_rate 0 \
      --argjson mean_review_cycles 0 \
      --argjson advisory false \
      --arg alt "$ALT" \
      '{
        n: $n,
        escalated_count: $escalated_count,
        escalated_rate: $escalated_rate,
        mean_review_cycles: $mean_review_cycles,
        advisory: $advisory,
        alt: (if ($alt | length) > 0 then $alt else null end)
      }'
  fi
  exit 0
fi

# ---- Aggregate (OQ6 all-time; skip bad lines) -------------------------------
# try fromjson catch empty skips corrupt JSONL lines (M9).
STATS="$(
  jq -n -R \
    --arg agent "$AGENT" \
    --arg tc "$TASK_CLASS" \
    --argjson min "$MIN_SAMPLES" \
    --arg alt "$ALT" \
    '
    [inputs
      | select(length > 0)
      | try fromjson catch empty
      | select(
          type == "object"
          and .agent == $agent
          and (.task_class | type == "string")
          and .task_class == $tc
        )
    ] as $rows
    | ($rows | length) as $n
    | ($rows | map(select(.outcome == "escalated")) | length) as $e
    | [ $rows[].review_cycles | select(. != null) ] as $cycles
    | (if $n == 0 then 0 else ($e / $n) end) as $rate
    | (if ($cycles | length) == 0 then 0
       else (($cycles | add) / ($cycles | length)) end) as $mean
    | ($alt | length > 0) as $has_alt
    | {
        n: $n,
        escalated_count: $e,
        escalated_rate: $rate,
        mean_review_cycles: $mean,
        advisory: (
          $n >= $min
          and ($rate >= 0.5 or $mean >= 2.0)
          and $has_alt
        ),
        alt: (if $has_alt then $alt else null end)
      }
    ' <"$LEDGER" 2>/dev/null
)" || STATS=""

# Any jq failure → silent fallback (M9)
if [ -z "$STATS" ]; then
  exit 0
fi

ADVISORY="$(printf '%s' "$STATS" | jq -r '.advisory')"
N="$(printf '%s' "$STATS" | jq -r '.n')"
E="$(printf '%s' "$STATS" | jq -r '.escalated_count')"
MEAN="$(printf '%s' "$STATS" | jq -r '.mean_review_cycles')"
ALT_OUT="$(printf '%s' "$STATS" | jq -r '.alt // empty')"

if [ "$JSON_MODE" -eq 1 ]; then
  printf '%s\n' "$STATS"
  exit 0
fi

# Human advisory only when thresholds + legal alt met (M5/M7/M8)
if [ "$ADVISORY" != "true" ]; then
  exit 0
fi

# Format mean to one decimal for the advisory line
MEAN_FMT="$(printf '%.1f' "$MEAN" 2>/dev/null || echo "$MEAN")"

printf 'Advisory: %s escalated %s/%s %s-class tasks (mean %s TL cycles, %s samples) — consider %s. Static rule keeps %s unless you accept.\n' \
  "$AGENT" "$E" "$N" "$TASK_CLASS" "$MEAN_FMT" "$N" "$ALT_OUT" "$AGENT"

exit 0
