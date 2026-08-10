#!/usr/bin/env bash
#
# autopilot/resume-state.sh — CDT-111-C8 T1: plan-file frontmatter resume
# lookup + M13 ledger accumulated-active-seconds helper.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   resume-state.sh <ISSUE-ID>                  # frontmatter lookup (Step-0 resume)
#   resume-state.sh --accumulated <ISSUE-ID>    # accumulated active-execution seconds
#
# ---- Lookup mode --------------------------------------------------------------
# Globs $MROOT/.claude/plans/*-<ISSUE-ID>-*.md (the glob lives in THIS script —
# callers never glob directly; keeps orchestrate/SKILL.md's bash fences
# skill-bash-lint clean). No match → {"found":false}. On a match, parses the
# plan's `## Tracking` section for:
#   - autopilot_on: true|false      (absent on a pre-C8 plan → autopilot_on:null)
#   - autopilot_bump: patch|minor|major|master|null
# Multiple matches (shouldn't happen given worktree-lib.sh's collision
# handling, but defensive) → most recently modified file wins.
#
# stdout (one compact JSON line, exit 0):
#   no match:                 {"found":false}
#   match, no recorded state: {"found":true,"plan":"<path>","autopilot_on":null,"autopilot_bump":null}
#   match, recorded state:    {"found":true,"plan":"<path>","autopilot_on":true|false,"autopilot_bump":"patch"|"minor"|"major"|"master"|null}
#
# ---- Accumulated mode ----------------------------------------------------------
# Delegates to read-cards.sh <ISSUE-ID> (never reimplements card JSON parsing)
# and prints max(.[].budget.wall_clock_s) // 0 as a bare integer on stdout.
# Consumed by orchestrate Step-0 to compute a synthetic RUN_START_EPOCH on
# resume (SPEC-033 M9a): pause duration must never count against the
# wall-clock budget cap, but active time must keep accumulating across any
# number of pause/resume cycles.
#
# Both modes share the ISSUE-ID charset guard below and are read-only (never
# write anything).
#
# Exit codes:
#   0   success
#  64   usage error (wrong argc / bad mode) / ISSUE-ID charset guard / jq absent

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: resume-state.sh <ISSUE-ID> | resume-state.sh --accumulated <ISSUE-ID>'

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
    [ "$1" = "--accumulated" ] || die "unknown option '$1' (expected --accumulated)"
    MODE="accumulated"
    ISSUE_ID="$2"
    ;;
  *)
    die "resume-state.sh requires 1 or 2 arguments (got $#)"
    ;;
esac

# ---- ISSUE-ID validation (path-traversal guard) -------------------------------
[ -z "$ISSUE_ID" ] && die "ISSUE-ID must not be empty"
case "$ISSUE_ID" in
  *[!A-Za-z0-9_-]*) die "ISSUE-ID must match ^[A-Za-z0-9_-]+$" ;;
esac

# ---- jq guard ------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  die "jq not found; cannot compute resume-state result"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ---- resolve_mroot (copied from read-cards.sh:47-54) --------------------------
resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

resolve_mroot

# =================================================================================
# Accumulated mode — delegate to read-cards.sh, compute max(wall_clock_s) // 0
# =================================================================================
if [ "$MODE" = "accumulated" ]; then
  CARDS_JSON=$(bash "$SCRIPT_DIR/read-cards.sh" "$ISSUE_ID")
  ACCUM=$(printf '%s' "$CARDS_JSON" | jq '[.[].budget.wall_clock_s] | max // 0')
  printf '%s\n' "$ACCUM"
  exit 0
fi

# =================================================================================
# Lookup mode — glob plans, parse ## Tracking autopilot_on / autopilot_bump
# =================================================================================
PLANS_DIR="$MROOT/.claude/plans"

# nullglob-safe: literal glob pattern must not be treated as a real (missing) file.
shopt -s nullglob
MATCHES=("$PLANS_DIR"/*-"$ISSUE_ID"-*.md)
shopt -u nullglob

if [ ${#MATCHES[@]} -eq 0 ]; then
  echo '{"found":false}'
  exit 0
fi

if [ ${#MATCHES[@]} -eq 1 ]; then
  PLAN="${MATCHES[0]}"
else
  # Defensive: multiple matches → most recently modified file wins.
  PLAN=$(ls -t "${MATCHES[@]}" | head -n 1)
fi

# ---- Parse `## Tracking` section ----------------------------------------------
# `- autopilot_on: true|false` → JSON bool; absent → null (pre-C8 plan).
AUTOPILOT_ON_RAW=$(grep -m1 '^- autopilot_on:' "$PLAN" 2>/dev/null | sed -E 's/^- autopilot_on:[[:space:]]*//' | tr -d '[:space:]' || true)
AUTOPILOT_BUMP_RAW=$(grep -m1 '^- autopilot_bump:' "$PLAN" 2>/dev/null | sed -E 's/^- autopilot_bump:[[:space:]]*//' | tr -d '[:space:]' || true)

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
