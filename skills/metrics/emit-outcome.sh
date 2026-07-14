#!/usr/bin/env bash
#
# metrics/emit-outcome.sh — SPEC-026 review-outcome ledger writer.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   emit-outcome.sh <ticket|null> <task_id|null> <agent> <task_class|null> \
#                   <size|null> <outcome> <review_cycles|null> \
#                   <qa_bounces|null> <council_overturns|null>
#
# Appends ONE JSONL record to $MROOT/.claude/metrics/outcomes.jsonl:
#   { ts, ticket, task_id, agent, task_class, size, outcome,
#     review_cycles, qa_bounces, council_overturns }
#
# String/number args accept the literal word "null" → JSON null (not a string).
# <agent> and <outcome> are required enums (never null).
# Pure-arg: council_overturns is caller-supplied (no auto index count).
#
# Exit codes:
#   0   success, jq absent, or best-effort failure (non-fatal)
#  64   usage error (wrong argc / invalid agent / invalid outcome)

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: emit-outcome.sh <ticket|null> <task_id|null> <agent> <task_class|null> <size|null> <outcome> <review_cycles|null> <qa_bounces|null> <council_overturns|null>'

# ---- Usage ------------------------------------------------------------------
if [ $# -ne 9 ]; then
  echo "error: emit-outcome.sh requires exactly 9 arguments" >&2
  echo "$USAGE" >&2
  exit 64
fi

TICKET="$1"
TASK_ID="$2"
AGENT="$3"
TASK_CLASS="$4"
SIZE="$5"
OUTCOME="$6"
REVIEW_CYCLES="$7"
QA_BOUNCES="$8"
COUNCIL_OVERTURNS="$9"

# ---- Validate enums ---------------------------------------------------------
case "$AGENT" in
  ic4|ic5|qa|devops|ds|local) ;;
  *)
    echo "error: invalid agent '$AGENT' (expected ic4|ic5|qa|devops|ds|local)" >&2
    echo "$USAGE" >&2
    exit 64
    ;;
esac

case "$OUTCOME" in
  accepted|escalated|rejected) ;;
  *)
    echo "error: invalid outcome '$OUTCOME' (expected accepted|escalated|rejected)" >&2
    echo "$USAGE" >&2
    exit 64
    ;;
esac

# ---- jq guard (M9: one-line stderr notice, exit 0, no write) ----------------
if ! command -v jq >/dev/null 2>&1; then
  echo "emit-outcome: jq not found; skipping ledger write" >&2
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

# Literal "null" → JSON null; else JSON-encode as string via jq.
json_str_or_null() {
  if [ "$1" = "null" ]; then
    printf '%s' 'null'
  else
    jq -cn --arg v "$1" '$v'
  fi
}

# Literal "null" → JSON null; else pass through as JSON number/value for --argjson.
json_num_or_null() {
  if [ "$1" = "null" ]; then
    printf '%s' 'null'
  else
    printf '%s' "$1"
  fi
}

# ---- Emit (best-effort / non-fatal) -----------------------------------------
resolve_mroot

metrics_dir="$MROOT/.claude/metrics"
metrics_file="$metrics_dir/outcomes.jsonl"

if ! mkdir -p "$metrics_dir" 2>/dev/null; then
  echo "emit-outcome: cannot create $metrics_dir; skipping ledger write" >&2
  exit 0
fi

ts=$(date +%s)

ticket_json=$(json_str_or_null "$TICKET")
task_id_json=$(json_str_or_null "$TASK_ID")
task_class_json=$(json_str_or_null "$TASK_CLASS")
size_json=$(json_str_or_null "$SIZE")
review_cycles_json=$(json_num_or_null "$REVIEW_CYCLES")
qa_bounces_json=$(json_num_or_null "$QA_BOUNCES")
council_overturns_json=$(json_num_or_null "$COUNCIL_OVERTURNS")

if ! jq -cn \
  --argjson ts "$ts" \
  --argjson ticket "$ticket_json" \
  --argjson task_id "$task_id_json" \
  --arg agent "$AGENT" \
  --argjson task_class "$task_class_json" \
  --argjson size "$size_json" \
  --arg outcome "$OUTCOME" \
  --argjson review_cycles "$review_cycles_json" \
  --argjson qa_bounces "$qa_bounces_json" \
  --argjson council_overturns "$council_overturns_json" \
  '{
    ts: $ts,
    ticket: $ticket,
    task_id: $task_id,
    agent: $agent,
    task_class: $task_class,
    size: $size,
    outcome: $outcome,
    review_cycles: $review_cycles,
    qa_bounces: $qa_bounces,
    council_overturns: $council_overturns
  }' \
  >> "$metrics_file" 2>/dev/null
then
  echo "emit-outcome: cannot write $metrics_file; skipping ledger write" >&2
  exit 0
fi

exit 0
