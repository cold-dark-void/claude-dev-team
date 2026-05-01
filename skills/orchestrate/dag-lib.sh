#!/usr/bin/env bash
#
# orchestrate/dag-lib.sh — DAG queries over the .claude/tasks/ JSON store
#
# Pure subprocess CLI. NEVER source this file.
#
# Implements the DAG primitives required by SPEC-017 (autonomous CI watch +
# task DAG): cycle detection on a node list, ready-set computation against
# the on-disk task store, and per-task status lookup.
#
# Usage:
#   dag-lib.sh check-cycle <json-file | -|/dev/stdin>
#   dag-lib.sh ready-set
#   dag-lib.sh status-of <task_id>
#
# check-cycle input: JSON array of {"task_id":"...","depends_on":[...]} objects.
#   Exit 0  if acyclic.
#   Exit 1  if a cycle exists; prints "cycle: A -> B -> ... -> A" on stderr.
#   Unknown task IDs in depends_on (not present as nodes) are treated as
#   roots with no outgoing edges (no error).
#
# ready-set:
#   Reads $MROOT/.claude/tasks/*.json atomically (single jq pass) and prints
#   one task_id per line for each task with status=="pending" whose every
#   declared dependency exists on disk with status=="completed".
#   Missing dep file → dep treated as pending → task stays WAITING.
#
# status-of:
#   Prints the status field of $MROOT/.claude/tasks/<task_id>.json, or
#   "pending" if the file is missing.
#
# No flock needed: every subcommand is read-only.

set -euo pipefail

usage() {
  echo "Usage:" >&2
  echo "  dag-lib.sh check-cycle <json-file | - | /dev/stdin>" >&2
  echo "  dag-lib.sh ready-set" >&2
  echo "  dag-lib.sh status-of <task_id>" >&2
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

TASKS_DIR="$MROOT/.claude/tasks"

# ---- Subcommands ------------------------------------------------------------

# check-cycle: 3-color DFS (WHITE=0, GRAY=1, BLACK=2).
# Graph construction is done in jq → tab-separated edge list (parent\tchild),
# then DFS in bash with associative arrays.
cmd_check_cycle() {
  [ $# -eq 1 ] || { echo "error: check-cycle requires 1 argument" >&2; usage; }
  local src="$1"
  if [ "$src" = "-" ]; then
    src=/dev/stdin
  fi
  if [ "$src" != "/dev/stdin" ] && [ ! -f "$src" ]; then
    echo "error: file not found: $src" >&2
    exit 2
  fi

  # Slurp input once.
  local raw
  raw=$(cat -- "$src")

  # Build node set and adjacency list. Unknown deps are silently dropped from
  # adjacency (they implicitly become roots with no outgoing edges later).
  local nodes
  nodes=$(jq -r '.[].task_id' <<<"$raw")
  if [ -z "$nodes" ]; then
    exit 0  # empty graph is trivially acyclic
  fi

  # Edges: "parent<TAB>child" lines, only where child is a known node.
  local edges
  edges=$(jq -r '
    [ .[] | .task_id ] as $known
    | .[]
    | . as $n
    | (.depends_on // [])[]
    | select(. as $d | $known | index($d))
    | "\(.)\t\($n.task_id)"
  ' <<<"$raw")

  # Build adjacency: ADJ[parent] = "child1 child2 ..." (space separated).
  declare -A ADJ
  declare -A COLOR  # 0=white (default/unset), 1=gray, 2=black
  local n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    COLOR["$n"]=0
    ADJ["$n"]=""
  done <<<"$nodes"

  if [ -n "$edges" ]; then
    local p c
    while IFS=$'\t' read -r p c; do
      [ -z "$p" ] && continue
      # Only add edge if parent is a known node. Unknown parents are roots
      # with no outgoing edges per spec.
      if [ "${COLOR[$p]+set}" = "set" ]; then
        ADJ["$p"]="${ADJ[$p]}${ADJ[$p]:+ }$c"
      fi
    done <<<"$edges"
  fi

  # Iterative DFS (avoids bash recursion depth issues on large graphs).
  # Stack entries: "ENTER:node" or "LEAVE:node".
  local cycle_node=""
  local cycle_from=""
  local start
  while IFS= read -r start; do
    [ -n "$cycle_node" ] && break   # already found one, stop
    [ -z "$start" ] && continue
    [ "${COLOR[$start]}" != "0" ] && continue

    local stack=("ENTER:$start")
    while [ ${#stack[@]} -gt 0 ]; do
      local top="${stack[-1]}"
      unset 'stack[-1]'
      local action="${top%%:*}"
      local node="${top#*:}"

      if [ "$action" = "LEAVE" ]; then
        COLOR["$node"]=2
        continue
      fi

      # ENTER
      if [ "${COLOR[$node]}" = "1" ]; then
        # already gray on stack — skip (shouldn't happen with this scheme)
        continue
      fi
      if [ "${COLOR[$node]}" = "2" ]; then
        continue
      fi
      COLOR["$node"]=1
      stack+=("LEAVE:$node")

      # Push children
      local children="${ADJ[$node]:-}"
      if [ -n "$children" ]; then
        local child
        local -a child_arr
        read -ra child_arr <<< "$children"
        for child in "${child_arr[@]}"; do
          local ccolor="${COLOR[$child]:-0}"
          if [ "$ccolor" = "1" ]; then
            # back edge → cycle from $node to $child
            cycle_node="$child"
            cycle_from="$node"
            break 2
          fi
          if [ "$ccolor" = "0" ]; then
            stack+=("ENTER:$child")
          fi
        done
      fi
    done
  done <<<"$nodes"

  if [ -n "$cycle_node" ]; then
    echo "cycle: $cycle_from -> $cycle_node" >&2
    exit 1
  fi

  exit 0
}

# ready-set: atomic snapshot of all task files; print pending tasks whose
# every declared dep is present and completed.
cmd_ready_set() {
  [ $# -eq 0 ] || { echo "error: ready-set takes no arguments" >&2; usage; }

  if [ ! -d "$TASKS_DIR" ]; then
    return 0  # no tasks yet → empty ready set
  fi

  shopt -s nullglob
  local files=("$TASKS_DIR"/*.json)
  shopt -u nullglob
  if [ ${#files[@]} -eq 0 ]; then
    return 0
  fi

  # Single jq invocation reads every file; jq opens them sequentially before
  # producing output, which is as close to an atomic snapshot as we get
  # without flock. The store is append-mostly anyway (one write per status
  # transition). Use --slurp so .[] iterates the array of all docs.
  jq -r --slurp '
    # First pass: build set of completed task_ids.
    (map(select(.status == "completed") | .task_id)) as $done
    # Second pass: emit pending tasks whose every dep is in $done.
    | .[]
    | select(.status == "pending")
    | select(((.depends_on // []) - $done) | length == 0)
    | .task_id
  ' "${files[@]}"
}

cmd_status_of() {
  [ $# -eq 1 ] || { echo "error: status-of requires 1 argument" >&2; usage; }
  local task_id="$1"
  local f="$TASKS_DIR/${task_id}.json"
  if [ ! -f "$f" ]; then
    echo "pending"
    return 0
  fi
  jq -r '.status // "pending"' "$f"
}

# ---- Dispatch ---------------------------------------------------------------
case "$SUBCMD" in
  check-cycle) cmd_check_cycle "$@" ;;
  ready-set)   cmd_ready_set "$@" ;;
  status-of)   cmd_status_of "$@" ;;
  *) echo "error: unknown subcommand: $SUBCMD" >&2; usage ;;
esac
