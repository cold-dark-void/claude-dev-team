#!/usr/bin/env bash
#
# orchestrate/task-store.sh — Write and update per-task metadata JSON files
#
# Implements the .claude/tasks/<task_id>.json store required by SPEC-009
# (Orchestrate MUSTs) and read by .claude/hooks/task-completed.sh (SPEC-002)
# for the optional council quality-gate.
#
# Usage:
#   task-store.sh create <task_id> <subject> <requires_council> [depends_on]
#   task-store.sh update-status <task_id> <new_status>
#
# <requires_council>: literal "true" or "false"
# <new_status>:       pending | in_progress | completed | blocked
#
# Invent / update-status policy (CDT-167 / SPEC-017):
#   create          — invents (or upserts) <task_id>.json with caller-supplied
#                     requires_council. Orchestrators MUST use compound keys
#                     (e.g. CDT-111-C1-7), never bare numeric IDs alone.
#   update-status   — when exact dest exists: status-only jq (preserve all other
#                     fields including requires_council).
#                   — when exact dest missing:
#                       1 match of *-<task_id>.json → update that compound file
#                       >1 matches               → fail closed (exit 1; list)
#                       0 matches                → invent bare stub rc:false
#   MUST NOT invent a bare <task_id>.json with requires_council:false while any
#   *-<task_id>.json compound match exists (would shadow the council gate).
#
# Exits 0 on success, non-zero on failure (message on stderr).
# Atomic tmp+rename, global flock on .claude/tasks/.lock (simpler than
# per-task locks; write contention on this store is negligible since each
# task_id is written at most twice: create then one status update per
# transition).

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

# ---- Usage ------------------------------------------------------------------
usage() {
  echo "Usage:" >&2
  echo "  task-store.sh create <task_id> <subject> <requires_council> [depends_on]" >&2
  echo "  task-store.sh update-status <task_id> <new_status>" >&2
  echo "" >&2
  echo "  [depends_on]: colon-separated task IDs, e.g. T-1:T-2 (optional)" >&2
  exit 1
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
TASKS_DIR="$MROOT/.claude/tasks"
LOCK="$TASKS_DIR/.lock"

mkdir -p "$TASKS_DIR"

# ---- Subcommands ------------------------------------------------------------
cmd_create() {
  { [ $# -ge 3 ] && [ $# -le 4 ]; } || { echo "error: create requires 3 or 4 arguments" >&2; usage; }
  local task_id="$1" subject="$2" requires_council="$3"
  local deps
  deps=$(printf '%s' "${4:-}" | jq -Rs 'split(":") | map(select(length > 0))')

  if ! [[ "$task_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf 'error: task_id must match [A-Za-z0-9_-]+ (no dots — a dotted ID cannot get a worktree), got: %q\n' "$task_id" >&2
    exit 2
  fi

  if [ "$requires_council" != "true" ] && [ "$requires_council" != "false" ]; then
    echo "error: requires_council must be 'true' or 'false', got: $requires_council" >&2
    exit 1
  fi

  local dest="$TASKS_DIR/${task_id}.json"
  local tmp="$TASKS_DIR/${task_id}.json.tmp"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  (
    flock -x 9

    if [ -f "$dest" ]; then
      # Upsert: update subject and requires_council, preserve created_at and status
      if [ $# -eq 4 ]; then
        jq \
          --arg subj "$subject" \
          --argjson rc "$requires_council" \
          --argjson deps "$deps" \
          '.subject = $subj | .requires_council = $rc | .depends_on = $deps' \
          "$dest" > "$tmp"
      else
        jq \
          --arg subj "$subject" \
          --argjson rc "$requires_council" \
          '.subject = $subj | .requires_council = $rc | .depends_on = (.depends_on // [])' \
          "$dest" > "$tmp"
      fi
      mv "$tmp" "$dest"
      echo "upserted: $dest (already existed, updated)" >&2
    else
      jq -n \
        --arg tid  "$task_id" \
        --arg subj "$subject" \
        --argjson rc "$requires_council" \
        --arg ts   "$ts" \
        --argjson deps "$deps" \
        '{task_id: $tid, subject: $subj, requires_council: $rc, depends_on: $deps, created_at: $ts, status: "pending"}' \
        > "$tmp"
      mv "$tmp" "$dest"
    fi
  ) 9>"$LOCK"

  echo "created: $dest" >&2
}

cmd_update_status() {
  [ $# -eq 2 ] || { echo "error: update-status requires 2 arguments" >&2; usage; }
  local task_id="$1" new_status="$2"

  if ! [[ "$task_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf 'error: task_id must match [A-Za-z0-9_-]+ (no dots — a dotted ID cannot get a worktree), got: %q\n' "$task_id" >&2
    exit 2
  fi

  case "$new_status" in
    pending|in_progress|completed|blocked) ;;
    *)
      echo "error: new_status must be one of: pending in_progress completed blocked, got: $new_status" >&2
      exit 1
      ;;
  esac

  local dest="$TASKS_DIR/${task_id}.json"
  local invented=0

  (
    flock -x 9

    if [ ! -f "$dest" ]; then
      # CDT-167: shadow-safe invent — prefer unique compound *-<task_id>.json
      # over inventing bare dest with requires_council:false.
      local matches=()
      local f
      shopt -s nullglob
      matches=( "$TASKS_DIR"/*-"${task_id}".json )
      shopt -u nullglob

      local n=${#matches[@]}
      if [ "$n" -gt 1 ]; then
        echo "error: update-status: ambiguous bare id '$task_id' matches $n compound files:" >&2
        for f in "${matches[@]}"; do
          printf '  %s\n' "$f" >&2
        done
        echo "error: use the full compound task_id (or resolve the ambiguity)" >&2
        exit 1
      elif [ "$n" -eq 1 ]; then
        dest="${matches[0]}"
      else
        # No compound match — invent bare stub (resume path OK)
        local ts tmp
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        tmp="${dest}.tmp"
        jq -n \
          --arg tid "$task_id" \
          --arg s   "$new_status" \
          --arg ts  "$ts" \
          '{task_id: $tid, subject: "(auto-created stub)", requires_council: false, depends_on: [], created_at: $ts, status: $s}' \
          > "$tmp"
        mv "$tmp" "$dest"
        echo "warning: task file not found, created stub: $dest" >&2
        invented=1
      fi
    fi

    if [ "$invented" -eq 0 ]; then
      local tmp="${dest}.tmp"
      jq --arg s "$new_status" '.status = $s' "$dest" > "$tmp"
      mv "$tmp" "$dest"
    fi

    # Print using resolved dest (may be compound path after redirect)
    echo "updated: $dest (status=$new_status)" >&2
  ) 9>"$LOCK"
}

# ---- Dispatch ---------------------------------------------------------------
case "$SUBCMD" in
  create)        cmd_create "$@" ;;
  update-status) cmd_update_status "$@" ;;
  *) echo "error: unknown subcommand: $SUBCMD" >&2; usage ;;
esac
