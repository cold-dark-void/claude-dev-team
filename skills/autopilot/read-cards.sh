#!/usr/bin/env bash
#
# autopilot/read-cards.sh — SPEC-033 M13 decision-card ledger reader.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   read-cards.sh <ticket_id>
#
# Reads $MROOT/.claude/autopilot/<ticket_id>.jsonl (one JSON object per line,
# written by skills/autopilot/append-card.sh) and prints all cards as a single
# JSON array on stdout.
#
# A ticket with no decisions yet is a valid, normal state (not an error):
# missing or empty ledger file → print `[]`, exit 0.
#
# Exit codes:
#   0   success (including the empty/missing-ledger case)
#  64   usage error (wrong argc) or jq absent

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: read-cards.sh <ticket_id>'

# ---- Usage ------------------------------------------------------------------
if [ $# -ne 1 ]; then
  echo "error: read-cards.sh requires exactly 1 argument" >&2
  echo "$USAGE" >&2
  exit 64
fi

TICKET_ID="$1"

# ---- jq guard (hard requirement — divergence from emit-outcome.sh precedent) -
if ! command -v jq >/dev/null 2>&1; then
  echo "error: read-cards.sh requires jq" >&2
  exit 64
fi

# ---- ticket_id validation (path-traversal guard) -----------------------------
case "$TICKET_ID" in
  *[!A-Za-z0-9_-]*) echo "error: ticket_id must match ^[A-Za-z0-9_-]+$" >&2; exit 64 ;;
esac

# ---- resolve_mroot ----------------------------------------------------------
resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

resolve_mroot

ledger_file="$MROOT/.claude/autopilot/$TICKET_ID.jsonl"

# ---- Missing/empty ledger → empty array, not an error -----------------------
if [ ! -s "$ledger_file" ]; then
  echo '[]'
  exit 0
fi

if ! jq -s '.' "$ledger_file"; then
  echo "error: failed to parse $ledger_file" >&2
  exit 64
fi

exit 0
