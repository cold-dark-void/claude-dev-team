#!/usr/bin/env bash
#
# local-agent/emit-orch-metric.sh — PR2 companion metrics helper.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   emit-orch-metric.sh <ticket> <saved_est_tokens|null> <spent_review_escalation|null>
#
# Appends ONE JSONL record to $MROOT/.claude/local-agent/metrics.jsonl:
#   { ts, ticket, saved_est_tokens, spent_review_escalation }
#
# <saved_est_tokens> and <spent_review_escalation> are JSON values — pass the
# literal number or the word "null" (serialized as JSON null, NOT a string).
# <ticket> is always a string.
#
# jq-guarded: if jq is absent, exits 0 silently (no record written).
# Best-effort / non-fatal: metric failure MUST NOT be a hard error (always
# returns 0 after a usage-error check).
#
# Exit codes:
#   0   success or jq absent or best-effort failure (non-fatal)
#  64   usage error (wrong argument count)

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

# ---- Usage ------------------------------------------------------------------
if [ $# -ne 3 ]; then
  echo "error: emit-orch-metric.sh requires exactly 3 arguments: <ticket> <saved_est_tokens|null> <spent_review_escalation|null>" >&2
  echo "Usage: emit-orch-metric.sh <ticket> <saved_est|null> <spent_review_escalation|null>" >&2
  exit 64
fi

TICKET="$1"
SAVED_EST="$2"
SPENT_RE="$3"

# ---- jq guard ---------------------------------------------------------------
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

# ---- Emit -------------------------------------------------------------------
{
  resolve_mroot

  local_dir="$MROOT/.claude/local-agent"
  local_file="$local_dir/metrics.jsonl"
  mkdir -p "$local_dir" 2>/dev/null

  ts=$(date +%s)

  jq -cn \
    --argjson ts "$ts" \
    --arg ticket "$TICKET" \
    --argjson saved_est "$SAVED_EST" \
    --argjson spent_re "$SPENT_RE" \
    '{ts: $ts, ticket: $ticket, saved_est_tokens: $saved_est, spent_review_escalation: $spent_re}' \
    >> "$local_file" 2>/dev/null
} 2>/dev/null || true

exit 0
