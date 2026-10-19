#!/usr/bin/env bash
# residue.sh — deterministic trigger-(c) council-residue detector (SPEC-039
# M20, epic child C6/CDT-561).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT. Deterministic bash+jq
# only: no LLM call, no spawn, no network, no advisor invocation.
#
#   bash skills/advisor/residue.sh --meta PATH.finalize-meta.json \
#        [--report PATH] [--threshold N]
#
# --meta (required) is the council engine's `.finalize-meta.json` sidecar
# (skills/council/engine-finalize.sh). --report optionally points at the
# rendered report — its degraded banner is a second degraded signal.
# --threshold is the pass threshold (default 80; integer 0-100) — the same
# 80 the ship-gate verdict mapper (SPEC-033 M14(b)) and the M29 decision map
# use.
#
# stdout: exactly one JSON object
#   {"residue":<bool>,"kinds":[...],
#    "below_threshold":{"present":<bool>,"count":N,"items":[...]},
#    "contradicted":  {"present":<bool>,"count":N,"items":[...]},
#    "unverified":    {"present":<bool>,"count":N,"items":[...]},
#    "degraded":      {"present":<bool>,"reasons":[...]}}
#
# Residue kinds (M20):
#   below-threshold — any unstruck item (verdict or finding) with confidence
#                     below the threshold (M14(b) step 6 disagree rule).
#   contradicted    — unstruck verdict_counts CONTRADICTED or FABRICATED > 0
#                     (FABRICATED is the worse split of the same class).
#   unverified      — unstruck verdict_counts UNVERIFIED > 0.
#   degraded        — verification_mode "self-verified" (M14(d)) and/or a
#                     `self-verified — refuters unavailable` banner in
#                     --report.
#
# A clean pass (every unstruck verdict VERIFIED/PARTIALLY_VERIFIED at
# confidence >= 80, verification_mode full, no banner) emits residue:false
# with all kinds absent — the M20 zero-advisor guarantee.
#
# Exit 0 on any scan; 64 on usage errors only (missing/unknown flag,
# missing --meta file, unreadable/non-object meta, bad --report value,
# non-integer or out-of-range --threshold).

set -u

usage() {
  cat >&2 <<'EOF'
usage: residue.sh --meta PATH.finalize-meta.json [--report PATH] [--threshold N]
EOF
  exit 64
}

die64() { echo "residue.sh: $1" >&2; exit 64; }

META="" REPORT="" THRESHOLD="80"
while [ $# -gt 0 ]; do
  case "$1" in
    --meta) [ $# -ge 2 ] || usage; META="$2"; shift 2 ;;
    --meta=*) META="${1#*=}"; shift ;;
    --report) [ $# -ge 2 ] || usage; REPORT="$2"; shift 2 ;;
    --report=*) REPORT="${1#*=}"; shift ;;
    --threshold) [ $# -ge 2 ] || usage; THRESHOLD="$2"; shift 2 ;;
    --threshold=*) THRESHOLD="${1#*=}"; shift ;;
    *) usage ;;
  esac
done
[ -n "$META" ] || usage
[ -f "$META" ] || die64 "no such meta sidecar: $META"
case "$THRESHOLD" in
  ''|*[!0-9]*) die64 "--threshold must be an integer 0-100" ;;
esac
[ "$THRESHOLD" -le 100 ] || die64 "--threshold must be an integer 0-100"
if [ -n "$REPORT" ] && [ ! -f "$REPORT" ]; then
  die64 "no such report: $REPORT"
fi

jq empty "$META" 2>/dev/null || die64 "meta sidecar is not valid JSON: $META"
jq -e 'type == "object"' "$META" >/dev/null 2>&1 || die64 "meta sidecar is not a JSON object"

# ---- verdict[] runs: unstruck_verdicts + verdict_counts ----------------------
# Item shape (engine-finalize.sh): {claim, verdict, confidence, evidence_blob}.

V_BELOW=$(jq -c --argjson th "$THRESHOLD" '
  [ (.unstruck_verdicts // [])[] | select((.confidence // 0) < $th)
    | {claim: (.claim // ""), verdict: (.verdict // ""), confidence: .confidence} ]' "$META" 2>/dev/null)
V_CONTRA=$(jq -c --argjson th "$THRESHOLD" '
  [ (.unstruck_verdicts // [])[] | select(.verdict == "CONTRADICTED" or .verdict == "FABRICATED")
    | {claim: (.claim // ""), verdict: .verdict, confidence: .confidence} ]' "$META" 2>/dev/null)
V_UNVER=$(jq -c '
  [ (.unstruck_verdicts // [])[] | select(.verdict == "UNVERIFIED")
    | {claim: (.claim // ""), verdict: .verdict, confidence: .confidence} ]' "$META" 2>/dev/null)

# ---- finding[] runs: unstruck_findings ---------------------------------------
# Item shape: {file, line, severity, confidence, ...} (engine-finalize.sh).
F_BELOW=$(jq -c --argjson th "$THRESHOLD" '
  [ (.unstruck_findings // [])[] | select((.confidence // 0) < $th)
    | {locator: ((.file // "") + ":" + ((.line // 0) | tostring)),
       severity: (.severity // ""), confidence: .confidence} ]' "$META" 2>/dev/null)

# ---- degraded: sidecar verification_mode + optional report banner ------------
REASONS=$(jq -cn --arg mode "$(jq -r '.verification_mode // ""' "$META")" '
  [ if $mode == "self-verified" then "verification_mode=self-verified" else empty end ]')
if [ -n "$REPORT" ] && grep -q 'self-verified — refuters unavailable' "$REPORT"; then
  REASONS=$(printf '%s' "$REASONS" | jq -c '. + ["report-banner"]')
fi

OUT=$(jq -cn \
  --argjson v_below "$V_BELOW" --argjson v_contra "$V_CONTRA" --argjson v_unver "$V_UNVER" \
  --argjson f_below "$F_BELOW" \
  --argjson reasons "$REASONS" \
  --argjson th "$THRESHOLD" '
  ([$v_below[], $f_below[]]) as $below |
  ($reasons | length) as $deg_n |
  {
    residue: (if ($below | length) > 0 or ($v_contra | length) > 0 or ($v_unver | length) > 0 or $deg_n > 0
              then true else false end),
    kinds: ([ if ($below | length) > 0 then "below-threshold" else empty end,
              if ($v_contra | length) > 0 then "contradicted" else empty end,
              if ($v_unver | length) > 0 then "unverified" else empty end,
              if $deg_n > 0 then "degraded" else empty end ]),
    below_threshold: {present: (if ($below | length) > 0 then true else false end),
                      count: ($below | length), items: $below},
    contradicted: {present: (if ($v_contra | length) > 0 then true else false end),
                   count: ($v_contra | length), items: $v_contra},
    unverified: {present: (if ($v_unver | length) > 0 then true else false end),
                 count: ($v_unver | length), items: $v_unver},
    degraded: {present: (if $deg_n > 0 then true else false end), reasons: $reasons},
    threshold: $th
  }')

printf '%s\n' "$OUT"
exit 0
