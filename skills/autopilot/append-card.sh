#!/usr/bin/env bash
#
# autopilot/append-card.sh — SPEC-033 AC6/M13 decision-card writer.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   append-card.sh <workflow> <ticket_id> <gate> <decision> <decided_by> \
#                  <bump|null> <confidence> <blocking_condition|null> \
#                  <run_id> <iteration> <wall_clock_s> <actor> <rationale>
#
# Appends ONE JSONL decision card to $MROOT/.claude/autopilot/<ticket_id>.jsonl
# with the M13-frozen key order:
#   { schema_version, type, ts, run_id, workflow, ticket_id, gate, decision,
#     decided_by, bump, confidence, blocking_condition, rationale, budget, actor }
#   budget = { iteration, iteration_cap, wall_clock_s, wall_clock_cap_s }
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

USAGE='Usage: append-card.sh <workflow> <ticket_id> <gate> <decision> <decided_by> <bump|null> <confidence> <blocking_condition|null> <run_id> <iteration> <wall_clock_s> <actor> <rationale>'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

# ---- Usage ------------------------------------------------------------------
[ $# -ne 13 ] && die "append-card.sh requires exactly 13 arguments (got $#)"

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
  patch|minor|major|null) ;;
  *) die "invalid bump '$BUMP' (expected patch|minor|major|null)" ;;
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

# ---- Cross-field invariants (M13) -------------------------------------------
# (a) bump non-null ONLY on a ship-choice card.
if [ "$BUMP" != "null" ] && [ "$GATE" != "ship-choice" ]; then
  die "bump '$BUMP' requires gate=ship-choice (got '$GATE')"
fi
# (b) blocking_condition=7 (BC7) requires confidence below the threshold (<80).
if [ "$BLOCKING_CONDITION" = "7" ] && [ "$CONFIDENCE" -ge 80 ]; then
  die "blocking_condition=7 requires confidence < 80 (got $CONFIDENCE)"
fi

# ---- rationale control-char guard -------------------------------------------
# Reject any newline / control character (secret-scrubbing is the caller's job).
# NOTE: a piped `grep '[[:cntrl:]]'` can't catch newlines (grep splits input on
# them, so an embedded \n is never seen as line content). Bash's [[ =~ ]] tests
# the whole string — newlines included — so it catches \n as well as \t etc.
if [[ "$RATIONALE" =~ [[:cntrl:]] ]]; then
  die "rationale must not contain newlines or control characters"
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

# ---- Writer-derived fields --------------------------------------------------
ITERATION_CAP=${AUTOPILOT_ITERATION_CAP:-25}
WALL_CLOCK_CAP_S=${AUTOPILOT_WALLCLOCK_CAP:-2700}
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

bump_json=$(json_str_or_null "$BUMP")

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
  --arg rationale "$RATIONALE" \
  --argjson iteration "$ITERATION" \
  --argjson iteration_cap "$ITERATION_CAP" \
  --argjson wall_clock_s "$WALL_CLOCK_S" \
  --argjson wall_clock_cap_s "$WALL_CLOCK_CAP_S" \
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
    rationale: $rationale,
    budget: {
      iteration: $iteration,
      iteration_cap: $iteration_cap,
      wall_clock_s: $wall_clock_s,
      wall_clock_cap_s: $wall_clock_cap_s
    },
    actor: $actor
  }' \
  >> "$card_file" 2>/dev/null
then
  die "cannot write decision card to $card_file"
fi

exit 0
