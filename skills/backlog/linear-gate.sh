#!/usr/bin/env bash
# linear-gate.sh — the ONE reader of the per-project `linear_sync` key
# (SPEC-009 § Linear sync is opt-in, CDT-646). Subprocess CLI: bash-only,
# never sourced, never opens a socket, never calls the Linear MCP.
#
# The key decides whether a Surface may issue a Linear MCP call at all:
#   off (default) — the local backlog store is the source of truth. Every
#                   reading Surface takes the local path and MUST NOT call
#                   Linear.
#   on            — local write first, Linear sync second.
#
# Usage:
#   linear-gate.sh status  [--root ROOT]                 prints on|off; exit 0
#   linear-gate.sh enabled [--root ROOT]                 exit 0 = on · 1 = off
#   linear-gate.sh set     --root ROOT on|off            writes the key
#   linear-gate.sh sync    [--root ROOT] -- CMD ARGS…    runs CMD only when on
#
# Value resolution, first hit wins:
#   1. $LINEAR_SYNC (on|off|true|false|1|0) — per-invocation override
#   2. .linear_sync in <root>/.claude/dev-team/config.json (git-ignored)
#   3. off
# A value that is not a recognized on-token resolves to off, so junk, a missing
# file, invalid JSON, and a box with no jq all take the offline path.
#
# Root rule (SPEC-009 § Backlog root rule): --root if set, else $MROOT — the
# parent of `git rev-parse --git-common-dir` — else pwd. One config per project,
# shared by every linked worktree.
#
# `sync` is the ordering seam: a caller writes local state first, then invokes
# `sync -- CMD`, where CMD is that caller's Linear bridge (the session's MCP
# call, or a test stub). off prints one skip line and never runs CMD; on runs
# CMD and passes its exit code through. With no CMD, on prints that the session
# owns the MCP call, so the gate is never a silent no-op on the sync path.
#
# Exit: 0 ok · 1 set failed (unwritable root, no jq, invalid JSON to merge) ·
# 64 usage.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PORTABLE="$SCRIPT_DIR/../lib/portable.sh"
[ -f "$PORTABLE" ] || { printf 'error: missing helper: %s\n' "$PORTABLE" >&2; exit 1; }
# shellcheck source=../lib/portable.sh
. "$PORTABLE"

CFG_REL=".claude/dev-team/config.json"
KEY="linear_sync"

usage() {
  printf 'usage: %s status|enabled [--root PATH]\n       %s set --root PATH on|off\n       %s sync [--root PATH] -- CMD ARGS…\n' \
    "${0##*/}" "${0##*/}" "${0##*/}" >&2
  exit 64
}

die() {
  local rc="$1"
  shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
}

CMD=""
ROOT=""
ROOT_GIVEN=false
VALUE=""
SYNC_CMD=()

[ $# -ge 1 ] || usage
case "$1" in
  status | enabled | set | sync) CMD="$1"; shift ;;
  *) usage ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || usage
      ROOT="$2"
      ROOT_GIVEN=true
      shift 2
      ;;
    --)
      shift
      [ "$CMD" = "sync" ] || usage
      SYNC_CMD=("$@")
      set --
      break
      ;;
    on | off)
      [ "$CMD" = "set" ] || usage
      [ -z "$VALUE" ] || usage
      VALUE="$1"
      shift
      ;;
    *)
      [ "$CMD" = "sync" ] || usage
      SYNC_CMD=("$@")
      set --
      break
      ;;
  esac
done

if [ "$CMD" = "set" ]; then
  [ "$ROOT_GIVEN" = true ] || die 64 "set needs --root"
  [ -n "$VALUE" ] || die 64 "set needs on or off"
fi
if [ "$CMD" = "sync" ] && [ "${#SYNC_CMD[@]}" -gt 0 ] && [ ! -x "${SYNC_CMD[0]}" ] \
  && ! command -v "${SYNC_CMD[0]}" >/dev/null 2>&1; then
  die 64 "sync command not executable: ${SYNC_CMD[0]}"
fi

if [ "$ROOT_GIVEN" != true ]; then
  _gc=$(git rev-parse --git-common-dir 2>/dev/null || true)
  if [ -n "$_gc" ]; then
    ROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    ROOT=$(pwd)
  fi
fi
[ -n "$ROOT" ] || die 64 "empty root"

cfg="$ROOT/$CFG_REL"

# norm_on_token <raw> → 0 = on, 1 = off, 2 = not a recognized token.
norm_on_token() {
  case "$1" in
    on | ON | On | true | TRUE | True | 1) return 0 ;;
    off | OFF | false | FALSE | False | 0) return 1 ;;
    *) return 2 ;;
  esac
}

# gate_value → prints "on" or "off". Fail-closed: anything unproven is off.
gate_value() {
  raw=""
  if [ -n "${LINEAR_SYNC:-}" ]; then
    if norm_on_token "$LINEAR_SYNC"; then
      printf 'on\n'
    else
      printf 'off\n'
    fi
    return 0
  fi
  if [ ! -f "$cfg" ]; then
    printf 'off\n'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'linear-gate: no jq — linear_sync reads as off\n' >&2
    printf 'off\n'
    return 0
  fi
  if ! raw=$(jq -r --arg k "$KEY" \
    '.[$k] // empty | if type == "string" then . else tostring end' "$cfg" 2>/dev/null); then
    printf 'linear-gate: %s is not valid JSON — linear_sync reads as off\n' "$cfg" >&2
    printf 'off\n'
    return 0
  fi
  if [ -z "$raw" ]; then
    printf 'off\n'
    return 0
  fi
  if norm_on_token "$raw"; then
    printf 'on\n'
  else
    printf 'off\n'
  fi
}

case "$CMD" in
  status)
    gate_value
    exit 0
    ;;

  enabled)
    if [ "$(gate_value)" = "on" ]; then
      exit 0
    fi
    exit 1
    ;;

  set)
    [ -d "$ROOT/.claude" ] || die 1 "no .claude directory under $ROOT — run /backlog init"
    mkdir -p "$ROOT/.claude/dev-team" || die 1 "cannot create $ROOT/.claude/dev-team"
    [ -w "$ROOT/.claude/dev-team" ] || die 1 "not writable: $ROOT/.claude/dev-team"
    command -v jq >/dev/null 2>&1 || die 1 "set needs jq"
    if [ -f "$cfg" ]; then
      jq -e . "$cfg" >/dev/null 2>&1 || die 1 "refusing to write $cfg: not valid JSON"
      if [ "$VALUE" = "on" ]; then
        atomic_write "$cfg" jq --arg k "$KEY" '.[$k] = true' "$cfg" \
          || die 1 "write failed: $cfg"
      else
        atomic_write "$cfg" jq --arg k "$KEY" '.[$k] = false' "$cfg" \
          || die 1 "write failed: $cfg"
      fi
    elif [ "$VALUE" = "on" ]; then
      atomic_write "$cfg" jq -n '{schema: 1, linear_sync: true}' || die 1 "write failed: $cfg"
    else
      atomic_write "$cfg" jq -n '{schema: 1, linear_sync: false}' || die 1 "write failed: $cfg"
    fi
    printf 'linear_sync=%s: %s\n' "$VALUE" "$cfg"
    exit 0
    ;;

  sync)
    v=$(gate_value)
    if [ "$v" = "off" ]; then
      printf 'linear-skip: linear_sync=off — local path only, no Linear call\n'
      exit 0
    fi
    if [ "${#SYNC_CMD[@]}" -eq 0 ]; then
      printf 'linear-sync: linear_sync=on — session owns the Linear MCP call (local write already committed)\n'
      exit 0
    fi
    printf 'linear-sync: %s\n' "${SYNC_CMD[*]}"
    rc=0
    "${SYNC_CMD[@]}" || rc=$?
    exit "$rc"
    ;;
esac
