#!/usr/bin/env bash
#
# autopilot/ship-gate-verdict.sh — M14 ship-gate verdict mapper
# (SPEC-033 M14(i), WP 1-14 interface contract C4).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# The ONLY implementation of SPEC-033 M14(b) (per-AC aggregation ->
# confidence -> BC mapping) and of M14(h) guard 3 (the [process] AC
# stamp-shape re-check). A pure jq mapper: it reads the council's own
# finalize-meta sidecar and card #1, after the verdict, and writes
# nothing (M14(i) "Limits"). It is not a render helper (M14(a)/(i)).
#
# Usage:
#   ship-gate-verdict.sh --meta <sidecar.json> --card1 <card1.json> --tier <light|full|skip>
#   ship-gate-verdict.sh --no-report <cause> --card1 <card1.json> --tier <light|full|skip>
#
# --meta / --no-report are mutually exclusive; exactly one is required.
# --card1 and --tier are always required.
#
# Stdout (exit 0 on EVERY computed outcome, never partial):
#   {"decision":"pr|merge|halt","blocking_condition":null|7,
#    "confidence":<int 0-100>,"bump":<card1.bump|null>,
#    "rationale":"<one line, no newline/control chars, ends '; council_tier=<t>'>"}
#
# Fail-closed outcomes (all exit 0, decision=halt, blocking_condition=7,
# confidence=0, bump=null unless noted):
#   - --no-report <cause>                              (M14(b) step 1)
#   - meta unreadable / not a JSON object                (C4 "unreadable meta")
#   - meta.process_acs present but not a JSON array, or a
#     meta.ac_claims[] entry that is not an object with a
#     non-empty string ac_id                             (malformed sidecar)
#   - meta has no non-empty plan.ac_claims[]             (M14(b): "no AC-bound
#     claims" — the per-AC split did not run, or produced zero claims)
#   - meta.verification_mode == "self-verified"          (M14(d) degraded run)
#   - meta.verification_mode is anything other than
#     "full" or "self-verified"                          (malformed sidecar)
#   - card1 unreadable / not a JSON object               (C4 "unreadable card1")
#   - plan.process_acs[] non-empty AND card1 fails the
#     M14(a) stamp shape                                 (M14(h) guard 3)
#   - one or more technical ACs unaudited                (M14(b) step 3)
#   - one or more technical ACs UNVERIFIED/CONTRADICTED/
#     FABRICATED                                          (M14(b) step 4)
#   - every technical AC VERIFIED/PARTIALLY_VERIFIED but
#     the lowest confidence is < 80 (confidence stays that
#     minimum — NOT forced to 0)                          (M14(b) step 6 disagree)
#   - on the agree path, card1.decision is not "pr" or
#     "merge" (missing/null/other)                        (malformed card #1)
#
# Agree outcome (M14(b) step 6): every technical AC VERIFIED/PARTIALLY_VERIFIED
# at confidence >= 80 -> decision/bump copied from card #1, blocking_condition=null,
# confidence = the lowest AC confidence.
#
# Invariant (append-card.sh cross-field invariant (b)): this script never
# emits blocking_condition=7 with confidence >= 80 — true by construction,
# since every blocking_condition=7 branch above sets confidence to either 0
# or a value already checked to be < 80.
#
# Exit codes:
#   0   every computed outcome above (including every fail-closed halt)
#  64   argv misuse only (bad/missing/duplicate flag, unknown flag, jq absent)

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

SELF="ship-gate-verdict"
USAGE="Usage: $SELF.sh (--meta <sidecar.json> | --no-report <cause>) --card1 <card1.json> --tier <light|full|skip>"

die() {
  echo "error: $SELF: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

if ! command -v jq >/dev/null 2>&1; then
  die "requires jq"
fi

# ---- Argv parsing ------------------------------------------------------------
MODE=""
META_PATH=""
NOREPORT_CAUSE=""
CARD1_PATH=""
TIER=""

require_value() {  # require_value <flag-name> <remaining-argc> <next-arg>
  [ "$2" -ge 2 ] || die "$1 requires a value"
  case "$3" in
    --*) die "$1 requires a value (got flag-like token '$3')" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --meta)
      require_value "--meta" "$#" "${2:-}"
      [ -z "$MODE" ] || die "specify exactly one of --meta or --no-report"
      MODE="meta"; META_PATH="$2"; shift 2 ;;
    --no-report)
      require_value "--no-report" "$#" "${2:-}"
      [ -z "$MODE" ] || die "specify exactly one of --meta or --no-report"
      NOREPORT_CAUSE="$2"; MODE="no-report"; shift 2 ;;
    --card1)
      require_value "--card1" "$#" "${2:-}"
      [ -z "$CARD1_PATH" ] || die "--card1 specified more than once"
      CARD1_PATH="$2"; shift 2 ;;
    --tier)
      require_value "--tier" "$#" "${2:-}"
      [ -z "$TIER" ] || die "--tier specified more than once"
      TIER="$2"; shift 2 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

[ -n "$MODE" ]       || die "specify exactly one of --meta or --no-report"
[ -n "$CARD1_PATH" ] || die "--card1 is required"
[ -n "$TIER" ]       || die "--tier is required"
case "$TIER" in
  light|full|skip) ;;
  *) die "--tier must be one of light, full, skip (got '$TIER')" ;;
esac
if [ "$MODE" = "no-report" ] && [ -z "$NOREPORT_CAUSE" ]; then
  die "--no-report requires a non-empty cause"
fi

# ---- emit: the ONLY place that prints final JSON (always exit 0) -----------
emit() {
  # emit <decision> <blocking_condition-json> <confidence-int> <bump-json> <body>
  local decision="$1" bc_json="$2" confidence="$3" bump_json="$4" body="$5"
  local rationale
  rationale=$(printf '%s; council_tier=%s' "$body" "$TIER" | tr -d '[:cntrl:]')
  jq -cn \
    --arg decision "$decision" \
    --argjson blocking_condition "$bc_json" \
    --argjson confidence "$confidence" \
    --argjson bump "$bump_json" \
    --arg rationale "$rationale" \
    '{decision: $decision, blocking_condition: $blocking_condition,
      confidence: $confidence, bump: $bump, rationale: $rationale}'
  exit 0
}

# halt0 <body> — the common fail-closed shape: halt, BC7, confidence 0, bump null.
halt0() {
  emit "halt" "7" "0" "null" "$1"
}

# read_json_object <path> <label> — on success, sets READ_JSON_OUT to the
# compact JSON read from <path> and returns 0. On failure (unreadable path,
# unparseable JSON, or parsed JSON that is not an object), sets
# READ_JSON_ERR to a one-line cause and returns 1. MUST be called directly
# (never inside a subshell / "$(...)") so a caller's own
# `read_json_object ... || halt0 "$READ_JSON_ERR"` can exit 0 from the top
# level — halt0 itself must never run inside a command-substitution subshell.
read_json_object() {
  local path="$1" label="$2"
  READ_JSON_OUT=""
  READ_JSON_ERR=""
  if [ ! -r "$path" ]; then
    READ_JSON_ERR="cannot read $label $path"
    return 1
  fi
  if ! READ_JSON_OUT=$(jq -c '.' "$path" 2>/dev/null) \
     || ! printf '%s' "$READ_JSON_OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    READ_JSON_ERR="cannot parse $label $path as a JSON object"
    return 1
  fi
  return 0
}

# ---- M14(b) step 1: no usable report ----------------------------------------
if [ "$MODE" = "no-report" ]; then
  halt0 "$NOREPORT_CAUSE"
fi

# ---- Read the finalize-meta sidecar -----------------------------------------
read_json_object "$META_PATH" "finalize-meta sidecar" || halt0 "$READ_JSON_ERR"
META_JSON="$READ_JSON_OUT"

# ---- M14(b): a run with no AC-bound claims fails closed ---------------------
# (SPEC-013 Phase 6: ac_claims is present only when plan.claims[] carried
# ac_id, i.e. an M14 split ran; an empty array means it produced zero claims.)
if ! printf '%s' "$META_JSON" \
    | jq -e '(.ac_claims? // []) | type == "array" and length > 0' >/dev/null 2>&1; then
  halt0 "no AC-bound claims in finalize-meta sidecar; the per-AC split did not run"
fi

# ---- Malformed-sidecar type guard: every ac_claims[] entry MUST be an object
# with a non-empty string ac_id (B4a) — the M14(b) matching pipeline below
# concatenates each ac_id into a "[AC-<id>]" tag string, which jq cannot do
# fail-closed for a non-string ac_id (a bare number/array/object element, or
# an element that is not an object at all, aborts jq with no output). Guard
# the shape here, before that pipeline ever runs, rather than let a malformed
# sidecar crash the mapper with no JSON (never fail-open).
if ! printf '%s' "$META_JSON" \
    | jq -e '(.ac_claims // [])
             | all(.[]; (type == "object") and has("ac_id")
                   and ((.ac_id) | type == "string" and length > 0))' \
    >/dev/null 2>&1; then
  halt0 "mapper: malformed sidecar"
fi

# ---- Malformed-sidecar type guard: process_acs, when present, MUST be a
# JSON array (B4a) — the guard-3 check below joins it into a comma-separated
# id list, which jq cannot do for a non-array value.
PROCESS_ACS_JSON=$(printf '%s' "$META_JSON" | jq -c '.process_acs // []') \
  || halt0 "mapper: malformed sidecar"
if ! printf '%s' "$PROCESS_ACS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  halt0 "mapper: malformed sidecar"
fi

# ---- M14(d): fully self-verified run is treated as a disagreement -----------
# (B4c) verification_mode is a strict two-value enum (SPEC-013 "council_tier is
# orthogonal to verification_mode"): "full" continues past this guard,
# "self-verified" takes the degraded-run halt below, and any other value
# (including an absent, null, false, or any other non-string value) falls
# through to the "*" branch below as a malformed sidecar and MUST NOT be
# treated as "full" (B-1: `// "full"` silently defaulted absent/null/false to
# "full", a fail-open; map anything that is not a JSON string to the empty
# string instead, which the "*" branch below catches).
VMODE=$(printf '%s' "$META_JSON" | jq -r 'if (.verification_mode|type)=="string" then .verification_mode else "" end')
case "$VMODE" in
  full) ;;
  self-verified)
    halt0 "self-verified — refuters unavailable"
    ;;
  *)
    halt0 "mapper: malformed sidecar"
    ;;
esac

# ---- Read card #1 ------------------------------------------------------------
read_json_object "$CARD1_PATH" "card #1" || halt0 "$READ_JSON_ERR"
CARD1_JSON="$READ_JSON_OUT"

# ---- M14(h) guard 3: process ACs present but card #1 fails the stamp shape --
PROCESS_ACS_NONEMPTY=no
printf '%s' "$PROCESS_ACS_JSON" | jq -e 'length > 0' >/dev/null 2>&1 && PROCESS_ACS_NONEMPTY=yes
STAMP_OK=no
printf '%s' "$CARD1_JSON" | jq -e '
    .gate == "ship-choice"
    and (.decision == "pr" or .decision == "merge")
    and .blocking_condition == null
    and .decided_by == "auto"
    and .council_tier == null
    and .grading_reason == null
  ' >/dev/null 2>&1 && STAMP_OK=yes

if [ "$PROCESS_ACS_NONEMPTY" = yes ] && [ "$STAMP_OK" != yes ]; then
  PROCESS_IDS=$(printf '%s' "$PROCESS_ACS_JSON" | jq -r 'join(", ")') \
    || halt0 "mapper: malformed sidecar"
  halt0 "process ACs present ($PROCESS_IDS) but card #1 fails the M14(a) stamp shape"
fi

# ---- M14(b) steps 2-6: match verdicts to ACs, aggregate ---------------------
# Matching: an unstruck verdict belongs to AC <id> iff its claim text starts
# with the exact tag "[AC-<id>]" (M14(b) step 2). A verdict whose own
# `verdict` value is outside the 5-value taxonomy, whose `confidence` is not
# a JSON number, or whose `confidence` is a number outside the valid [0,100]
# range (N1 — an out-of-range confidence MUST NOT pass through and MUST NOT
# quietly win a min()/worst() comparison), is dropped before matching (never
# counted for any AC — "a verdict outside the taxonomy" is one of the listed
# unaudited causes, M14(b) step 3). A verdict tagged for no known AC is
# ignored. When more than one valid verdict matches one AC, the AC's verdict
# is the worst by the FABRICATED > CONTRADICTED > UNVERIFIED >
# PARTIALLY_VERIFIED > VERIFIED order, and its confidence is the LOWEST
# confidence among all of that AC's matching verdicts (independently of which
# entry carried the worst verdict) — both extremes taken separately, the
# conservative reading of "use the worst verdict and the lowest confidence".
RESULT=$(jq -cn \
  --argjson meta "$META_JSON" \
  --argjson card1 "$CARD1_JSON" \
  '
  def taxonomy: ["FABRICATED","CONTRADICTED","UNVERIFIED","PARTIALLY_VERIFIED","VERIFIED"];
  ($meta.ac_claims // []) as $ac_claims
  | ($ac_claims | map(.ac_id) | unique) as $ac_ids
  | ($meta.unstruck_verdicts // []) as $verdicts
  | ($verdicts
     | map(select(((.verdict // null) as $v | (taxonomy | index($v))) != null))
     | map(select((.confidence | type) == "number"))
     | map(select(.confidence >= 0 and .confidence <= 100))
    ) as $valid
  | ($ac_ids | map(
      . as $id
      | ($valid | map(select((.claim // "") | startswith("[AC-" + $id + "]")))) as $matched
      | if ($matched | length) == 0 then
          {ac_id: $id, status: "unaudited"}
        else
          ($matched | map(.verdict as $v | (taxonomy | index($v))) | min) as $worst_idx
          | ($matched | map(.confidence) | min | floor) as $min_conf
          | if $worst_idx <= 2 then
              {ac_id: $id, status: "failed", verdict: (taxonomy[$worst_idx])}
            else
              {ac_id: $id, status: "ok", confidence: $min_conf}
            end
        end
    )) as $results
  | ($results | map(select(.status == "unaudited") | .ac_id)) as $unaudited
  | ($results | map(select(.status == "failed"))) as $failed
  | ($results | map(select(.status == "ok"))) as $ok
  | if ($unaudited | length) > 0 then
      {kind: "unaudited", ids: $unaudited}
    elif ($failed | length) > 0 then
      {kind: "failed", items: $failed}
    else
      ($ok | map(.confidence) | min) as $conf
      | if $conf >= 80 then
          {kind: "agree", confidence: $conf, decision: $card1.decision, bump: $card1.bump}
        else
          {kind: "disagree", confidence: $conf,
           below: ($ok | map(select(.confidence < 80)))}
        end
    end
  ' 2>/dev/null) || halt0 "mapper: malformed sidecar"

KIND=$(printf '%s' "$RESULT" | jq -r '.kind')
case "$KIND" in
  unaudited)
    IDS=$(printf '%s' "$RESULT" | jq -r '.ids | join(", ")')
    halt0 "unaudited AC(s): $IDS"
    ;;
  failed)
    ITEMS=$(printf '%s' "$RESULT" | jq -r '[.items[] | "\(.ac_id)=\(.verdict)"] | join(", ")')
    halt0 "failed AC(s): $ITEMS"
    ;;
  disagree)
    CONF=$(printf '%s' "$RESULT" | jq -r '.confidence')
    BELOW=$(printf '%s' "$RESULT" | jq -r '[.below[] | "\(.ac_id)=\(.confidence)"] | join(", ")')
    emit "halt" "7" "$CONF" "null" "AC(s) below 80: $BELOW"
    ;;
  agree)
    # (B4b) card #1's decision MUST be "pr" or "merge" on the agree path — a
    # missing/null decision reads as the literal string "null" here (jq -r on
    # a JSON null), which is caught by the same case, and any other value
    # (e.g. a stray "halt") MUST NOT be echoed into a decision=halt,
    # blocking_condition=null card, an invalid combination append-card.sh
    # would otherwise have to reject.
    DECISION=$(printf '%s' "$RESULT" | jq -r '.decision')
    case "$DECISION" in
      pr|merge) ;;
      *) halt0 "card #1 decision must be pr or merge for the agree path (got '$DECISION')" ;;
    esac
    CONF=$(printf '%s' "$RESULT" | jq -r '.confidence')
    BUMP_JSON=$(printf '%s' "$RESULT" | jq -c '.bump')
    emit "$DECISION" "null" "$CONF" "$BUMP_JSON" "every technical AC verified, min confidence $CONF"
    ;;
  *)
    halt0 "internal error: unexpected mapper result kind '$KIND'"
    ;;
esac
