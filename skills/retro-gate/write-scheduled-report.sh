#!/usr/bin/env bash
# write-scheduled-report.sh — write CDV-190 scheduled retro report under $MROOT/.claude/retro/
#
# Usage:
#   write-scheduled-report.sh \
#     --mroot <path> --mode all-auto \
#     [--scanned N] [--skipped N] [--gated N] [--deep N] \
#     [--applied-file PATH] [--followup-file PATH] \
#     [--duplicate-file PATH] [--observations-file PATH] \
#     [--summary TEXT] [--note TEXT] \
#     [--applied-count N] [--followup-count N]
#
# stdout: absolute path of written report
# exit 0 success; 1 usage/IO error
# After write: rotate to keep newest 12 scheduled-*.md
# Optional: if AGENT_WEBHOOK_URL set, fail-open POST (not CDV-210)
set -u

MROOT=""
MODE=""
SCANNED=0
SKIPPED=0
GATED=0
DEEP=0
APPLIED_FILE=""
FOLLOWUP_FILE=""
DUP_FILE=""
OBS_FILE=""
SUMMARY=""
NOTE=""
APPLIED_COUNT=""
FOLLOWUP_COUNT=""

usage() {
  echo "usage: write-scheduled-report.sh --mroot PATH --mode all-auto [options]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mroot)           MROOT=${2:-}; shift 2 ;;
    --mode)            MODE=${2:-}; shift 2 ;;
    --scanned)         SCANNED=${2:-0}; shift 2 ;;
    --skipped)         SKIPPED=${2:-0}; shift 2 ;;
    --gated)           GATED=${2:-0}; shift 2 ;;
    --deep)            DEEP=${2:-0}; shift 2 ;;
    --applied-file)    APPLIED_FILE=${2:-}; shift 2 ;;
    --followup-file)   FOLLOWUP_FILE=${2:-}; shift 2 ;;
    --duplicate-file)  DUP_FILE=${2:-}; shift 2 ;;
    --observations-file) OBS_FILE=${2:-}; shift 2 ;;
    --summary)         SUMMARY=${2:-}; shift 2 ;;
    --note)            NOTE=${2:-}; shift 2 ;;
    --applied-count)   APPLIED_COUNT=${2:-}; shift 2 ;;
    --followup-count)  FOLLOWUP_COUNT=${2:-}; shift 2 ;;
    -h|--help)         usage ;;
    *)
      echo "write-scheduled-report: unknown arg: $1" >&2
      usage
      ;;
  esac
done

[ -n "$MROOT" ] || usage
[ "$MODE" = "all-auto" ] || {
  echo "write-scheduled-report: --mode must be all-auto" >&2
  exit 1
}

RETRO_DIR="$MROOT/.claude/retro"
mkdir -p "$RETRO_DIR" || {
  echo "write-scheduled-report: cannot create $RETRO_DIR" >&2
  exit 1
}

TS=$(date -u +%Y-%m-%dT%H%M%SZ)
REPORT="$RETRO_DIR/scheduled-${TS}.md"
# Avoid collision if two writes in same second.
if [ -e "$REPORT" ]; then
  REPORT="$RETRO_DIR/scheduled-${TS}-$$.md"
fi

# Count applied/followup from files if counts not provided.
if [ -z "$APPLIED_COUNT" ]; then
  if [ -n "$APPLIED_FILE" ] && [ -f "$APPLIED_FILE" ]; then
    APPLIED_COUNT=$(grep -c . "$APPLIED_FILE" 2>/dev/null || echo 0)
  else
    APPLIED_COUNT=0
  fi
fi
if [ -z "$FOLLOWUP_COUNT" ]; then
  if [ -n "$FOLLOWUP_FILE" ] && [ -f "$FOLLOWUP_FILE" ]; then
    FOLLOWUP_COUNT=$(grep -c . "$FOLLOWUP_FILE" 2>/dev/null || echo 0)
  else
    FOLLOWUP_COUNT=0
  fi
fi
# Normalize possible "0\n0" from grep -c || echo
APPLIED_COUNT=$(printf '%s' "$APPLIED_COUNT" | head -1 | tr -cd '0-9')
FOLLOWUP_COUNT=$(printf '%s' "$FOLLOWUP_COUNT" | head -1 | tr -cd '0-9')
APPLIED_COUNT=${APPLIED_COUNT:-0}
FOLLOWUP_COUNT=${FOLLOWUP_COUNT:-0}

tmp="${REPORT}.tmp.$$"
{
  printf '%s\n' "# Scheduled retro report"
  printf '%s\n' "- timestamp: $TS"
  printf '%s\n' "- mode: --all --auto"
  printf '%s\n' "- sessions: scanned=$SCANNED skipped=$SKIPPED gated=$GATED deep-read=$DEEP"
  printf '\n'

  if [ -n "$NOTE" ]; then
    printf '%s\n\n' "## Note"
    printf '%s\n\n' "$NOTE"
  fi

  printf '%s\n' "## Applied"
  if [ -n "$APPLIED_FILE" ] && [ -f "$APPLIED_FILE" ] && [ -s "$APPLIED_FILE" ]; then
    # TSV: target\taction\tsummary → readable bullets
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      t=$(printf '%s' "$line" | cut -f1)
      a=$(printf '%s' "$line" | cut -f2)
      s=$(printf '%s' "$line" | cut -f3-)
      printf -- '- target=%s action=%s: %s\n' "$t" "$a" "$s"
    done <"$APPLIED_FILE"
  else
    printf '%s\n' "(none)"
  fi
  printf '\n'

  printf '%s\n' "## Manual follow-up"
  if [ -n "$FOLLOWUP_FILE" ] && [ -f "$FOLLOWUP_FILE" ] && [ -s "$FOLLOWUP_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      printf -- '- %s\n' "$line"
    done <"$FOLLOWUP_FILE"
  else
    printf '%s\n' "(none)"
  fi
  printf '\n'

  printf '%s\n' "## Duplicates (advisory)"
  if [ -n "$DUP_FILE" ] && [ -f "$DUP_FILE" ] && [ -s "$DUP_FILE" ]; then
    cat "$DUP_FILE"
    printf '\n'
  else
    printf '%s\n\n' "(none)"
  fi

  printf '%s\n' "## Observations"
  if [ -n "$OBS_FILE" ] && [ -f "$OBS_FILE" ] && [ -s "$OBS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      printf -- '- %s\n' "$line"
    done <"$OBS_FILE"
  else
    printf '%s\n' "(none)"
  fi
  printf '\n'

  printf '%s\n' "## Summary"
  if [ -n "$SUMMARY" ]; then
    printf '%s\n' "$SUMMARY"
  else
    printf '%s\n' "Applied: $APPLIED_COUNT | Manual follow-up: $FOLLOWUP_COUNT | scanned=$SCANNED skipped=$SKIPPED gated=$GATED deep-read=$DEEP"
  fi
  printf '\n'
} >"$tmp" || {
  rm -f "$tmp"
  echo "write-scheduled-report: write failed" >&2
  exit 1
}

mv -f "$tmp" "$REPORT" || {
  rm -f "$tmp"
  echo "write-scheduled-report: rename failed" >&2
  exit 1
}

# Retention: keep newest 12 scheduled-*.md only (never touch lock/friction.jsonl).
# shellcheck disable=SC2012
(
  cd "$RETRO_DIR" || exit 0
  # ls -1t: newest first; drop from 13th onward
  ls -1t scheduled-*.md 2>/dev/null | tail -n +13 | while IFS= read -r old; do
    [ -n "$old" ] && rm -f -- "$old"
  done
)

# Thin optional webhook (fail-open; not CDV-210). Summary counts only — no transcript.
if [ -n "${AGENT_WEBHOOK_URL:-}" ]; then
  curl -sS -m 5 -X POST "$AGENT_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"event\":\"scheduled_retro\",\"report_path\":\"$REPORT\",\"applied\":$APPLIED_COUNT,\"manual_followup\":$FOLLOWUP_COUNT,\"timestamp\":\"$TS\"}" \
    >/dev/null 2>&1 || true
fi

# Absolute path on stdout.
case "$REPORT" in
  /*) printf '%s\n' "$REPORT" ;;
  *)  printf '%s\n' "$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")" ;;
esac
exit 0
