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
# CDT-126 — council_tier / grading_reason (M13, additive + nullable):
#   * Cards written before the amendment omit both keys. M13 defines absent ≡
#     null, so this reader materializes that equivalence: missing keys are
#     backfilled as explicit nulls in their frozen position (right after
#     blocking_condition), and every card in the output array therefore has the
#     full M13 shape regardless of when it was written.
#   * The reader also re-checks append-card.sh cross-field invariant (c) —
#     council_tier/grading_reason non-null ⟹ gate == "ship-choice". The writer
#     is the only legitimate producer of this file and already enforces (c), so
#     a violation means a hand-edited or corrupt ledger; this pair treats an
#     untrustworthy audit trail as a hard failure, not something to pass through.
#
# CDT-223 — max_loc (M13/M16, additive + nullable):
#   * Absent max_loc is backfilled as explicit null immediately after
#     grading_reason (before rationale). Pre-CDT-126 cards (no council pair)
#     still receive the council-pair backfill AND max_loc. schema_version stays 1.
#
# CDT-224 — nested budget.{tier,source,signals} (M13/M9b, additive + nullable):
#   * Absent nested keys are backfilled as explicit null after wall_clock_cap_s
#     in frozen order (tier, source, signals). Pre-CDT-224 4-key budget objects
#     remain valid (absent ≡ null). Top-level key count stays 18.
#
# Exit codes:
#   0   success (including the empty/missing-ledger case)
#  64   usage error (wrong argc), jq absent, unparseable ledger, or a card
#       violating the M13 cross-field invariant

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

# ---- Parse + backfill the M13 nullable keys (CDT-126, CDT-223, CDT-224) -----
# Insert council_tier/grading_reason as explicit nulls right after
# blocking_condition when absent, then max_loc after grading_reason, so legacy
# cards read back in the frozen M13 key order rather than silently lacking keys.
# Nested budget.tier/source/signals: absent ≡ null after wall_clock_cap_s.
if ! cards=$(jq -s '
  def insert_after($after; $pairs):
    to_entries
    | map(if .key == $after then ., $pairs[] else . end)
    | from_entries;
  def ensure_null($key; $after):
    if has($key) then . else insert_after($after; [{key: $key, value: null}]) end;
  map(
    if type != "object" then .
    else
      (if has("council_tier") then .
       else insert_after("blocking_condition"; [
              {key: "council_tier", value: null},
              {key: "grading_reason", value: null}
            ])
       end)
      | ensure_null("max_loc"; "grading_reason")
      | (if (has("budget") and (.budget | type) == "object") then
           .budget |= (
             ensure_null("tier"; "wall_clock_cap_s")
             | ensure_null("source"; "tier")
             | ensure_null("signals"; "source")
           )
         else .
         end)
    end
  )
' "$ledger_file" 2>/dev/null); then
  echo "error: failed to parse $ledger_file" >&2
  exit 64
fi

# ---- M13 cross-field invariant (c) — mirror of append-card.sh ---------------
if ! printf '%s' "$cards" | jq -e '
  all(
    if type == "object"
    then ((.council_tier == null) and (.grading_reason == null))
         or (.gate == "ship-choice")
    else true
    end
  )
' >/dev/null 2>&1; then
  echo "error: $ledger_file has a card with council_tier/grading_reason on a non-ship-choice gate" >&2
  exit 64
fi

printf '%s\n' "$cards"

exit 0
