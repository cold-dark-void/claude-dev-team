#!/usr/bin/env bash
#
# autopilot/resume-state.sh — SPEC-033 M9a plan-lookup + resume helper.
# CDT-111-C8 T1 origin; WP 1-08 Task 2 moves the plan-lookup mode onto
# skills/lib/plan-resolve.sh (Tracking `ticket_id:` exact match) and adds
# the --iteration mode.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   resume-state.sh <ISSUE-ID>                  # Tracking ticket_id lookup (Step-0 resume)
#   resume-state.sh --accumulated <ISSUE-ID>    # accumulated active-execution seconds
#   resume-state.sh --iteration <ISSUE-ID>      # largest recorded budget.iteration
#
# ---- Lookup mode ----------------------------------------------------------
# Resolves the plan via `skills/lib/plan-resolve.sh find <ISSUE-ID>`
# (Tracking `- ticket_id:` exact/literal match; worktree top-level
# .claude/plans then $MROOT/.claude/plans, deduped, newest mtime on several
# matches; a legacy plan with no `ticket_id:` line is not found — SPEC-033
# D11). No match -> {"found":false}. On a match, reads `- autopilot_on:` /
# `- autopilot_bump:` from the SAME plan's `## Tracking` section via
# `plan-resolve.sh field` (a `- autopilot_on:` line outside `## Tracking`
# is ignored — plan-resolve.sh only ever reads inside that section).
#
# stdout (one compact JSON line, exit 0):
#   no match:                 {"found":false}
#   match, no recorded state: {"found":true,"plan":"<path>","autopilot_on":null,"autopilot_bump":null}
#   match, recorded state:    {"found":true,"plan":"<path>","autopilot_on":true|false,"autopilot_bump":"patch"|"minor"|"major"|"master"|null}
#
# ---- Accumulated mode -------------------------------------------------------
# Delegates to read-cards.sh <ISSUE-ID> (never reimplements card JSON
# parsing) and prints max(.[].budget.wall_clock_s) // 0 as a bare integer on
# stdout. read-cards.sh failure (non-zero exit) or an empty/missing ledger
# both print exactly one line: `0`. Consumed by orchestrate Step-0 to
# compute a synthetic RUN_START_EPOCH on resume (SPEC-033 M9a): pause
# duration must never count against the wall-clock budget cap, but active
# time must keep accumulating across any number of pause/resume cycles.
#
# ---- Iteration mode ---------------------------------------------------------
# Delegates to read-cards.sh <ISSUE-ID> and prints
# [.[].budget.iteration] | max // 0 as a bare integer on stdout. Same
# failure rule as --accumulated (read-cards.sh failure or no cards -> `0`).
# Consumed by orchestrate Step-0 to restore ITER on resume (SPEC-033 M9a).
#
# This script MUST NOT seed AUTOPILOT_ITERATION_CAP / AUTOPILOT_WALLCLOCK_CAP
# from plan frontmatter in ANY mode (SPEC-033 M9a) — caps come only from the
# ledger freeze / env, never from a plan file; this script never prints an
# iteration_cap, wall_clock_cap_s or max_loc key.
#
# All three modes share the ISSUE-ID charset guard below and are read-only
# (never write anything).
#
# Exit codes:
#   0   success
#  64   usage error (wrong argc / bad mode) / ISSUE-ID charset guard / jq absent

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: resume-state.sh <ISSUE-ID> | resume-state.sh --accumulated <ISSUE-ID> | resume-state.sh --iteration <ISSUE-ID>'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

# ---- Usage / mode dispatch ----------------------------------------------------
MODE="lookup"
ISSUE_ID=""
case $# in
  1)
    ISSUE_ID="$1"
    ;;
  2)
    case "$1" in
      --accumulated) MODE="accumulated" ;;
      --iteration) MODE="iteration" ;;
      *) die "unknown option '$1' (expected --accumulated or --iteration)" ;;
    esac
    ISSUE_ID="$2"
    ;;
  *)
    die "resume-state.sh requires 1 or 2 arguments (got $#)"
    ;;
esac

# ---- ISSUE-ID validation (path-traversal guard) -------------------------------
[ -z "$ISSUE_ID" ] && die "ISSUE-ID must not be empty"
case "$ISSUE_ID" in
  *[!A-Za-z0-9_-]*) die "ISSUE-ID must match ^[A-Za-z0-9_-]+\$" ;;
esac

# ---- jq guard ------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  die "jq not found; cannot compute resume-state result"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLAN_RESOLVE="$SCRIPT_DIR/../lib/plan-resolve.sh"

# =================================================================================
# Accumulated mode — delegate to read-cards.sh, compute max(wall_clock_s) // 0
# =================================================================================
if [ "$MODE" = "accumulated" ]; then
  CARDS_JSON=$(bash "$SCRIPT_DIR/read-cards.sh" "$ISSUE_ID" 2>/dev/null) || CARDS_JSON="[]"
  ACCUM=$(printf '%s' "$CARDS_JSON" | jq '[.[].budget.wall_clock_s] | max // 0' 2>/dev/null) || ACCUM="0"
  case "$ACCUM" in ''|*[!0-9]*) ACCUM=0 ;; esac
  printf '%s\n' "$ACCUM"
  exit 0
fi

# =================================================================================
# Iteration mode — delegate to read-cards.sh, compute max(budget.iteration) // 0
# =================================================================================
if [ "$MODE" = "iteration" ]; then
  CARDS_JSON=$(bash "$SCRIPT_DIR/read-cards.sh" "$ISSUE_ID" 2>/dev/null) || CARDS_JSON="[]"
  ITERATION=$(printf '%s' "$CARDS_JSON" | jq '[.[].budget.iteration] | max // 0' 2>/dev/null) || ITERATION="0"
  case "$ITERATION" in ''|*[!0-9]*) ITERATION=0 ;; esac
  printf '%s\n' "$ITERATION"
  exit 0
fi

# =================================================================================
# Lookup mode — resolve via plan-resolve.sh find, then read the SAME plan's
# `## Tracking` autopilot_on / autopilot_bump via plan-resolve.sh field.
# =================================================================================
PLAN=$(bash "$PLAN_RESOLVE" find "$ISSUE_ID" 2>/dev/null) || PLAN=""

if [ -z "$PLAN" ]; then
  echo '{"found":false}'
  exit 0
fi

AUTOPILOT_ON_RAW=$(bash "$PLAN_RESOLVE" field "$PLAN" autopilot_on 2>/dev/null) || AUTOPILOT_ON_RAW=""
AUTOPILOT_BUMP_RAW=$(bash "$PLAN_RESOLVE" field "$PLAN" autopilot_bump 2>/dev/null) || AUTOPILOT_BUMP_RAW=""

case "$AUTOPILOT_ON_RAW" in
  true) AUTOPILOT_ON_JSON="true" ;;
  false) AUTOPILOT_ON_JSON="false" ;;
  *) AUTOPILOT_ON_JSON="null" ;;
esac

case "$AUTOPILOT_BUMP_RAW" in
  patch|minor|major|master) AUTOPILOT_BUMP_JSON="\"$AUTOPILOT_BUMP_RAW\"" ;;
  *) AUTOPILOT_BUMP_JSON="null" ;;
esac

jq -cn \
  --argjson found true \
  --arg plan "$PLAN" \
  --argjson autopilot_on "$AUTOPILOT_ON_JSON" \
  --argjson autopilot_bump "$AUTOPILOT_BUMP_JSON" \
  '{found: $found, plan: $plan, autopilot_on: $autopilot_on, autopilot_bump: $autopilot_bump}'

exit 0
