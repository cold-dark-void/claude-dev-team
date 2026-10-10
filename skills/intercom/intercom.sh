#!/usr/bin/env bash
# intercom.sh — the intercom CLI (SPEC-038). Subprocess only: never source it.
#
#   intercom ask [--sid S] TEXT
#   intercom send [--sid S] [--summary T] [--file P] TEXT
#   intercom read [--sid S] [--ack]
#   intercom away [on|off|status]
#   intercom help
#
# ask writes a pending question (the poller escalates it); send writes an
# outbox record (the poller drains it to Telegram); read prints (and with
# --ack consumes) the session inbox; away toggles/reads state/away. ask and
# send do no network I/O. Exit codes: 0 success, 1 operational failure, 2
# usage/sid failure.
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
       intercom read [--sid S] [--ack]
       intercom away [on|off|status]
       intercom help

TEXT may be a single quoted argument; multiple words are joined with spaces.
`--` stops option parsing and sends the rest verbatim. ask prints the qid;
send prints the record path; read prints the inbox records (with --ack it
consumes them into spool/<sid>/consumed/); away prints `away: on` or
`away: off`.
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
  ir_away_sid_refresh "$sid"
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
  ir_away_sid_refresh "$sid"
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
      # A session origin must know its sid: resolve before any state write, so
      # an unresolvable sid leaves away untouched (exit 1, CDT-535).
      local asid
      if ! asid=$(ir_resolve_sid ""); then
        exit 1
      fi
      # state/away present = on (AC20); content is the epoch for the audit trail.
      if ! atomic_write "$f" date +%s; then
        echo "intercom: cannot write $f" >&2
        exit 1
      fi
      # Pin the away endpoint (CDT-535): bare sid, atomic, last-writer-wins.
      ir_away_sid_write "$asid" || exit 1
      printf 'away: on\n'
      ;;
    off)
      # Only the flag goes; away_sid is kept until the next CLI `away on`.
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

ir_away_sid_refresh() {
  # ir_away_sid_refresh SID — while away is ON the speaking session owns the
  # walkie-talkie: refresh state/away_sid (CDT-535). Best-effort: a failed
  # write never fails the ask/send that triggered it. Away OFF → never create.
  local statedir
  statedir=$(ir_state_root)/state
  [ -f "$statedir/away" ] || return 0
  ir_away_sid_write "$1" >/dev/null 2>&1 || true
}

ir_cli_read() {
  # ir_cli_read [--sid S] [--ack] — print spool/<sid>/inbox/ records in
  # filename order (CDT-535): one `qid=<id> kind=<kind>` line per record
  # (qid is the record's qid field falling back to update_id) plus the text
  # body. --ack moves each printed record to spool/<sid>/consumed/ (tmp +
  # rename in the same dir tree, original filename preserved); records that
  # vanish mid-read are skipped. Without --ack the inbox is unchanged.
  local sid="" ack=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --sid)
        [ $# -ge 2 ] || { echo "intercom read: --sid needs a value" >&2; exit 2; }
        sid="$2"; shift 2
        ;;
      --sid=*)
        sid="${1#*=}"; shift
        ;;
      --ack)
        ack=1; shift
        ;;
      --)
        shift
        ;;
      -*)
        echo "intercom read: unknown option: $1" >&2
        ir_usage_exit
        ;;
      *)
        echo "intercom read: unexpected argument: $1" >&2
        ir_usage_exit
        ;;
    esac
  done
  ir_require_tools jq || exit 1
  if ! sid=$(ir_resolve_sid "$sid"); then
    ir_usage_exit
  fi
  local inbox consumed rec qid kind text name tmp
  inbox=$(ir_spool_dir "$sid" inbox) || exit 1
  consumed=""
  if [ "$ack" -eq 1 ]; then
    consumed=$(ir_spool_dir "$sid" consumed) || exit 1
  fi
  for rec in "$inbox"/*.json; do
    [ -f "$rec" ] || continue
    qid=$(jq -r '(.qid // .update_id // empty)' "$rec" 2>/dev/null) || qid=""
    kind=$(jq -r '(.kind // "message")' "$rec" 2>/dev/null) || kind="message"
    # A record without an id cannot be addressed; skip it defensively.
    [ -n "$qid" ] || continue
    printf 'qid=%s kind=%s\n' "$qid" "$kind"
    text=$(jq -r '(.text // empty)' "$rec" 2>/dev/null) || text=""
    # if/else (not `&&`) so a textless last record cannot turn the loop —
    # and the CLI — into exit 1.
    if [ -n "$text" ]; then
      printf '%s\n' "$text"
    fi
    if [ "$ack" -eq 1 ]; then
      name=${rec##*/}
      # Same-dir-tree publish: reserve a unique tmp inside consumed, rename the
      # record onto it, then publish under the original name (atomic; a vanished
      # record is skipped, a failed publish puts the record back).
      tmp=$(mktemp "$consumed/.read.XXXXXX") || { echo "intercom: cannot ack $rec" >&2; exit 1; }
      if ! mv -f "$rec" "$tmp"; then
        rm -f "$tmp"
        continue
      fi
      if ! mv -f "$tmp" "$consumed/$name"; then
        mv -f "$tmp" "$rec" 2>/dev/null || rm -f "$tmp"
        echo "intercom: cannot publish consumed record: $name" >&2
        exit 1
      fi
    fi
  done
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
    read) ir_cli_read "$@" ;;
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
