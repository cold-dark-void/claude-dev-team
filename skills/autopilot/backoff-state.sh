#!/usr/bin/env bash
#
# autopilot/backoff-state.sh — CDT-617 watchdog back-off state for an open
# hard blocker (SPEC-017 Watchdog back-off, consumes SPEC-033 M7 halt cards
# through the M13 ledger reader).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   backoff-state.sh check  <TICKET>
#   backoff-state.sh record <TICKET> <BC>
#   backoff-state.sh reset  <TICKET>
#
# A watchdog (skills/ci-watch/poll.sh, a cron body) asks before it re-fires:
#   check  -> one JSON object on stdout:
#             {"blocked":bool,"bc":"BCn"|null,"attempts":int,
#              "delay_s":int,"next_fire_ts":int}
#           exit 0 on every well-formed call, blocked included.
#   record -> ramps the back-off for blocking condition <BC> (<BC> is
#             BC1..BC8, or the bare ordinal 1..8) and prints the new state.
#   reset  -> clears the state (the run went green). Silent, exit 0.
#
# State file: $MROOT/.claude/autopilot/<TICKET>.backoff.json — git-ignored
# local state, same directory as the M13 ledger.
#
# "Open hard blocker" = the ledger's LAST card has decision "halt" AND a
# blocking condition in {BC1,BC2,BC3,BC4,BC6,BC7,BC8}. BC5 (reroute-epic) is a
# reroute, never a block, so it never backs off (SPEC-033 M6/M7). Card parsing
# is delegated to read-cards.sh — this script never re-implements the M13
# reader.
#
# Fail-open is the contract: a missing, empty, unreadable, or unparseable
# ledger, and a missing or corrupt state file, all read as "not blocked /
# attempts 0" with exit 0. A watchdog that cannot read the journal keeps its
# normal cadence; it never halts the watch and never invents a blocker.
#
# Delay ladder (AC3): first record = base, then double per identical blocking
# condition. A different <BC> restarts the ramp at the base.
#   AUTOPILOT_BACKOFF_BASE_S      base delay       (default 1800)
#   AUTOPILOT_BACKOFF_MAX_S       delay ceiling    (default 86400)
#   AUTOPILOT_BACKOFF_MAX_ATTEMPTS attempts after
#                                 which doubling stops (default 8)
# Each value MUST be a non-negative integer (at most 15 digits, no leading
# zero) before it is used; anything else falls back to the default with one
# stderr line. When the open halt card carries budget.wall_clock_cap_s, that
# cap bounds the delay too (min of it and the max).
#
# Exit codes:
#   0   success (check/record/reset, blocked or not)
#  64   usage error (wrong argc, bad subcommand, bad ticket id or BC charset,
#       BC5 record, jq absent, state write failure)

set -euo pipefail
# THIS SCRIPT IS a SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: backoff-state.sh check <TICKET> | backoff-state.sh record <TICKET> <BC> | backoff-state.sh reset <TICKET>'

BASE_DEFAULT_S=1800
MAX_DEFAULT_S=86400
MAX_ATTEMPTS_DEFAULT=8

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

# ---- Usage ------------------------------------------------------------------
if [ $# -lt 1 ]; then
  die "backoff-state.sh requires a subcommand"
fi
SUBCMD="$1"; shift

case "$SUBCMD" in
  check)  [ $# -eq 1 ] || die "check requires exactly 1 argument (got $#)" ;;
  record) [ $# -eq 2 ] || die "record requires exactly 2 arguments (got $#)" ;;
  reset)  [ $# -eq 1 ] || die "reset requires exactly 1 argument (got $#)" ;;
  *)      die "unknown subcommand: $SUBCMD" ;;
esac

TICKET_ID="$1"

if ! command -v jq >/dev/null 2>&1; then
  die "jq is required"
fi

# ---- ticket_id validation (path-traversal guard, read-cards.sh rule) --------
[ -n "$TICKET_ID" ] || die "ticket_id must not be empty"
case "$TICKET_ID" in
  *[!A-Za-z0-9_-]*) die "ticket_id must match ^[A-Za-z0-9_-]+\$" ;;
esac

# ---- normalize BC ------------------------------------------------------------
BC=""
if [ "$SUBCMD" = "record" ]; then
  case "$2" in
    1|2|3|4|5|6|7|8) BC="BC$2" ;;
    BC1|BC2|BC3|BC4|BC5|BC6|BC7|BC8) BC="$2" ;;
    *) die "BC must be BC1..BC8 (or the ordinal 1..8), got: $2" ;;
  esac
  # BC5 is the complexity-overflow reroute (SPEC-033 M6/M7): it is not a hard
  # blocker, so there is nothing to back off from.
  if [ "$BC" = "BC5" ]; then
    die "BC5 is a reroute, not a hard blocker — it never backs off"
  fi
fi

# ---- resolve_mroot ----------------------------------------------------------
resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

resolve_mroot

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

READ_CARDS="$SCRIPT_DIR/read-cards.sh"
STATE_DIR="$MROOT/.claude/autopilot"
STATE_FILE="$STATE_DIR/$TICKET_ID.backoff.json"

# ---- env integer guard (SPEC-033 AC9 pattern) --------------------------------
# env_int <name> <value> <default> — prints the value when it is a
# non-negative integer (at most 15 digits, no leading zero), else the default
# with one stderr line. A watchdog keeps a sane cadence on garbage input.
env_int() {
  local name="$1" value="$2" default="$3"
  if [ -z "$value" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  case "$value" in
    *[!0-9]*|0[0-9]*)
      echo "warning: $name='$value' is not a non-negative integer; using $default" >&2
      printf '%s\n' "$default"
      return 0
      ;;
  esac
  if [ "${#value}" -gt 15 ]; then
    echo "warning: $name='$value' is too large; using $default" >&2
    printf '%s\n' "$default"
    return 0
  fi
  printf '%s\n' "$value"
}

# ---- the open-blocker probe (ledger -> OPEN_BC, OPEN_CAP_S) ------------------
OPEN_BC=""
OPEN_CAP_S=""

probe_ledger() {
  OPEN_BC=""
  OPEN_CAP_S=""

  local cards last decision raw cap
  cards=$(bash "$READ_CARDS" "$TICKET_ID" 2>/dev/null) || return 0
  last=$(printf '%s' "$cards" | jq -c '
    if type == "array" and length > 0
    then (last | if type == "object" then . else null end)
    else null end' 2>/dev/null) || return 0
  if [ "$last" = "null" ] || [ -z "$last" ]; then
    return 0
  fi

  decision=$(printf '%s' "$last" | jq -r 'if (.decision | type) == "string" then .decision else "" end' 2>/dev/null) || decision=""
  if [ "$decision" != "halt" ]; then
    return 0
  fi

  raw=$(printf '%s' "$last" | jq -r '
    .blocking_condition
    | if type == "number" then tostring
      elif type == "string" then .
      else "" end' 2>/dev/null) || raw=""
  case "$raw" in
    1|2|3|4|6|7|8) OPEN_BC="BC$raw" ;;
    BC1|BC2|BC3|BC4|BC6|BC7|BC8) OPEN_BC="$raw" ;;
    *) return 0 ;;
  esac

  cap=$(printf '%s' "$last" | jq -r '
    if (.budget | type) == "object"
    then (.budget.wall_clock_cap_s | if type == "number" then tostring else "" end)
    else "" end' 2>/dev/null) || cap=""
  case "$cap" in
    ''|*[!0-9]*) cap="" ;;
  esac
  OPEN_CAP_S="$cap"
  return 0
}

# ---- the state reader (state file -> ST_BC, ST_ATTEMPTS, ST_DELAY, ST_NEXT) --
read_state() {
  ST_BC=""
  ST_ATTEMPTS=0
  ST_DELAY=0
  ST_NEXT=0

  local state
  [ -f "$STATE_FILE" ] || return 0
  state=$(jq -c '
    if type == "object" then
      { bc: (.bc | if type == "string" then . else "" end),
        attempts: ((.attempts | tonumber?) // 0),
        delay_s: ((.delay_s | tonumber?) // 0),
        next_fire_ts: ((.next_fire_ts | tonumber?) // 0) }
    else null end' "$STATE_FILE" 2>/dev/null) || return 0
  if [ -z "$state" ] || [ "$state" = "null" ]; then
    return 0
  fi
  ST_BC=$(printf '%s' "$state" | jq -r '.bc' 2>/dev/null) || ST_BC=""
  ST_ATTEMPTS=$(printf '%s' "$state" | jq -r '.attempts' 2>/dev/null) || ST_ATTEMPTS=0
  ST_DELAY=$(printf '%s' "$state" | jq -r '.delay_s' 2>/dev/null) || ST_DELAY=0
  ST_NEXT=$(printf '%s' "$state" | jq -r '.next_fire_ts' 2>/dev/null) || ST_NEXT=0
  case "$ST_ATTEMPTS" in ''|*[!0-9]*) ST_ATTEMPTS=0 ;; esac
  case "$ST_DELAY" in ''|*[!0-9]*) ST_DELAY=0 ;; esac
  case "$ST_NEXT" in ''|*[!0-9]*) ST_NEXT=0 ;; esac
  return 0
}

# ---- Subcommands -------------------------------------------------------------
case "$SUBCMD" in
  reset)
    rm -f "$STATE_FILE"
    exit 0
    ;;

  check)
    probe_ledger
    read_state
    if [ -z "$OPEN_BC" ]; then
      printf '%s\n' '{"blocked":false,"bc":null,"attempts":0,"delay_s":0,"next_fire_ts":0}'
      exit 0
    fi
    jq -cn \
      --argjson blocked true \
      --arg bc "$OPEN_BC" \
      --argjson attempts "$ST_ATTEMPTS" \
      --argjson delay_s "$ST_DELAY" \
      --argjson next_fire_ts "$ST_NEXT" \
      '{blocked: $blocked, bc: $bc, attempts: $attempts,
        delay_s: $delay_s, next_fire_ts: $next_fire_ts}'
    exit 0
    ;;

  record)
    probe_ledger
    # A record call is only meaningful inside an open-halt episode (the TL
    # review: a stale .backoff.json must not seed the next halt of the same
    # BC). If the ledger no longer shows an open blocker, the episode is
    # over — clear any stale state and report not-blocked.
    if [ -z "$OPEN_BC" ]; then
      rm -f "$STATE_FILE"
      printf '%s\n' '{"blocked":false,"bc":null,"attempts":0,"delay_s":0,"next_fire_ts":0}'
      exit 0
    fi
    read_state

    base_s=$(env_int AUTOPILOT_BACKOFF_BASE_S "${AUTOPILOT_BACKOFF_BASE_S:-}" "$BASE_DEFAULT_S")
    max_s=$(env_int AUTOPILOT_BACKOFF_MAX_S "${AUTOPILOT_BACKOFF_MAX_S:-}" "$MAX_DEFAULT_S")
    max_attempts=$(env_int AUTOPILOT_BACKOFF_MAX_ATTEMPTS "${AUTOPILOT_BACKOFF_MAX_ATTEMPTS:-}" "$MAX_ATTEMPTS_DEFAULT")

    # The open halt card's run-budget cap bounds the delay as well, so a
    # back-off can never outlast the run budget that produced the halt.
    if [ -n "$OPEN_CAP_S" ] && [ "$OPEN_CAP_S" != "0" ] && [ "$OPEN_CAP_S" -lt "$max_s" ]; then
      max_s="$OPEN_CAP_S"
    fi

    # Identical blocking condition: double the delay, stopping at the
    # attempts cap. Any other condition (first sight, or a new BC) restarts
    # the ramp at the base.
    if [ "$ST_BC" = "$BC" ] && [ "$ST_DELAY" -gt 0 ]; then
      attempts=$(( ST_ATTEMPTS + 1 ))
      if [ "$ST_ATTEMPTS" -ge "$max_attempts" ]; then
        delay="$ST_DELAY"
      else
        delay=$(( ST_DELAY * 2 ))
        if [ "$delay" -gt "$max_s" ]; then
          delay="$max_s"
        fi
      fi
    else
      attempts=1
      delay="$base_s"
    fi
    if [ "$delay" -gt "$max_s" ]; then
      delay="$max_s"
    fi

    now=$(date +%s)
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    next_fire_ts=$(( now + delay ))
    ts_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$now")

    mkdir -p "$STATE_DIR" 2>/dev/null \
      || die "cannot create $STATE_DIR"
    atomic_write "$STATE_FILE" jq -cn \
      --arg ticket_id "$TICKET_ID" \
      --arg bc "$BC" \
      --argjson attempts "$attempts" \
      --argjson delay_s "$delay" \
      --argjson next_fire_ts "$next_fire_ts" \
      --arg updated_at "$ts_iso" \
      '{ticket_id: $ticket_id, bc: $bc, attempts: $attempts,
        delay_s: $delay_s, next_fire_ts: $next_fire_ts, updated_at: $updated_at}' \
      || die "failed to write $STATE_FILE"

    jq -cn \
      --argjson blocked true \
      --arg bc "$BC" \
      --argjson attempts "$attempts" \
      --argjson delay_s "$delay" \
      --argjson next_fire_ts "$next_fire_ts" \
      '{blocked: $blocked, bc: $bc, attempts: $attempts,
        delay_s: $delay_s, next_fire_ts: $next_fire_ts}'
    exit 0
    ;;
esac
