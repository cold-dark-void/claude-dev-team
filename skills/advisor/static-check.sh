#!/usr/bin/env bash
# static-check.sh — cheap pre-probe checks before an advisor trigger-(b) probe
# is spent (SPEC-039 M19, epic child CDT-564-C5).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT. Deterministic bash+jq:
# no LLM, no agent spawn.
#
#   static-check.sh run    --question TEXT --evidence-dir DIR --run-id ID
#   static-check.sh hash   --question TEXT --evidence-dir DIR
#   static-check.sh verify --run-id ID --question-hash H
#
# `run` derives cheap checks from the question — `command -v` per candidate
# tool token (locates, never executes the binary), repo-docs grep over
# $MROOT/specs + $MROOT/docs + README.md, and — ONLY when
# ADVISOR_STATIC_HOST_CMDS=1 (host safeguards allow it) — `pacman -Q` per
# token plus `file`/`strings` per path token found in the question. Without
# that flag the host family is recorded as skipped and nothing is executed.
#
# Evidence is paths, never embedded prose (M18): every check's output goes to
# a file inside the evidence dir; docs hits are `path:line` locators; the
# summary <evidence-dir>/static-check.json holds only check names, exit codes,
# and output PATHS. The file set is deterministic (no timestamps), so the
# question hash ask.sh computes over the dir is stable across re-runs.
#
# The question hash is ask.sh's algorithm (sha256 of trigger + normalized
# question + evidence-dir content hash), computed AFTER the outputs are
# written, so a probe over the same dir dedupes to the same hash. `run` also
# writes a receipt under
# $ADVISOR_STATE_ROOT/runs/<run_id>/static-check-receipts/<hash>.json;
# `verify` exits 0 only for a hash that has run (M19: probe MUST NOT start
# otherwise). The trigger-(b) procedure in skills/advisor/SKILL.md and the
# hook fences run static-check before ask.sh probe.

set -u

usage() {
  cat >&2 <<'EOF'
usage: static-check.sh run    --question TEXT --evidence-dir DIR --run-id ID
       static-check.sh hash   --question TEXT --evidence-dir DIR
       static-check.sh verify --run-id ID --question-hash H
EOF
  exit 64
}

die() { echo "static-check.sh: $1" >&2; exit "$2"; }

MODE="${1:-}"
[ -n "$MODE" ] || usage
shift
case "$MODE" in run|hash|verify) ;; *) usage ;; esac

QUESTION="" EVIDENCE_DIR="" RUN_ID="" QHASH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --question) [ $# -ge 2 ] || usage; QUESTION="$2"; shift 2 ;;
    --question=*) QUESTION="${1#*=}"; shift ;;
    --evidence-dir) [ $# -ge 2 ] || usage; EVIDENCE_DIR="$2"; shift 2 ;;
    --evidence-dir=*) EVIDENCE_DIR="${1#*=}"; shift ;;
    --run-id) [ $# -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
    --run-id=*) RUN_ID="${1#*=}"; shift ;;
    --question-hash) [ $# -ge 2 ] || usage; QHASH="$2"; shift 2 ;;
    --question-hash=*) QHASH="${1#*=}"; shift ;;
    *) usage ;;
  esac
done

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ADVISOR_DIR="${ADVISOR_STATE_ROOT:-$MROOT/.claude/advisor}"

# Same normalization + evidence hash as ask.sh (sha256 of
# "trigger|question|evidence_hash"); question_hash("b", q, dir).
norm_question() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }
evidence_hash() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then printf 'none' | sha256sum | cut -d" " -f1; return; fi
  ( cd "$dir" && find . -type f ! -name '.*' -print0 2>/dev/null | sort -z \
      | xargs -0 -r sha256sum ) | sha256sum | cut -d" " -f1
}
question_hash() { # question_hash <question> <evidence_dir>
  local eh
  eh=$(evidence_hash "$2")
  printf '%s' "b|$(norm_question "$1")|$eh" | sha256sum | cut -d" " -f1
}

if [ "$MODE" = "hash" ]; then
  [ -n "$QUESTION" ] || usage
  question_hash "$QUESTION" "$EVIDENCE_DIR"
  exit 0
fi

if [ "$MODE" = "verify" ]; then
  [ -n "$RUN_ID" ] && [ -n "$QHASH" ] || usage
  RCPT="$ADVISOR_DIR/runs/$RUN_ID/static-check-receipts/$QHASH.json"
  if [ -f "$RCPT" ] && [ "$(jq -r '.question_hash // empty' "$RCPT" 2>/dev/null)" = "$QHASH" ]; then
    exit 0
  fi
  exit 1
fi

# ---- run ----------------------------------------------------------------------
[ -n "$QUESTION" ] && [ -n "$EVIDENCE_DIR" ] && [ -n "$RUN_ID" ] || usage
mkdir -p "$EVIDENCE_DIR" || die "cannot create evidence dir $EVIDENCE_DIR" 1

# Candidate tool tokens: lowercase word tokens (len>=2). Candidate paths:
# absolute paths that exist. Tokens are charset-validated before any command
# sees them (untrusted input is argv, never code — AGENTS.md).
TOKENS=$(printf '%s\n' "$(norm_question "$QUESTION")" | tr '[:space:]' '\n' \
  | grep -E '^[a-z][a-z0-9._-]{1,30}$' \
  | grep -vxE 'is|not|isnt|the|are|for|and|with|does|exist|tool|version|running|use|used|our|its|this|that|installed|present|available|missing|machine|host|box|on|in|at|by|to|of|it|we|run|here|there|plan|step|check|make|sure|verify|confirm|actually|really|still|now|host.|which|what|where|when|who|how|why' \
  | sort -u | head -8)
PATHS=$(printf '%s\n' "$(norm_question "$QUESTION")" | tr '[:space:]' '\n' \
  | grep -E '^/[^[:space:]]+$' | sort -u | while IFS= read -r p; do [ -e "$p" ] && printf '%s\n' "$p"; done | head -8)

# checks TSV: check<TAB>cmd<TAB>exit<TAB>output   (skipped: exit = "skip")
CHECKS_TSV=$(mktemp "${TMPDIR:-/tmp}/static-check.XXXXXX") || die "mktemp failed" 1
trap 'rm -f "$CHECKS_TSV"' EXIT

while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  OUT="$EVIDENCE_DIR/cmdv-$tok.txt"
  if command -v "$tok" > "$OUT" 2>&1; then EXIT=0; else EXIT=$?; fi
  printf 'command-v\tcommand -v %s\t%s\t%s\n' "$tok" "$EXIT" "$OUT" >> "$CHECKS_TSV"
done <<EOF
$TOKENS
EOF

if [ "${ADVISOR_STATIC_HOST_CMDS:-}" = "1" ]; then
  if command -v pacman > /dev/null 2>&1; then
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      OUT="$EVIDENCE_DIR/pacman-$tok.txt"
      pacman -Q "$tok" > "$OUT" 2>&1 && EXIT=0 || EXIT=$?
      printf 'pacman\tpacman -Q %s\t%s\t%s\n' "$tok" "$EXIT" "$OUT" >> "$CHECKS_TSV"
    done <<EOF
$TOKENS
EOF
  else
    printf 'pacman\t\tpacman -Q <token>\tskip\tno pacman on host\n' >> "$CHECKS_TSV"
  fi
  PIDX=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    PIDX=$((PIDX + 1))
    OUT="$EVIDENCE_DIR/file-$PIDX.out"
    file "$p" > "$OUT" 2>&1 && EXIT=0 || EXIT=$?
    printf 'file\tfile %s\t%s\t%s\n' "$p" "$EXIT" "$OUT" >> "$CHECKS_TSV"
    OUT="$EVIDENCE_DIR/strings-$PIDX.out"
    strings "$p" > "$OUT" 2>&1 && EXIT=0 || EXIT=$?
    printf 'strings\tstrings %s\t%s\t%s\n' "$p" "$EXIT" "$OUT" >> "$CHECKS_TSV"
  done <<EOF
$PATHS
EOF
else
  printf 'host-cmds\tpacman -Q / file / strings\tskip\tADVISOR_STATIC_HOST_CMDS unset (host safeguards)\n' >> "$CHECKS_TSV"
fi

# Repo docs: path:line locators only (M18 discipline — no match text).
DOCS_HITS="$EVIDENCE_DIR/docs-hits.txt"
: > "$DOCS_HITS"
for DOCROOT in "$MROOT/specs" "$MROOT/docs" "$MROOT/README.md"; do
  [ -e "$DOCROOT" ] || continue
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    grep -rn -- "$tok" "$DOCROOT" 2>/dev/null | cut -d: -f1-2
  done <<EOF
$TOKENS
EOF
done | sort -u | head -50 >> "$DOCS_HITS" || true

# Summary JSON: names, exit codes, output PATHS. Evidence output never rides
# inside the JSON — every command's raw output stays in its file.
jq -cn --arg q "$(norm_question "$QUESTION")" --arg docs "$DOCS_HITS" --arg tsv "$(cat "$CHECKS_TSV")" '
  { question: $q,
    checks: ($tsv | split("\n") | map(select(length > 0))
      | map(capture("(?<check>[^\t]*)\t(?<cmd>[^\t]*)\t(?<exit>[^\t]*)\t(?<output>.*)"))
      | map(if .exit == "skip"
            then { check: .check, cmd: .cmd, status: "skipped", reason: .output }
            else { check: .check, cmd: .cmd, status: "ran",
                   exit: (.exit | tonumber), output: .output } end)),
    docs_hits: $docs }' > "$EVIDENCE_DIR/static-check.json" \
  || die "cannot write $EVIDENCE_DIR/static-check.json" 1

# Receipt keyed by the question hash the probe will compute (post-write, so
# it matches ask.sh probe over the same evidence dir).
HASH=$(question_hash "$QUESTION" "$EVIDENCE_DIR")
mkdir -p "$ADVISOR_DIR/runs/$RUN_ID/static-check-receipts"
jq -cn --arg hash "$HASH" --arg ev "$EVIDENCE_DIR" \
  '{question_hash:$hash, evidence_dir:$ev}' \
  > "$ADVISOR_DIR/runs/$RUN_ID/static-check-receipts/$HASH.json"

printf '%s\n' "$HASH"
exit 0
