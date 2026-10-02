#!/usr/bin/env bash
#
# ci-watch/sidecar.sh — Manage per-ticket CI-watch sidecar JSON files
#
# Implements the sidecar store required by SPEC-017 (autonomous CI watch / task DAG).
# Each ticket gets one JSON file: $MROOT/.claude/ci-watch/<TICKET>.json
#
# Usage:
#   sidecar.sh init   <TICKET> <mode> <pr_number> <branch>
#   sidecar.sh set    <TICKET> <key> <value>
#   sidecar.sh get    <TICKET> <key>
#   sidecar.sh inc    <TICKET> <key>
#   sidecar.sh delete <TICKET>
#   sidecar.sh path   <TICKET>
#
# Schema:
#   { ticket_id, mode, pr_number, branch, retry_count, poll_error_count,
#     fixer_active, fixer_started_at, empty_poll_count, cron_job_id }
#   set keeps digit strings as strings. true|false|null stay JSON.
#   inc owns numeric counters. --string forces a JSON string.
#
# Atomic writes use tmp+flock+rename pattern (same as orchestrate/task-store.sh).
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -euo pipefail
_SC_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../lib/portable.sh
. "$_SC_HERE/../lib/portable.sh"

# ---- Usage ------------------------------------------------------------------
usage() {
  echo "Usage:" >&2
  echo "  sidecar.sh init   <TICKET> <mode> <pr_number> <branch>" >&2
  echo "  sidecar.sh set    [--string] <TICKET> <key> <value>" >&2
  echo "  sidecar.sh get    <TICKET> <key>" >&2
  echo "  sidecar.sh inc    <TICKET> <key>" >&2
  echo "  sidecar.sh delete <TICKET>" >&2
  echo "  sidecar.sh path   <TICKET>" >&2
  exit 1
}

validate_ticket_id() {
  if ! [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf 'error: ticket_id must match [A-Za-z0-9_-]+ (no dots — a dotted ID cannot get a worktree), got: %q\n' "$1" >&2
    exit 2
  fi
}

[ $# -lt 1 ] && usage
SUBCMD="$1"; shift

# ---- Dependency check -------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not found in PATH" >&2
  exit 1
fi

# ---- Resolve MROOT (worktree-aware) -----------------------------------------
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)

# ---- Paths ------------------------------------------------------------------
WATCH_DIR="$MROOT/.claude/ci-watch"
LOCK="$WATCH_DIR/.lock"

# ---- Helpers ----------------------------------------------------------------
sidecar_file() {
  echo "$WATCH_DIR/${1}.json"
}

# ---- Subcommands ------------------------------------------------------------
cmd_init() {
  [ $# -eq 4 ] || { echo "error: init requires 4 arguments" >&2; usage; }
  validate_ticket_id "$1"
  local ticket="$1" mode="$2" pr_number="$3" branch="$4"

  mkdir -p "$WATCH_DIR"

  local dest
  dest=$(sidecar_file "$ticket")

  (
    flock -x 9

    # Re-arm guard: if file exists and cron_job_id is non-null, refuse
    if [ -f "$dest" ]; then
      if ! jq -e '.cron_job_id == null' "$dest" >/dev/null 2>&1; then
        echo "sidecar already armed for $ticket" >&2
        exit 2
      fi
    fi

    atomic_write "$dest" jq -n \
      --arg  ticket_id    "$ticket" \
      --arg  mode         "$mode" \
      --arg  pr_number    "$pr_number" \
      --arg  branch       "$branch" \
      '{
        ticket_id:       $ticket_id,
        mode:            $mode,
        pr_number:       $pr_number,
        branch:          $branch,
        retry_count:     0,
        poll_error_count: 0,
        fixer_active:    false,
        cron_job_id:     null
      }' || exit 1
  ) 9>"$LOCK"
}

cmd_set() {
  local force_string=0
  if [ "${1:-}" = "--string" ]; then
    force_string=1
    shift
  fi
  [ $# -eq 3 ] || { echo "error: set requires 3 arguments" >&2; usage; }
  validate_ticket_id "$1"
  local ticket="$1" key="$2" value="$3"

  local dest
  dest=$(sidecar_file "$ticket")

  if [ ! -f "$dest" ]; then
    echo "error: sidecar file not found for $ticket" >&2
    exit 1
  fi

  (
    flock -x 9

    # true|false|null stay JSON. Digit strings stay strings (pr_number "42").
    # --string forces a JSON string, including for true|false|null.
    # inc owns numeric counters.
    local jq_type
    if [ "$force_string" -eq 1 ]; then
      jq_type=arg
    else
      case "$value" in
        true|false|null) jq_type=argjson ;;
        *) jq_type=arg ;;
      esac
    fi
    atomic_write "$dest" jq --"$jq_type" v "$value" --arg k "$key" '.[$k] = $v' "$dest" || exit 1
  ) 9>"$LOCK"
}

cmd_get() {
  [ $# -eq 2 ] || { echo "error: get requires 2 arguments" >&2; usage; }
  validate_ticket_id "$1"
  local ticket="$1" key="$2"

  local dest
  dest=$(sidecar_file "$ticket")

  if [ ! -f "$dest" ]; then
    echo "error: sidecar file not found for $ticket" >&2
    exit 1
  fi

  jq -r --arg k "$key" '.[$k]' "$dest"
}

cmd_inc() {
  [ $# -eq 2 ] || { echo "error: inc requires 2 arguments" >&2; usage; }
  validate_ticket_id "$1"
  local ticket="$1" key="$2"

  local dest
  dest=$(sidecar_file "$ticket")

  if [ ! -f "$dest" ]; then
    echo "error: sidecar file not found for $ticket" >&2
    exit 1
  fi

  (
    flock -x 9
    new_val=$(jq --arg k "$key" '((.[$k] | tonumber?) // 0) + 1' "$dest")
    atomic_write "$dest" jq --argjson v "$new_val" --arg k "$key" '.[$k] = $v' "$dest" || exit 1
    echo "$new_val"
  ) 9>"$LOCK"
}

cmd_delete() {
  [ $# -eq 1 ] || { echo "error: delete requires 1 argument" >&2; usage; }
  validate_ticket_id "$1"
  local ticket="$1"

  rm -f \
    "$(sidecar_file "$ticket")" \
    "$WATCH_DIR/${ticket}.last_failure.txt" \
    "$WATCH_DIR/${ticket}.log"
}

cmd_path() {
  [ $# -eq 1 ] || { echo "error: path requires 1 argument" >&2; usage; }
  validate_ticket_id "$1"
  sidecar_file "$1"
}

# ---- Dispatch ---------------------------------------------------------------
case "$SUBCMD" in
  init)   cmd_init   "$@" ;;
  set)    cmd_set    "$@" ;;
  get)    cmd_get    "$@" ;;
  inc)    cmd_inc    "$@" ;;
  delete) cmd_delete "$@" ;;
  path)   cmd_path   "$@" ;;
  *) echo "error: unknown subcommand: $SUBCMD" >&2; usage ;;
esac
