#!/usr/bin/env bash
#
# council/index-writer.sh — Append one row to .claude/council/index.json
#
# Usage:
#   index-writer.sh <task_id> <report_path> <max_verdict_confidence|null> <max_finding_confidence|null>
#                   <council_tier> <grading_reason>
#
# Exits 0 on success, non-zero on failure (message on stderr).
# Atomic tmp+rename, flock-serialized to prevent concurrent races.

set -euo pipefail

# ---- Args -------------------------------------------------------------------
if [ $# -ne 6 ]; then
  echo "Usage: index-writer.sh <task_id> <report_path> <max_verdict_confidence|null> <max_finding_confidence|null> <council_tier> <grading_reason>" >&2
  exit 1
fi

TASK_ID="$1"
REPORT_PATH="$2"
MVC="$3"    # max_verdict_confidence  — integer or literal "null"
MFC="$4"    # max_finding_confidence  — integer or literal "null"
TIER="$5"   # council_tier (CDT-126)  — light | full | skip
REASON="$6" # grading_reason (CDT-126) — free text, may be empty

# ---- Validate task_id (path traversal prevention) ----------------------------
if [ -n "$TASK_ID" ] && ! [[ "$TASK_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  printf 'error: task_id must match [a-zA-Z0-9._-]+, got: %q\n' "$TASK_ID" >&2
  exit 1
fi

# ---- Validate confidence args -----------------------------------------------
validate_confidence() {
  local val="$1" label="$2"
  if [ "$val" != "null" ]; then
    if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 0 ] || [ "$val" -gt 100 ]; then
      echo "error: $label must be an integer 0-100 or 'null', got: $val" >&2
      exit 1
    fi
  fi
}
validate_confidence "$MVC" "max_verdict_confidence"
validate_confidence "$MFC" "max_finding_confidence"

# ---- Validate council_tier ---------------------------------------------------
# light|full come from an actual engine.sh finalize run; grading can never
# return `skip` and engine.sh itself refuses to reach preflight with it
# (engine.sh: "--tier skip is resolved by the caller"). `skip` rows instead
# come from a task-gate call site's own short-circuit (CDT-126 Task 6,
# orchestrate/SKILL.md Step 9) recording a DRI-forced skip directly — no
# council run, no report — via this same one owning surface for index.json
# (SPEC-013 "Recording the tier"; SPEC-026 M10 forbids other writers).
case "$TIER" in
  light|full|skip) ;;
  *)
    echo "error: council_tier must be light|full|skip, got: $TIER" >&2
    exit 1
    ;;
esac

# ---- Dependency check -------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not found in PATH" >&2
  exit 1
fi

# ---- Resolve MROOT (worktree-aware) -----------------------------------------
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)

# ---- Paths ------------------------------------------------------------------
COUNCIL_DIR="$MROOT/.claude/council"
INDEX="$COUNCIL_DIR/index.json"
LOCK="$COUNCIL_DIR/.index.lock"
TMP="$COUNCIL_DIR/index.json.tmp"

mkdir -p "$COUNCIL_DIR"

# ---- Timestamp --------------------------------------------------------------
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---- Atomic read-modify-write under flock -----------------------------------
(
  flock -x 9

  # Seed with empty object if index doesn't exist yet
  if [ ! -f "$INDEX" ]; then
    echo '{}' > "$INDEX"
  fi

  jq --arg tid "$TASK_ID" \
     --arg rp  "$REPORT_PATH" \
     --argjson mvc "$MVC" \
     --argjson mfc "$MFC" \
     --arg ts  "$TS" \
     --arg tier "$TIER" \
     --arg reason "$REASON" \
     '.[$tid] = [{report_path: $rp, max_verdict_confidence: $mvc, max_finding_confidence: $mfc, created_at: $ts, council_tier: $tier, grading_reason: $reason}] + (.[$tid] // [])' \
     "$INDEX" > "$TMP"

  mv "$TMP" "$INDEX"
) 9>"$LOCK"
