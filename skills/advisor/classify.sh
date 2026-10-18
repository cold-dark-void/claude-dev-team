#!/usr/bin/env bash
# classify.sh — mechanical trigger-(b) empirical-claim classifier (SPEC-039
# M14/M15/M16/M17, epic child CDT-564-C5).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT. It is deterministic
# POSIX-ERE only: no LLM call, no spawn, no network, no advisor invocation.
#
#   bash skills/advisor/classify.sh --kind wave-plan    (--file PATH|--text TEXT)
#   bash skills/advisor/classify.sh --kind disposition --action close \
#        (--file PATH|--text TEXT) [--run-id ID]
#
# Text comes from --file, --text, or stdin. stdout: exactly one JSON array of
# hits `{"trigger":"b","class":"identity|disposition","span":...,
# "question_hash":...}` (M14). Empty array = no fire. Exit 0 on any scan;
# 64 on usage errors (unknown kind, disposition without a valid --action,
# --action on kind=wave-plan, missing --file).
#
# M15 — disposition class: fires only when --action is in
# {close,block,descope,reassign} (the structured arg; freeform prose is never
# scanned for those verbs). One disposition hit is emitted for the write plus
# identity hits from the scanned text.
#
# M16 — identity-claim class (case-sensitive subject rules; subject is a
# lowercase token `^[a-z][a-z0-9._+-]*$` or an absolute path
# `^/[^[:space:]]+$`):
#   1. `<subject> on this (machine|host|box) (is|is not|isn't|are|aren't) …`
#   2. `<subject> (is|is not|isn't) (installed|present|available|missing|not installed)`
#   3. `<subject> (is|is not|isn't) <ProperName>`  (ProperName starts `[A-Z]`)
# Patterns run in order 1,2,3; a later match overlapping an earlier span on
# the same line is skipped, so `omp on this machine is Open MPI` yields the
# pattern-1 hit and not a spurious `machine is Open` pattern-3 hit.
#
# question_hash: sha256 of `b|` + the whitespace-normalized span (the whole
# normalized text for the disposition hit) — the same normalization the probe
# seam applies to --question.
#
# M17 — miss sampling: a zero-hit scan is a silent skip. With --run-id, the
# scanned input is hashed (sha256); when `hash % 10 == 0` (first 13 hex chars
# read as one integer), exactly one `class=miss-sample` row is appended to
# `$ADVISOR_STATE_ROOT/runs/<run_id>/shadow.jsonl` (default
# `$MROOT/.claude/advisor/`). It NEVER spawns and writes nothing else.

set -u

usage() {
  cat >&2 <<'EOF'
usage: classify.sh --kind wave-plan    (--file PATH | --text TEXT) [--run-id ID]
       classify.sh --kind disposition --action close|block|descope|reassign
                    (--file PATH | --text TEXT) [--run-id ID]
EOF
  exit 64
}

die64() { echo "classify.sh: $1" >&2; exit 64; }

KIND="" TEXT="" FILE="" ACTION="" RUN_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) [ $# -ge 2 ] || usage; KIND="$2"; shift 2 ;;
    --kind=*) KIND="${1#*=}"; shift ;;
    --text) [ $# -ge 2 ] || usage; TEXT="$2"; shift 2 ;;
    --text=*) TEXT="${1#*=}"; shift ;;
    --file) [ $# -ge 2 ] || usage; FILE="$2"; shift 2 ;;
    --file=*) FILE="${1#*=}"; shift ;;
    --action) [ $# -ge 2 ] || usage; ACTION="$2"; shift 2 ;;
    --action=*) ACTION="${1#*=}"; shift ;;
    --run-id) [ $# -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
    --run-id=*) RUN_ID="${1#*=}"; shift ;;
    *) usage ;;
  esac
done
case "$KIND" in wave-plan|disposition) ;; *) usage ;; esac
if [ "$KIND" = "disposition" ]; then
  case "$ACTION" in close|block|descope|reassign) ;; *) usage ;; esac
else
  [ -z "$ACTION" ] || die64 "--action applies only to --kind disposition (M15)"
fi
if [ -n "$FILE" ]; then
  [ -z "$TEXT" ] || die64 "--file and --text are mutually exclusive"
  [ -f "$FILE" ] || die64 "no such file: $FILE"
  INPUT=$(cat "$FILE")
elif [ -n "$TEXT" ]; then
  INPUT="$TEXT"
else
  INPUT=$(cat)
fi

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ADVISOR_DIR="${ADVISOR_STATE_ROOT:-$MROOT/.claude/advisor}"

# ---- scan: one awk pass, POSIX ERE, longest-first verb alternation ----------
# Each output line: identity<TAB><span> (leading guard space stripped).
HITS_RAW=$(printf '%s\n' "$INPUT" | awk -v P1='(^|[[:space:]])([a-z][a-z0-9._+-]*|/[^[:space:]]+)[[:space:]]+on[[:space:]]+this[[:space:]]+(machine|host|box)[[:space:]]+(is not|isn'"'"'t|aren'"'"'t|are|is)([^a-zA-Z0-9._'"'"'+-]|$)' \
    -v P2='(^|[[:space:]])([a-z][a-z0-9._+-]*|/[^[:space:]]+)[[:space:]]+(is not|isn'"'"'t|is)[[:space:]]+(installed|present|available|missing|not[[:space:]]+installed)([^a-zA-Z0-9._'"'"'+-]|$)' \
    -v P3='(^|[[:space:]])([a-z][a-z0-9._+-]*|/[^[:space:]]+)[[:space:]]+(is not|isn'"'"'t|is)[[:space:]]+([A-Z][A-Za-z0-9._+-]*)' '
BEGIN { P[1] = P1; P[2] = P2; P[3] = P3 }
{
  nspans = 0
  for (p = 1; p <= 3; p++) {
    s = $0; off = 0
    while (match(s, P[p])) {
      start = off + RSTART; len = RLENGTH
      overlap = 0
      for (i = 1; i <= nspans; i++) {
        if (start < span_start[i] + span_len[i] && span_start[i] < start + len) { overlap = 1; break }
      }
      if (!overlap) {
        nspans++
        span_start[nspans] = start; span_len[nspans] = len
        span = substr($0, start, len)
        sub(/^[[:space:]]+/, "", span)
        print "identity\t" span
      }
      off = off + RSTART + RLENGTH - 1
      s = substr($0, off + 1)
      if (s == "") break
    }
  }
}')

# M17 input hash: sha256 of the scanned bytes (file content, or the exact
# --text/stdin payload). 13 hex chars = 52 bits, safe in 64-bit arithmetic.
INPUT_SHA=$(printf '%s' "$INPUT" | sha256sum | cut -d' ' -f1)

norm_span() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

# ---- build the hit array -----------------------------------------------------
# Span text is data: it travels only inside JSON strings (jq), never as an
# interpolated shell word. question_hash = sha256("b|" + normalized span) is
# added per hit in bash (jq has no sha256).
OUT=$(jq -cn \
  --arg kind "$KIND" \
  --arg norm_text "$(norm_span "$INPUT")" \
  --arg raw "$HITS_RAW" '
  [ if $kind == "disposition" then
      { trigger: "b", class: "disposition", span: $norm_text } else empty end ]
  + ($raw | split("\n") | map(select(length > 0))
     | map(capture("(?<class>[^\t]+)\t(?<span>.*)"))
     | map({ trigger: "b", class: .class, span: .span }))')

N=$(printf '%s' "$OUT" | jq 'length')
FINAL="["
i=0
while [ "$i" -lt "$N" ]; do
  H=$(printf '%s' "$OUT" | jq -c ".[$i]")
  SPAN=$(printf '%s' "$H" | jq -r '.span')
  QH=$(printf 'b|%s' "$(norm_span "$SPAN")" | sha256sum | cut -d' ' -f1)
  H=$(printf '%s' "$H" | jq -c --arg qh "$QH" '.question_hash = $qh')
  [ "$i" -eq 0 ] || FINAL="$FINAL,"
  FINAL="$FINAL$H"
  i=$((i + 1))
done
FINAL="$FINAL]"

# ---- M17 miss sampling: zero hits -> silent skip, 10% shadow row ------------
if [ "$N" -eq 0 ] && [ -n "$RUN_ID" ]; then
  H13="0x${INPUT_SHA%%"${INPUT_SHA#?????????????}"}"
  if [ $(( H13 % 10 )) -eq 0 ]; then
    mkdir -p "$ADVISOR_DIR/runs/$RUN_ID"
    printf '{"class":"miss-sample","kind":"%s","sha256":"%s","ts":"%s"}\n' \
      "$KIND" "$INPUT_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> "$ADVISOR_DIR/runs/$RUN_ID/shadow.jsonl"
  fi
fi

printf '%s\n' "$FINAL"
exit 0
