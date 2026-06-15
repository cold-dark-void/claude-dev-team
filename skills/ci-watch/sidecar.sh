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
#     fixer_active, cron_job_id }
#
# Atomic writes use tmp+flock+rename pattern (same as orchestrate/task-store.sh).
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -euo pipefail

# ---- Usage ------------------------------------------------------------------
usage() {
  echo "Usage:" >&2
  echo "  sidecar.sh init   <TICKET> <mode> <pr_number> <branch>" >&2
  echo "  sidecar.sh set    <TICKET> <key> <value>" >&2
  echo "  sidecar.sh get    <TICKET> <key>" >&2
  echo "  sidecar.sh inc    <TICKET> <key>" >&2
  echo "  sidecar.sh delete <TICKET>" >&2
  echo "  sidecar.sh path   <TICKET>" >&2
  exit 1
}

validate_ticket_id() {
  if ! printf '%s' "$1" | grep -qE '^[A-Za-z0-9_-]+$'; then
    echo "error: ticket_id must match [A-Za-z0-9_-]+ (no dots — a dotted ID cannot get a worktree), got: $1" >&2
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

sidecar_tmp() {
  echo "$WATCH_DIR/${1}.json.tmp"
}

# ---- Subcommands ------------------------------------------------------------
cmd_init() {
  [ $# -eq 4 ] || { echo "error: init requires 4 arguments" >&2; usage; }
  validate_ticket_id "$1"
  local ticket="$1" mode="$2" pr_number="$3" branch="$4"

  mkdir -p "$WATCH_DIR"

  local dest
  dest=$(sidecar_file "$ticket")
  local tmp
  tmp=$(sidecar_tmp "$ticket")

  (
    flock -x 9

    # Re-arm guard: if file exists and cron_job_id is non-null, refuse
    if [ -f "$dest" ]; then
      if ! jq -e '.cron_job_id == null' "$dest" >/dev/null 2>&1; then
        echo "sidecar already armed for $ticket" >&2
        exit 2
      fi
    fi

    jq -n \
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
      }' > "$tmp"
    mv "$tmp" "$dest"
  ) 9>"$LOCK"
}

cmd_set() {
  [ $# -eq 3 ] || { echo "error: set requires 3 arguments" >&2; usage; }
  validate_ticket_id "$1"
  local ticket="$1" key="$2" value="$3"

  local dest
  dest=$(sidecar_file "$ticket")
  local tmp
  tmp=$(sidecar_tmp "$ticket")

  if [ ! -f "$dest" ]; then
    echo "error: sidecar file not found for $ticket" >&2
    exit 1
  fi

  (
    flock -x 9

    # Type inference: boolean, null → --argjson; integer → --argjson; else --arg (string)
    local jq_type
    case "$value" in
      true|false|null) jq_type=argjson ;;
      *) if [[ "$value" =~ ^-?[0-9]+$ ]]; then jq_type=argjson; else jq_type=arg; fi ;;
    esac
    jq --"$jq_type" v "$value" --arg k "$key" '.[$k] = $v' "$dest" > "$tmp"
    mv "$tmp" "$dest"
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
  local tmp
  tmp=$(sidecar_tmp "$ticket")

  if [ ! -f "$dest" ]; then
    echo "error: sidecar file not found for $ticket" >&2
    exit 1
  fi

  (
    flock -x 9
    new_val=$(jq --arg k "$key" '(.[$k] // 0) + 1' "$dest")
    jq --argjson v "$new_val" --arg k "$key" '.[$k] = $v' "$dest" > "$tmp"
    mv "$tmp" "$dest"
    echo "$new_val"
  ) 9>"$LOCK"
}

cmd_delete() {
  [ $# -eq 1 ] || { echo "error: delete requires 1 argument" >&2; usage; }
  validate_ticket_id "$1"
  local ticket="$1"

  local dest
  dest=$(sidecar_file "$ticket")
  rm -f "$dest"
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
