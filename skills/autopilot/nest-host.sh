#!/usr/bin/env bash
#
# autopilot/nest-host.sh — CDT-512-C6 / SPEC-033 M14(l) Grok nest detector.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   nest-host.sh [--host grok|claude|unknown] [--ticket ID] [json]
#   nest-host.sh [--host …] [--ticket ID] can-spawn-council
#   nest-host.sh [--host …] [--ticket ID] classify-spawn-fail
#
# Default command is json. Stdout (json): one line
#   {"host":"grok|claude|unknown","nest_depth":N,"can_spawn_council":true|false}
#
# can-spawn-council: exit 0 if a /council spawn is allowed here, 1 if not, 64 usage.
# classify-spawn-fail: prints needs-parent-M14 when a council spawn-fail must
# defer to the parent walker; otherwise bc7-spawn-fail (depth-0 M14(d) path).
#
# Host: --host flag, else DEVTEAM_HOST, else GROK_AGENT=1 or GROK_SESSION_ID → grok,
# else claude.
# Nest depth: DEVTEAM_NEST_DEPTH (integer, including 0) wins; else 1 when
# EPIC_RELEASE_END or EPIC_INTEGRATION_PATH is set; else 1 when --ticket is an
# in_progress epic child; else 0.
# can_spawn_council is false iff host=grok AND nest_depth>=1.
#
# Exit: 0 ok; 1 can-spawn-council false; 64 usage / bad args.

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: nest-host.sh [--host grok|claude|unknown] [--ticket ID] [json|can-spawn-council|classify-spawn-fail]'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

HOST_FLAG=""
TICKET=""
CMD="json"

while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      [ $# -ge 2 ] || die "missing --host value"
      HOST_FLAG="$2"
      shift 2
      ;;
    --host=*)
      HOST_FLAG="${1#--host=}"
      shift
      ;;
    --ticket)
      [ $# -ge 2 ] || die "missing --ticket value"
      TICKET="$2"
      shift 2
      ;;
    --ticket=*)
      TICKET="${1#--ticket=}"
      shift
      ;;
    json|can-spawn-council|classify-spawn-fail)
      CMD="$1"
      shift
      ;;
    -h|--help)
      echo "$USAGE"
      exit 0
      ;;
    *)
      die "unknown argument '$1'"
      ;;
  esac
done

case "$HOST_FLAG" in
  ""|grok|claude|unknown) ;;
  *) die "invalid --host '$HOST_FLAG' (expected grok|claude|unknown)" ;;
esac

resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

detect_host() {
  if [ -n "$HOST_FLAG" ]; then
    HOST="$HOST_FLAG"
    return
  fi
  case "${DEVTEAM_HOST:-}" in
    grok|claude|unknown)
      HOST="$DEVTEAM_HOST"
      return
      ;;
    "")
      ;;
    *)
      die "invalid DEVTEAM_HOST '$DEVTEAM_HOST' (expected grok|claude|unknown)"
      ;;
  esac
  if [ "${GROK_AGENT:-}" = "1" ] || [ -n "${GROK_SESSION_ID:-}" ]; then
    HOST=grok
    return
  fi
  HOST=claude
}

ticket_in_progress() {
  local id="$1" f
  [ -n "$id" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -d "$MROOT/.claude/epics" ] || return 1
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if jq -e --arg id "$id" \
      '.children[]? | select(.id == $id and .status == "in_progress")' \
      "$f" >/dev/null 2>&1; then
      return 0
    fi
  done < <(find "$MROOT/.claude/epics" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null)
  return 1
}

detect_depth() {
  case "${DEVTEAM_NEST_DEPTH:-}" in
    "")
      ;;
    0|[1-9]*)
      case "${DEVTEAM_NEST_DEPTH}" in
        *[!0-9]*) ;;
        *)
          DEPTH="$DEVTEAM_NEST_DEPTH"
          return
          ;;
      esac
      ;;
  esac
  if [ -n "${EPIC_RELEASE_END:-}" ] || [ -n "${EPIC_INTEGRATION_PATH:-}" ]; then
    DEPTH=1
    return
  fi
  if [ -n "$TICKET" ] && ticket_in_progress "$TICKET"; then
    DEPTH=1
    return
  fi
  DEPTH=0
}

resolve_mroot
detect_host
detect_depth

CAN=true
if [ "$HOST" = grok ] && [ "$DEPTH" -ge 1 ]; then
  CAN=false
fi

case "$CMD" in
  json)
    printf '{"host":"%s","nest_depth":%s,"can_spawn_council":%s}\n' \
      "$HOST" "$DEPTH" "$CAN"
    exit 0
    ;;
  can-spawn-council)
    if [ "$CAN" = true ]; then
      exit 0
    fi
    exit 1
    ;;
  classify-spawn-fail)
    if [ "$CAN" = false ]; then
      printf '%s\n' 'needs-parent-M14'
    else
      printf '%s\n' 'bc7-spawn-fail'
    fi
    exit 0
    ;;
  *)
    die "unknown command '$CMD'"
    ;;
esac
