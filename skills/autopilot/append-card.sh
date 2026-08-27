#!/usr/bin/env bash
#
# autopilot/append-card.sh — SPEC-033 AC6/M13 decision-card writer.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   append-card.sh <workflow> <ticket_id> <gate> <decision> <decided_by> \
#                  <bump|null> <confidence> <blocking_condition|null> \
#                  <run_id> <iteration> <wall_clock_s> <actor> <rationale> \
#                  [<max_loc|null> | <council_tier|null> <grading_reason|null> \
#                   [<max_loc|null>]]
#
# Appends ONE JSONL decision card to $MROOT/.claude/autopilot/<ticket_id>.jsonl
# with the M13-frozen key order:
#   { schema_version, type, ts, run_id, workflow, ticket_id, gate, decision,
#     decided_by, bump, confidence, blocking_condition, council_tier,
#     grading_reason, max_loc, rationale, budget, actor }
#   budget = { iteration, iteration_cap, wall_clock_s, wall_clock_cap_s,
#              tier, source, signals }
#
# CDT-126: council_tier / grading_reason are additive + nullable, so argc 13 is
# still legal and means both are null (schema_version stays 1).
# CDT-223: max_loc is additive + nullable in the same envelope (18 keys).
# CDT-224: nested budget.{tier,source,signals} additive + nullable (still 18
# top-level keys). Snapshot via process-local AUTOPILOT_BUDGET_META; MUST NOT
# export META; MUST NOT write AUTOPILOT_*_CAP.
# Argc is 13 (all optionals null) | 14 (max_loc, council pair null) |
# 15 (council pair, max_loc null) | 16 (council pair + max_loc).
# Any other argc → 64. Council_tier without grading_reason is not a valid shape.
#
# DELIBERATE INVERSION of metrics/emit-outcome.sh best-effort semantics:
# this writer HARD-FAILS (exit 64) on EVERY failure mode — malformed args,
# invalid enum/range, cross-field-invariant violation, control chars in
# rationale, jq absent, mkdir/write failure. It NEVER exits 0 on failure.
# The decision-card audit trail must be trustworthy; a silently-dropped card
# is worse than a loud abort.
#
# Exit codes:
#   0   success (one card appended)
#  64   ANY failure (usage / validation / jq absent / mkdir / write)

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: append-card.sh <workflow> <ticket_id> <gate> <decision> <decided_by> <bump|null> <confidence> <blocking_condition|null> <run_id> <iteration> <wall_clock_s> <actor> <rationale> [<max_loc|null> | <council_tier|null> <grading_reason|null> [<max_loc|null>]]'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

# ---- Usage ------------------------------------------------------------------
# 13: all optionals null · 14: max_loc, council pair null
# 15: council pair, max_loc null · 16: council pair + max_loc
case $# in
  13|14|15|16) ;;
  *) die "append-card.sh requires 13, 14, 15, or 16 arguments (got $#)" ;;
esac

WORKFLOW="$1"
TICKET_ID="$2"
GATE="$3"
DECISION="$4"
DECIDED_BY="$5"
BUMP="$6"
CONFIDENCE="$7"
BLOCKING_CONDITION="$8"
RUN_ID="$9"
ITERATION="${10}"
WALL_CLOCK_S="${11}"
ACTOR="${12}"
RATIONALE="${13}"
COUNCIL_TIER=null
GRADING_REASON=null
MAX_LOC=null
if [ $# -ge 15 ]; then
  COUNCIL_TIER="${14}"
  GRADING_REASON="${15}"
fi
if [ $# -eq 14 ]; then
  MAX_LOC="${14}"
elif [ $# -eq 16 ]; then
  MAX_LOC="${16}"
fi

# ---- Required non-empty string fields ---------------------------------------
[ -z "$TICKET_ID" ] && die "ticket_id must not be empty"
# Path-safety: ticket_id is concatenated into card_file below. Match the repo
# convention (skills/ci-watch/sidecar.sh:38, skills/worktree-lib.sh:184) — no
# dots, no slashes — so a value like "../../tmp/evil" cannot escape .claude/autopilot/.
case "$TICKET_ID" in *[!A-Za-z0-9_-]*) die "ticket_id must match ^[A-Za-z0-9_-]+$" ;; esac
[ -z "$RUN_ID" ]    && die "run_id must not be empty"
[ -z "$ACTOR" ]     && die "actor must not be empty"

# ---- Enum guards (5) --------------------------------------------------------
case "$WORKFLOW" in
  orchestrate|kickoff|epic) ;;
  *) die "invalid workflow '$WORKFLOW' (expected orchestrate|kickoff|epic)" ;;
esac

case "$GATE" in
  scope-confirm|plan-approve|ship-choice) ;;
  *) die "invalid gate '$GATE' (expected scope-confirm|plan-approve|ship-choice)" ;;
esac

case "$DECISION" in
  proceed|approve|pr|merge|reroute-epic|halt) ;;
  *) die "invalid decision '$DECISION' (expected proceed|approve|pr|merge|reroute-epic|halt)" ;;
esac

case "$DECIDED_BY" in
  auto|user) ;;
  *) die "invalid decided_by '$DECIDED_BY' (expected auto|user)" ;;
esac

case "$BUMP" in
  patch|minor|major|master|null) ;;
  *) die "invalid bump '$BUMP' (expected patch|minor|major|master|null)" ;;
esac

# council_tier vocabulary is SPEC-013's (Council tiering), not this spec's (M13/N4).
case "$COUNCIL_TIER" in
  skip|light|full|null) ;;
  *) die "invalid council_tier '$COUNCIL_TIER' (expected skip|light|full|null)" ;;
esac

# ---- Numeric-range guards ---------------------------------------------------
# confidence: integer 0..100
case "$CONFIDENCE" in
  ''|*[!0-9]*) die "confidence '$CONFIDENCE' must be an integer 0..100" ;;
esac
[ "$CONFIDENCE" -gt 100 ] && die "confidence '$CONFIDENCE' out of range (0..100)"

# blocking_condition: literal null or integer 1..8
if [ "$BLOCKING_CONDITION" != "null" ]; then
  case "$BLOCKING_CONDITION" in
    ''|*[!0-9]*) die "blocking_condition '$BLOCKING_CONDITION' must be null or 1..8" ;;
  esac
  { [ "$BLOCKING_CONDITION" -lt 1 ] || [ "$BLOCKING_CONDITION" -gt 8 ]; } \
    && die "blocking_condition '$BLOCKING_CONDITION' out of range (1..8)"
fi

# iteration / wall_clock_s: non-negative integers
case "$ITERATION" in
  ''|*[!0-9]*) die "iteration '$ITERATION' must be a non-negative integer" ;;
esac
case "$WALL_CLOCK_S" in
  ''|*[!0-9]*) die "wall_clock_s '$WALL_CLOCK_S' must be a non-negative integer" ;;
esac

# max_loc: null | unbound | ^[1-9][0-9]*$  (JSON null / string / number)
# Legal on every gate (unlike council_tier). 0 / leading-zero / junk → 64.
case "$MAX_LOC" in
  null|unbound) ;;
  ''|*[!0-9]*|0*) die "invalid max_loc '$MAX_LOC' (expected null|unbound|^[1-9][0-9]*$)" ;;
esac

# ---- Cross-field invariants (M13) -------------------------------------------
# (a) bump non-null ONLY on a ship-choice card.
if [ "$BUMP" != "null" ] && [ "$GATE" != "ship-choice" ]; then
  die "bump '$BUMP' requires gate=ship-choice (got '$GATE')"
fi
# (b) blocking_condition=7 (BC7) requires confidence below the threshold (<80).
if [ "$BLOCKING_CONDITION" = "7" ] && [ "$CONFIDENCE" -ge 80 ]; then
  die "blocking_condition=7 requires confidence < 80 (got $CONFIDENCE)"
fi
# (c) council_tier / grading_reason non-null ONLY on a ship-choice card (CDT-126).
# Deliberately weaker than M13's prose rule, which scopes them to the M14 council
# card (ship-choice card #2) alone. Cards #1 and #2 share gate/run_id/decided_by
# and M13 defines no write-time discriminator, so a stricter writer check would
# have to invent one (N4). The narrower rule is enforced by the caller —
# skills/autopilot/ship-gate-council.md §6, which passes null/null on card #1.
if { [ "$COUNCIL_TIER" != "null" ] || [ "$GRADING_REASON" != "null" ]; } \
   && [ "$GATE" != "ship-choice" ]; then
  die "council_tier/grading_reason require gate=ship-choice (got '$GATE')"
fi

# ---- rationale control-char guard -------------------------------------------
# Reject any newline / control character (secret-scrubbing is the caller's job).
# NOTE: a piped `grep '[[:cntrl:]]'` can't catch newlines (grep splits input on
# them, so an embedded \n is never seen as line content). Bash's [[ =~ ]] tests
# the whole string — newlines included — so it catches \n as well as \t etc.
if [[ "$RATIONALE" =~ [[:cntrl:]] ]]; then
  die "rationale must not contain newlines or control characters"
fi
# grading_reason carries the same one-line + redaction obligation as rationale (M13).
if [[ "$GRADING_REASON" =~ [[:cntrl:]] ]]; then
  die "grading_reason must not contain newlines or control characters"
fi

# ---- jq guard (HARD FAIL — divergence from emit-outcome.sh) ------------------
if ! command -v jq >/dev/null 2>&1; then
  die "jq not found; cannot write decision card"
fi

# ---- resolve_mroot (copied from metrics/emit-outcome.sh) --------------------
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

# max_loc: JSON null, string "unbound", or a JSON number.
json_max_loc() {
  case "$1" in
    null) printf '%s' 'null' ;;
    unbound) printf '%s' '"unbound"' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---- Writer-derived fields --------------------------------------------------
# CDT-224 / M9b: AUTOPILOT_BUDGET_META (compact JSON) is process-local only.
# MUST NOT export it. MUST NOT write AUTOPILOT_ITERATION_CAP / AUTOPILOT_WALLCLOCK_CAP.
# Set → numeric caps + nested keys verbatim (do not also apply AUTOPILOT_*_CAP).
# Unset → nested JSON null; numerics from env-or-default as today.
# Malformed META → 64.
if [ -n "${AUTOPILOT_BUDGET_META:-}" ]; then
  if ! parsed=$(printf '%s' "$AUTOPILOT_BUDGET_META" | jq -ce '
    select(
      type == "object"
      and has("iteration_cap") and has("wall_clock_cap_s")
      and has("tier") and has("source") and has("signals")
      and (.iteration_cap | type == "number" and . == floor and . >= 0)
      and (.wall_clock_cap_s | type == "number" and . == floor and . >= 0)
      and (.tier == null or .tier == "S" or .tier == "M" or .tier == "L")
      and (.source == null or .source == "auto" or .source == "env"
           or .source == "default" or .source == "mixed")
      and (
        .signals == null
        or (
          (.signals | type) == "object"
          and (.signals | has("tasks") and has("projected_loc") and has("waves"))
        )
      )
    )
  ' 2>/dev/null); then
    die "malformed AUTOPILOT_BUDGET_META"
  fi
  ITERATION_CAP=$(printf '%s' "$parsed" | jq -c '.iteration_cap')
  WALL_CLOCK_CAP_S=$(printf '%s' "$parsed" | jq -c '.wall_clock_cap_s')
  BUDGET_TIER_JSON=$(printf '%s' "$parsed" | jq -c '.tier')
  BUDGET_SOURCE_JSON=$(printf '%s' "$parsed" | jq -c '.source')
  BUDGET_SIGNALS_JSON=$(printf '%s' "$parsed" | jq -c '.signals')
else
  ITERATION_CAP=${AUTOPILOT_ITERATION_CAP:-25}
  WALL_CLOCK_CAP_S=${AUTOPILOT_WALLCLOCK_CAP:-2700}
  BUDGET_TIER_JSON=null
  BUDGET_SOURCE_JSON=null
  BUDGET_SIGNALS_JSON=null
fi
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

bump_json=$(json_str_or_null "$BUMP")
council_tier_json=$(json_str_or_null "$COUNCIL_TIER")
grading_reason_json=$(json_str_or_null "$GRADING_REASON")
max_loc_json=$(json_max_loc "$MAX_LOC")

# ---- Emit (HARD FAIL on mkdir/jq/write) -------------------------------------
resolve_mroot

autopilot_dir="$MROOT/.claude/autopilot"
card_file="$autopilot_dir/$TICKET_ID.jsonl"

if ! mkdir -p "$autopilot_dir" 2>/dev/null; then
  die "cannot create $autopilot_dir"
fi

# PIPE_BUF: each card is a single compact line well under PIPE_BUF (>=512 on
# POSIX, 4096 on Linux), so a single O_APPEND write >> is atomic w.r.t.
# interleaving under concurrent appends — no flock needed at this scale.
if ! jq -cn \
  --argjson schema_version 1 \
  --arg ts "$ts" \
  --arg run_id "$RUN_ID" \
  --arg workflow "$WORKFLOW" \
  --arg ticket_id "$TICKET_ID" \
  --arg gate "$GATE" \
  --arg decision "$DECISION" \
  --arg decided_by "$DECIDED_BY" \
  --argjson bump "$bump_json" \
  --argjson confidence "$CONFIDENCE" \
  --argjson blocking_condition "$BLOCKING_CONDITION" \
  --argjson council_tier "$council_tier_json" \
  --argjson grading_reason "$grading_reason_json" \
  --argjson max_loc "$max_loc_json" \
  --arg rationale "$RATIONALE" \
  --argjson iteration "$ITERATION" \
  --argjson iteration_cap "$ITERATION_CAP" \
  --argjson wall_clock_s "$WALL_CLOCK_S" \
  --argjson wall_clock_cap_s "$WALL_CLOCK_CAP_S" \
  --argjson budget_tier "$BUDGET_TIER_JSON" \
  --argjson budget_source "$BUDGET_SOURCE_JSON" \
  --argjson budget_signals "$BUDGET_SIGNALS_JSON" \
  --arg actor "$ACTOR" \
  '{
    schema_version: $schema_version,
    type: "autopilot_decision",
    ts: $ts,
    run_id: $run_id,
    workflow: $workflow,
    ticket_id: $ticket_id,
    gate: $gate,
    decision: $decision,
    decided_by: $decided_by,
    bump: $bump,
    confidence: $confidence,
    blocking_condition: $blocking_condition,
    council_tier: $council_tier,
    grading_reason: $grading_reason,
    max_loc: $max_loc,
    rationale: $rationale,
    budget: {
      iteration: $iteration,
      iteration_cap: $iteration_cap,
      wall_clock_s: $wall_clock_s,
      wall_clock_cap_s: $wall_clock_cap_s,
      tier: $budget_tier,
      source: $budget_source,
      signals: $budget_signals
    },
    actor: $actor
  }' \
  >> "$card_file" 2>/dev/null
then
  die "cannot write decision card to $card_file"
fi

exit 0
