#!/usr/bin/env bash
# appeal.sh — trigger-(c) council-residue appeal seam (SPEC-039 M20/M21/M22,
# epic child C6/CDT-561).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT. Deterministic bash+jq
# only. The advisor spawn itself goes through ask.sh probe/finalize (M5) —
# this script never spawns and never calls the model.
#
# Subcommands:
#   appeal.sh gate --meta PATH.finalize-meta.json [--report PATH]
#                  [--run-id ID] [--evidence-dir DIR]
#       Runs residue.sh on the council sidecar. CLEAN PASS (residue:false):
#       exit 0, no output, nothing written — the M20 zero-advisor guarantee
#       (no spawn-request, no probe, no state). Residue with the advisor off
#       (ADVISOR_ON != "true") or bypassed (ADVISOR_SKIP_TRIGGER=1): exit 0,
#       silent skip. Residue with the advisor on: stage the appeal evidence
#       (default $ADVISOR_STATE_ROOT/runs/<run_id>/appeal-evidence/ —
#       structurally OUTSIDE the council bundle directory, M22) and run
#       `ask.sh probe --trigger c` (reserve c=2, M26), printing the probe's
#       one JSON action object on stdout. The caller then spawns natively
#       and finalizes per skills/advisor/SKILL.md.
#
#   appeal.sh authority --ruling-file PATH [--run-id ID]
#       M21 authority fence. Maps the trigger-(c) ruling to one of exactly
#       two authorities — AGREE -> sustain-halt; CONTRADICT or INSUFFICIENT
#       -> re-council (fail-closed) — and NEVER proceed: CONTRADICTED ship
#       goes only through a fresh council pass with new tool evidence (M21).
#       stdout: exactly one JSON object
#         {"authority":"sustain-halt|re-council","advisor_appeal":true,
#          "ruling":"...","confidence":N}
#       With --run-id the record is written to
#       runs/<run_id>/appeal.json (provenance key "advisor_appeal": true).
#       An unknown ruling value exits 64.
#
#   appeal.sh check-bundle-set --file PATH
#       M22 injection guard for the council bundle set: exit 0 when the JSON
#       carries NO object with the provenance key "advisor_appeal", exit 64
#       when any does (advisor-gathered evidence is rejected if injected
#       into a bundle set) and 64 on unparseable input.
#
# Exit: 0 on every computed outcome; 64 on usage errors, an unreadable
# meta/ruling file, or a residue-detector failure.

set -u

usage() {
  cat >&2 <<'EOF'
usage: appeal.sh gate --meta PATH.finalize-meta.json [--report PATH]
                      [--run-id ID] [--evidence-dir DIR]
       appeal.sh authority --ruling-file PATH [--run-id ID]
       appeal.sh check-bundle-set --file PATH
EOF
  exit 64
}

die64() { echo "appeal.sh: $1" >&2; exit 64; }

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

# ---- sibling resolution (self-dir: the plugin ships skills/ as one dir) ------
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || die64 "cannot resolve script dir"
RESIDUE="$SELF_DIR/residue.sh"
ASK="$SELF_DIR/ask.sh"
[ -f "$RESIDUE" ] || die64 "sibling residue.sh not found"
[ -f "$ASK" ] || die64 "sibling ask.sh not found"

# ---- state root (same pattern as ask.sh) -------------------------------------
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ADVISOR_DIR="${ADVISOR_STATE_ROOT:-$MROOT/.claude/advisor}"

case "$CMD" in
  gate)
    META="" REPORT="" RUN_ID="" EVIDENCE_DIR=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --meta) [ $# -ge 2 ] || usage; META="$2"; shift 2 ;;
        --meta=*) META="${1#*=}"; shift ;;
        --report) [ $# -ge 2 ] || usage; REPORT="$2"; shift 2 ;;
        --report=*) REPORT="${1#*=}"; shift ;;
        --run-id) [ $# -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
        --run-id=*) RUN_ID="${1#*=}"; shift ;;
        --evidence-dir) [ $# -ge 2 ] || usage; EVIDENCE_DIR="$2"; shift 2 ;;
        --evidence-dir=*) EVIDENCE_DIR="${1#*=}"; shift ;;
        *) usage ;;
      esac
    done
    [ -n "$META" ] || usage

    RES=$(bash "$RESIDUE" --meta "$META" ${REPORT:+--report "$REPORT"}) \
      || die64 "residue detector failed: $RES"
    IS_RESIDUE=$(printf '%s' "$RES" | jq -r '.residue')
    # Clean pass: zero advisor calls — no stdout, no state, no probe (M20).
    [ "$IS_RESIDUE" = "true" ] || exit 0

    # Advisor off or interactive bypass: silent skip (CDT-564 fence seam).
    [ "${ADVISOR_ON:-}" = "true" ] || exit 0
    [ "${ADVISOR_SKIP_TRIGGER:-}" != "1" ] || exit 0

    # Evidence travels as a directory path (M18), staged OUTSIDE the council
    # bundle set (M22): default under the advisor state root.
    if [ -z "$EVIDENCE_DIR" ]; then
      [ -n "$RUN_ID" ] || die64 "gate: --run-id is required when --evidence-dir is omitted"
      EVIDENCE_DIR="$ADVISOR_DIR/runs/$RUN_ID/appeal-evidence"
    fi
    mkdir -p "$EVIDENCE_DIR" || die64 "cannot create evidence dir: $EVIDENCE_DIR"
    cp "$META" "$EVIDENCE_DIR/council.finalize-meta.json" || die64 "cannot stage meta into $EVIDENCE_DIR"
    [ -z "$REPORT" ] || cp "$REPORT" "$EVIDENCE_DIR/council-report.md" || die64 "cannot stage report into $EVIDENCE_DIR"

    KINDS=$(printf '%s' "$RES" | jq -r '.kinds | sort | join(",")')
    THRESHOLD=$(printf '%s' "$RES" | jq -r '.threshold')
    # Deterministic question; its hash covers the staged evidence content
    # (ask.sh), so changed council output is a new question (retries count).
    QUESTION="council-residue appeal: kinds=$KINDS threshold=$THRESHOLD report=$(basename "$META")"
    PROBE_ARGS=(probe --trigger c --question "$QUESTION" --evidence-dir "$EVIDENCE_DIR")
    [ -z "$RUN_ID" ] || PROBE_ARGS+=(--run-id "$RUN_ID")
    bash "$ASK" "${PROBE_ARGS[@]}" || die64 "ask.sh probe failed"
    exit 0
    ;;

  authority)
    RULING_FILE="" RUN_ID=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --ruling-file) [ $# -ge 2 ] || usage; RULING_FILE="$2"; shift 2 ;;
        --ruling-file=*) RULING_FILE="${1#*=}"; shift ;;
        --run-id) [ $# -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
        --run-id=*) RUN_ID="${1#*=}"; shift ;;
        *) usage ;;
      esac
    done
    [ -n "$RULING_FILE" ] || usage
    [ -f "$RULING_FILE" ] || die64 "no such ruling file: $RULING_FILE"
    jq empty "$RULING_FILE" 2>/dev/null || die64 "ruling file is not valid JSON: $RULING_FILE"
    RULING=$(jq -r '.ruling // ""' "$RULING_FILE" 2>/dev/null)
    case "$RULING" in
      AGREE|CONTRADICT|INSUFFICIENT) ;;
      *) die64 "ruling must be AGREE|CONTRADICT|INSUFFICIENT (got '$RULING')" ;;
    esac
    CONF=$(jq -r '.confidence // 0' "$RULING_FILE" 2>/dev/null)
    case "$CONF" in
      ''|*[!0-9]*) die64 "confidence must be an integer 0-100" ;;
    esac
    # M21 authority map: only sustain-halt or re-council. INSUFFICIENT fails
    # closed to sustain-halt (a halt is only lifted by a fresh council pass).
    case "$RULING" in
      AGREE) AUTHORITY="sustain-halt" ;;
      *) AUTHORITY="re-council" ;;
    esac
    if [ -n "$RUN_ID" ]; then
      mkdir -p "$ADVISOR_DIR/runs/$RUN_ID"
      jq -cn --arg authority "$AUTHORITY" --arg ruling "$RULING" \
             --argjson confidence "$CONF" \
             --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{authority:$authority, advisor_appeal:true, ruling:$ruling,
          confidence:$confidence, ts:$ts}' \
        > "$ADVISOR_DIR/runs/$RUN_ID/appeal.json" || die64 "cannot write appeal record"
    fi
    jq -cn --arg authority "$AUTHORITY" --arg ruling "$RULING" \
           --argjson confidence "$CONF" \
      '{authority:$authority, advisor_appeal:true, ruling:$ruling, confidence:$confidence}'
    exit 0
    ;;

  check-bundle-set)
    FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --file) [ $# -ge 2 ] || usage; FILE="$2"; shift 2 ;;
        --file=*) FILE="${1#*=}"; shift ;;
        *) usage ;;
      esac
    done
    [ -n "$FILE" ] || usage
    [ -f "$FILE" ] || die64 "no such file: $FILE"
    jq empty "$FILE" 2>/dev/null || die64 "bundle set is not valid JSON: $FILE"
    # The provenance key "advisor_appeal" marks advisor-gathered evidence
    # (M22). Any object in the set carrying it is rejected — the labelled
    # evidence structurally cannot enter a council bundle set.
    N=$(jq '[.. | objects | select(has("advisor_appeal"))] | length' "$FILE" 2>/dev/null) \
      || die64 "cannot scan bundle set: $FILE"
    if [ "$N" -gt 0 ]; then
      echo "appeal.sh: $N advisor_appeal-labelled object(s) found in bundle set $FILE — advisor-gathered evidence MUST NOT enter a council bundle set (M22)" >&2
      exit 64
    fi
    exit 0
    ;;

  *) usage ;;
esac
