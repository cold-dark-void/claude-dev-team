#!/usr/bin/env bash
# intercom.sh — the intercom CLI (SPEC-038). Subprocess only: never source it.
#
#   intercom ask [--sid S] TEXT
#   intercom send [--sid S] [--summary T] [--file P] TEXT
#   intercom away [on|off|status]
#   intercom help
#
# ask writes a pending question (the poller escalates it); send writes an
# outbox record (the poller drains it to Telegram); away toggles/reads
# state/away. ask and send do no network I/O. Exit codes: 0 success, 1
# operational failure, 2 usage/sid failure.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "intercom.sh is a subprocess CLI (SPEC-038); source common.sh for the library." >&2
  return 1
fi

ir_usage() {
  cat <<'EOF'
usage: intercom ask [--sid S] TEXT
       intercom send [--sid S] [--summary T] [--file P] TEXT
       intercom away [on|off|status]
       intercom help

TEXT may be a single quoted argument; multiple words are joined with spaces.
`--` stops option parsing and sends the rest verbatim. ask prints the qid;
send prints the record path; away prints `away: on` or `away: off`.
EOF
}

ir_usage_exit() {
  ir_usage >&2
  exit 2
}

ir_join_text() {
  # Remaining words joined with single spaces ("" when absent).
  local acc=""
  while [ $# -gt 0 ]; do
    acc="${acc:+$acc }$1"
    shift
  done
  printf '%s' "$acc"
}

ir_cli_ask() {
  local sid="" text=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sid)
        [ $# -ge 2 ] || { echo "intercom ask: --sid needs a value" >&2; exit 2; }
        sid="$2"; shift 2
        ;;
      --sid=*)
        sid="${1#*=}"; shift
        ;;
      --)
        shift
        text=$(ir_join_text "$@")
        shift $#
        ;;
      -*)
        echo "intercom ask: unknown option: $1" >&2
        ir_usage_exit
        ;;
      *)
        text="${text:+$text }$1"
        shift
        ;;
    esac
  done
  if [ -z "$text" ]; then
    echo "intercom ask: TEXT is required" >&2
    ir_usage_exit
  fi
  ir_require_tools jq || exit 1
  if ! sid=$(ir_resolve_sid "$sid"); then
    ir_usage_exit
  fi
  ir_pending_write "$sid" "$text" || exit 1
}

ir_cli_send() {
  local sid="" summary="" file="" text=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sid)
        [ $# -ge 2 ] || { echo "intercom send: --sid needs a value" >&2; exit 2; }
        sid="$2"; shift 2
        ;;
      --sid=*)
        sid="${1#*=}"; shift
        ;;
      --summary)
        [ $# -ge 2 ] || { echo "intercom send: --summary needs a value" >&2; exit 2; }
        summary="$2"; shift 2
        ;;
      --summary=*)
        summary="${1#*=}"; shift
        ;;
      --file)
        [ $# -ge 2 ] || { echo "intercom send: --file needs a value" >&2; exit 2; }
        file="$2"; shift 2
        ;;
      --file=*)
        file="${1#*=}"; shift
        ;;
      --)
        shift
        text=$(ir_join_text "$@")
        shift $#
        ;;
      -*)
        echo "intercom send: unknown option: $1" >&2
        ir_usage_exit
        ;;
      *)
        text="${text:+$text }$1"
        shift
        ;;
    esac
  done
  if [ -z "$text" ]; then
    echo "intercom send: TEXT is required" >&2
    ir_usage_exit
  fi
  ir_require_tools jq || exit 1
  if ! sid=$(ir_resolve_sid "$sid"); then
    ir_usage_exit
  fi
  if [ -n "$file" ] && [ ! -f "$file" ]; then
    echo "intercom send: --file does not exist: $file" >&2
    exit 1
  fi
  # Longread rule: above concise_threshold the record must carry a summary so
  # the poller sends one concise message plus one document — never chunk-split.
  local threshold
  threshold=$(ir_config_field concise_threshold 1024)
  case "$threshold" in
    ''|*[!0-9]*) threshold=1024 ;;
  esac
  if [ -z "$summary" ]; then
    local tlen
    tlen=$(jq -rn --arg t "$text" '$t | length') || tlen=0
    if [ "$tlen" -gt "$threshold" ]; then
      summary=$(ir_gen_summary "$text") || summary=""
    fi
  fi
  ir_outbox_write "$sid" "$text" "$summary" "$file" || exit 1
}

ir_cli_away() {
  local arg="${1:-status}"
  case "$arg" in
    on|off|status) ;;
    *)
      echo "intercom away: expected on|off|status, got: $arg" >&2
      ir_usage_exit
      ;;
  esac
  local statedir f
  statedir=$(ir_state_dir) || exit 1
  f="$statedir/away"
  case "$arg" in
    on)
      # state/away present = on (AC20); content is the epoch for the audit trail.
      if ! atomic_write "$f" date +%s; then
        echo "intercom: cannot write $f" >&2
        exit 1
      fi
      printf 'away: on\n'
      ;;
    off)
      if ! rm -f "$f"; then
        echo "intercom: cannot remove $f" >&2
        exit 1
      fi
      printf 'away: off\n'
      ;;
    status)
      if [ -f "$f" ]; then
        printf 'away: on\n'
      else
        printf 'away: off\n'
      fi
      ;;
  esac
}

main() {
  if [ $# -lt 1 ]; then
    ir_usage >&2
    exit 2
  fi
  local cmd="$1"
  shift
  case "$cmd" in
    ask) ir_cli_ask "$@" ;;
    send) ir_cli_send "$@" ;;
    away) ir_cli_away "$@" ;;
    help|-h|--help) ir_usage ;;
    *)
      echo "intercom: unknown verb: $cmd" >&2
      ir_usage >&2
      exit 2
      ;;
  esac
}

main "$@"
