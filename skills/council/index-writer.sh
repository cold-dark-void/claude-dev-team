#!/usr/bin/env bash
#
# council/index-writer.sh — Append one row to .claude/council/index.json
#
# Usage:
#   index-writer.sh <task_id> <report_path> <max_verdict_confidence|null> <max_finding_confidence|null>
#                   <council_tier> <grading_reason>
#                   [max_verified_confidence|null] [worst_verdict|null]
#
# The last two args are optional. A 6-arg call still writes the pre-CDT-317
# row (those keys absent). Finalize passes both. Empty task_id is rejected.
# A non-empty id is accepted for every tier, including skip.
#
# Exits 0 on success, non-zero on failure (message on stderr).
# Atomic tmp+rename, flock-serialized to prevent concurrent races.

set -euo pipefail

# ---- Args -------------------------------------------------------------------
if [ $# -lt 6 ] || [ $# -gt 8 ]; then
  echo "Usage: index-writer.sh <task_id> <report_path> <max_verdict_confidence|null> <max_finding_confidence|null> <council_tier> <grading_reason> [max_verified_confidence|null] [worst_verdict|null]" >&2
  exit 1
fi

TASK_ID="$1"
REPORT_PATH="$2"
MVC="$3"    # max_verdict_confidence  — JSON number (int|float) or literal "null"
MFC="$4"    # max_finding_confidence  — JSON number (int|float) or literal "null"
TIER="$5"   # council_tier (CDT-126)  — light | full | skip
REASON="$6" # grading_reason (CDT-126) — free text, may be empty
HAS_MVC_VERIFIED=0
MVC_VERIFIED="null"
HAS_WORST=0
WORST_VERDICT="null"
if [ $# -ge 7 ]; then
  MVC_VERIFIED="$7"
  HAS_MVC_VERIFIED=1
fi
if [ $# -ge 8 ]; then
  WORST_VERDICT="$8"
  HAS_WORST=1
fi

# ---- Dependency check -------------------------------------------------------
# jq required early: confidence floor-normalize (CDT-181) + atomic index write.
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not found in PATH" >&2
  exit 1
fi

# ---- Validate task_id (path traversal prevention) ----------------------------
# Empty is rejected (W2-15). ".." matches the character class; reject it.
# Do not reject a non-empty skip-tier id — tier is checked separately.
if [ -z "$TASK_ID" ]; then
  echo "error: task_id must be non-empty" >&2
  exit 1
fi
if [[ "$TASK_ID" == *..* ]] || [[ "$TASK_ID" == */* ]] || ! [[ "$TASK_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  printf 'error: task_id must match [a-zA-Z0-9._-]+, got: %q\n' "$TASK_ID" >&2
  exit 1
fi

# ---- Validate confidence args (CDT-181: floor-normalize) --------------------
# Accept null, or a JSON number (int/float, optional leading -). Floor via jq;
# require the floored integer in 0..100; write int string back into named var
# for --argjson. Non-numeric / OOB-after-floor → stderr + exit 1 (no index mutate).
validate_confidence() {
  local -n _vc_ref="$1"
  local label="$2"
  local val="$_vc_ref"
  if [ "$val" = "null" ]; then
    return 0
  fi
  local floored
  if ! floored=$(jq -n --argjson n "$val" '$n | floor' 2>/dev/null); then
    echo "error: $label must be a JSON number 0-100 or 'null', got: $val" >&2
    exit 1
  fi
  # floor always yields an integer JSON number; re-check range as bash int
  if ! [[ "$floored" =~ ^-?[0-9]+$ ]] || [ "$floored" -lt 0 ] || [ "$floored" -gt 100 ]; then
    echo "error: $label must be in 0-100 after floor, got: $val (floor=$floored)" >&2
    exit 1
  fi
  _vc_ref="$floored"
}
validate_confidence MVC "max_verdict_confidence"
validate_confidence MFC "max_finding_confidence"
if [ "$HAS_MVC_VERIFIED" -eq 1 ]; then
  validate_confidence MVC_VERIFIED "max_verified_confidence"
fi
if [ "$HAS_WORST" -eq 1 ]; then
  case "$WORST_VERDICT" in
    null|VERIFIED|PARTIALLY_VERIFIED|UNVERIFIED|CONTRADICTED|FABRICATED) ;;
    *)
      echo "error: worst_verdict must be a taxonomy term or 'null', got: $WORST_VERDICT" >&2
      exit 1
      ;;
  esac
fi

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
     --argjson has_mv "$HAS_MVC_VERIFIED" \
     --argjson mv "$MVC_VERIFIED" \
     --argjson has_wv "$HAS_WORST" \
     --arg wv "$WORST_VERDICT" \
     '.[$tid] = [({report_path: $rp, max_verdict_confidence: $mvc, max_finding_confidence: $mfc, created_at: $ts, council_tier: $tier, grading_reason: $reason}
        + (if $has_mv == 1 then {max_verified_confidence: $mv} else {} end)
        + (if $has_wv == 1 then {worst_verdict: (if $wv == "null" then null else $wv end)} else {} end)
      )] + (.[$tid] // [])' \
     "$INDEX" > "$TMP"

  mv "$TMP" "$INDEX"
) 9>"$LOCK"
