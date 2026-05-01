#!/usr/bin/env bash
#
# orchestrate/task-store.sh — Write and update per-task metadata JSON files
#
# Implements the .claude/tasks/<task_id>.json store required by SPEC-009
# (Orchestrate MUSTs) and read by .claude/hooks/task-completed.sh (SPEC-002)
# for the optional council quality-gate.
#
# Usage:
#   task-store.sh create <task_id> <subject> <requires_council>
#   task-store.sh update-status <task_id> <new_status>
#
# <requires_council>: literal "true" or "false"
# <new_status>:       pending | in_progress | completed | blocked
#
# Exits 0 on success, non-zero on failure (message on stderr).
# Atomic tmp+rename, global flock on .claude/tasks/.lock (simpler than
# per-task locks; write contention on this store is negligible since each
# task_id is written at most twice: create then one status update per
# transition).

set -euo pipefail

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

  if ! printf '%s' "$task_id" | grep -qE '^[a-zA-Z0-9._-]+$'; then
    echo "error: task_id must match [a-zA-Z0-9._-]+, got: $task_id" >&2
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

  echo "created: $dest"
}

cmd_update_status() {
  [ $# -eq 2 ] || { echo "error: update-status requires 2 arguments" >&2; usage; }
  local task_id="$1" new_status="$2"

  if ! printf '%s' "$task_id" | grep -qE '^[a-zA-Z0-9._-]+$'; then
    echo "error: task_id must match [a-zA-Z0-9._-]+, got: $task_id" >&2
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
  local tmp="$TASKS_DIR/${task_id}.json.tmp"

  (
    flock -x 9

    if [ ! -f "$dest" ]; then
      # Auto-create a stub if task file is missing (e.g. after session pause/resume)
      local ts
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      jq -n \
        --arg tid "$task_id" \
        --arg s   "$new_status" \
        --arg ts  "$ts" \
        '{task_id: $tid, subject: "(auto-created stub)", requires_council: false, depends_on: [], created_at: $ts, status: $s}' \
        > "$tmp"
      mv "$tmp" "$dest"
      echo "warning: task file not found, created stub: $dest" >&2
    else
      jq --arg s "$new_status" '.status = $s' "$dest" > "$tmp"
      mv "$tmp" "$dest"
    fi
  ) 9>"$LOCK"

  echo "updated: $dest (status=$new_status)"
}

# ---- Dispatch ---------------------------------------------------------------
case "$SUBCMD" in
  create)        cmd_create "$@" ;;
  update-status) cmd_update_status "$@" ;;
  *) echo "error: unknown subcommand: $SUBCMD" >&2; usage ;;
esac
