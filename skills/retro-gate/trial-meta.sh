#!/usr/bin/env bash
# trial-meta.sh — parse/annotate/strip trial metadata on directive lines (CDV-200 / SPEC-001 M1)
#
# Pure CLI — never sourced. stdout only for data; diagnostics on stderr.
#
# Usage:
#   trial-meta.sh parse <line>
#     → TSV: text\tstart\tsource\treview_after   exit 1 if no trial meta
#   trial-meta.sh annotate --text T --start D --source S --review-after R
#     → "<text> <!-- trial start=D source=S review-after=R -->"
#   trial-meta.sh strip <line>
#     → bare directive line (comment removed; numbering preserved)
#   trial-meta.sh is-elapsed --start D --review-after R --session-mtimes-file F [--today YYYY-MM-DD]
#     → prints "true" or "false" on stdout; exit 0 always (usage error → exit 1)
#
# Comment form: <!-- trial start=YYYY-MM-DD source=<sess>#<anchor> review-after=N-sessions|D-days -->
# Unknown keys inside the comment are ignored (soft).
set -u

usage() {
  echo "usage: trial-meta.sh parse|annotate|strip|is-elapsed ..." >&2
  exit 1
}

# Extract value for key= from trial comment body (space-separated key=value tokens).
_get_kv() {
  # $1 = body (inside <!-- trial ... -->), $2 = key
  local body=$1 key=$2
  # shellcheck disable=SC2086
  printf '%s\n' $body | tr ' ' '\n' | while IFS= read -r tok; do
    case "$tok" in
      ${key}=*) printf '%s\n' "${tok#*=}" ;;
    esac
  done | head -1
}

# Match <!-- trial ... --> (non-greedy body via sed).
# Sets globals: _TRIAL_BODY (inner), _TEXT_BEFORE (line without comment)
_split_trial_comment() {
  local line=$1
  _TRIAL_BODY=""
  _TEXT_BEFORE="$line"
  # Require the word "trial" immediately after <!--
  case "$line" in
    *"<!-- trial "*|*"<!--trial "*) ;;
    *) return 1 ;;
  esac
  # Extract first trial comment body
  _TRIAL_BODY=$(printf '%s' "$line" | sed -n 's/.*<!--[[:space:]]*trial[[:space:]]\{1,\}\([^>]*\)-->.*/\1/p' | head -1)
  [ -n "$_TRIAL_BODY" ] || return 1
  # Strip the comment (and surrounding whitespace before it)
  _TEXT_BEFORE=$(printf '%s' "$line" | sed 's/[[:space:]]*<!--[[:space:]]*trial[[:space:]]\{1,\}[^>]*-->[[:space:]]*//')
  # Trim trailing whitespace on text
  _TEXT_BEFORE=$(printf '%s' "$_TEXT_BEFORE" | sed 's/[[:space:]]*$//')
  return 0
}

cmd_parse() {
  [ $# -ge 1 ] || usage
  local line=$1
  if ! _split_trial_comment "$line"; then
    exit 1
  fi
  local start source review_after
  start=$(_get_kv "$_TRIAL_BODY" "start")
  source=$(_get_kv "$_TRIAL_BODY" "source")
  review_after=$(_get_kv "$_TRIAL_BODY" "review-after")
  # Require all three known keys
  if [ -z "$start" ] || [ -z "$source" ] || [ -z "$review_after" ]; then
    exit 1
  fi
  # TSV: text, start, source, review_after
  printf '%s\t%s\t%s\t%s\n' "$_TEXT_BEFORE" "$start" "$source" "$review_after"
}

cmd_annotate() {
  local text="" start="" source="" review_after=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --text) text=${2:-}; shift 2 ;;
      --start) start=${2:-}; shift 2 ;;
      --source) source=${2:-}; shift 2 ;;
      --review-after) review_after=${2:-}; shift 2 ;;
      -h|--help) usage ;;
      *)
        echo "trial-meta annotate: unknown arg: $1" >&2
        usage
        ;;
    esac
  done
  if [ -z "$text" ] || [ -z "$start" ] || [ -z "$source" ] || [ -z "$review_after" ]; then
    echo "trial-meta annotate: --text --start --source --review-after required" >&2
    exit 1
  fi
  # Strip any existing trial comment from text first (idempotent re-annotate)
  if _split_trial_comment "$text"; then
    text=$_TEXT_BEFORE
  fi
  printf '%s <!-- trial start=%s source=%s review-after=%s -->\n' \
    "$text" "$start" "$source" "$review_after"
}

cmd_strip() {
  [ $# -ge 1 ] || usage
  local line=$1
  if _split_trial_comment "$line"; then
    printf '%s\n' "$_TEXT_BEFORE"
  else
    # No meta — pass through
    printf '%s\n' "$line"
  fi
}

# Convert YYYY-MM-DD → epoch seconds at 00:00:00 UTC (portable).
_date_to_epoch() {
  local d=$1
  if date -u -d "${d} 00:00:00" +%s 2>/dev/null; then
    return 0
  fi
  # BSD date fallback
  date -u -j -f "%Y-%m-%d %H:%M:%S" "${d} 00:00:00" +%s 2>/dev/null
}

# Days between two YYYY-MM-DD (end - start), integer.
_days_between() {
  local start=$1 end=$2
  local s e
  s=$(_date_to_epoch "$start") || return 1
  e=$(_date_to_epoch "$end") || return 1
  echo $(( (e - s) / 86400 ))
}

cmd_is_elapsed() {
  local start="" review_after="" mtimes_file="" today=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --start) start=${2:-}; shift 2 ;;
      --review-after) review_after=${2:-}; shift 2 ;;
      --session-mtimes-file) mtimes_file=${2:-}; shift 2 ;;
      --today) today=${2:-}; shift 2 ;;
      -h|--help) usage ;;
      *)
        echo "trial-meta is-elapsed: unknown arg: $1" >&2
        usage
        ;;
    esac
  done
  if [ -z "$start" ] || [ -z "$review_after" ]; then
    echo "trial-meta is-elapsed: --start and --review-after required" >&2
    exit 1
  fi
  today=${today:-$(date -u +%Y-%m-%d)}

  case "$review_after" in
    *-sessions)
      local n=${review_after%-sessions}
      case "$n" in
        ''|*[!0-9]*)
          echo "trial-meta is-elapsed: bad review-after: $review_after" >&2
          exit 1
          ;;
      esac
      if [ -z "$mtimes_file" ] || [ ! -f "$mtimes_file" ]; then
        echo "false"
        exit 0
      fi
      local start_epoch
      start_epoch=$(_date_to_epoch "$start") || {
        echo "trial-meta is-elapsed: bad start date: $start" >&2
        exit 1
      }
      local count=0 mt
      while IFS= read -r mt || [ -n "$mt" ]; do
        [ -z "$mt" ] && continue
        case "$mt" in
          *[!0-9]*) continue ;;
        esac
        if [ "$mt" -ge "$start_epoch" ]; then
          count=$((count + 1))
        fi
      done <"$mtimes_file"
      if [ "$count" -ge "$n" ]; then
        echo "true"
      else
        echo "false"
      fi
      ;;
    *-days)
      local d=${review_after%-days}
      case "$d" in
        ''|*[!0-9]*)
          echo "trial-meta is-elapsed: bad review-after: $review_after" >&2
          exit 1
          ;;
      esac
      local delta
      delta=$(_days_between "$start" "$today") || {
        echo "trial-meta is-elapsed: date math failed" >&2
        exit 1
      }
      if [ "$delta" -ge "$d" ]; then
        echo "true"
      else
        echo "false"
      fi
      ;;
    *)
      echo "trial-meta is-elapsed: review-after must be N-sessions or D-days" >&2
      exit 1
      ;;
  esac
}

[ $# -ge 1 ] || usage
CMD=$1
shift
case "$CMD" in
  parse)       cmd_parse "$@" ;;
  annotate)    cmd_annotate "$@" ;;
  strip)       cmd_strip "$@" ;;
  is-elapsed)  cmd_is_elapsed "$@" ;;
  *)           usage ;;
esac
