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
#   dag-lib.sh check-cycle <json-file | - | /dev/stdin>
#   dag-lib.sh ready-set [--issue <ISSUE-ID>]
#   dag-lib.sh status-of <task_id>
#
# Exit codes (SPEC-017 § dag-lib.sh contract):
#   0   success.
#   1   check-cycle only: a cycle was found. stderr holds one line
#       "cycle: <from> -> <to>" where both ids are on the cycle.
#   2   input error: check-cycle file not found, or its input is not valid
#       JSON or not a JSON array; status-of: two or more *-<id>.json matches
#       (ambiguous), stderr names the files.
#   64  usage error: no subcommand, unknown subcommand, wrong argument count,
#       unknown flag, a bad --issue or task id value; also: jq missing from
#       PATH.
#
# Callers MUST treat exit 1 as "cycle" and every other non-zero exit as
# "the check could not run" — both MUST stop the caller.
#
# check-cycle input: JSON array of {"task_id":"...","depends_on":[...]} objects.
#   Empty array -> 0 (acyclic). Unknown task IDs in depends_on (not present
#   as nodes) are roots with no outgoing edges - no error. A self-loop is a
#   cycle. One jq program only: no bash graph walk, no associative arrays,
#   no per-node recursion - an iterative two-phase Kahn peel (in-degree, then
#   out-degree) followed by a bounded walk inside the remaining set.
#   "-" or "/dev/stdin" reads stdin.
#
# ready-set [--issue <ISSUE-ID>]:
#   Reads $MROOT/.claude/tasks/*.json and prints one ready task_id per line
#   to stdout - pending, every dep completed. The completed set spans every
#   readable task file, regardless of --issue. Fast path: one ordinary
#   (non-raw) jq pass parses every file at once (self-delimiting JSON, so a
#   missing trailing newline cannot merge two files). Falls back to a
#   per-file read only when that pass fails, or its doc count does not match
#   the file count (a truncated or unreadable file) - each per-file read
#   failure becomes its own warning instead of aborting the batch.
#   With --issue <ID>: scope is every task_id matching "<ID>-" + digits only
#   (so epic-child keys "<ID>-C1-2" and "<ID>-ci-fixer" are excluded).
#   --issue may be given at most once, and its value must match ID_RE (an
#   empty value or a repeat exits 64). Without --issue: scope is every task
#   (the /standup view).
#   A task file that is not valid JSON, or cannot be read, is skipped with
#   one stderr line "warning: skipping unreadable task file: <path>"; valid
#   JSON that is not an object with a string task_id, or whose depends_on is
#   neither null nor an array, is skipped silently. Any internal jq failure
#   exits 2. Otherwise exit stays 0.
#   An in-scope pending task with a dep whose status is "blocked" is
#   reported "blocked-dep: <task_id> <- <dep_id>" on stderr, never stdout.
#
# status-of <task_id>:
#   task_id failing ID_RE exits 64, no file read. The exact file
#   $MROOT/.claude/tasks/<task_id>.json wins when present. Else exactly one
#   $MROOT/.claude/tasks/*-<task_id>.json match is read (same resolution as
#   task-store.sh update-status); two or more matches exit 2 and name the
#   files on stderr; zero matches prints "pending". A matched file that is
#   not valid JSON exits 2.
#
# No flock needed: every subcommand is read-only.
#
# bash 3.2 only: no associative arrays, no negative array index, no bulk
# line-read builtin, no ${var,,}, no local -n.

set -euo pipefail

ID_RE='^[A-Za-z0-9_-]+$'

usage() {
  echo "Usage:" >&2
  echo "  dag-lib.sh check-cycle <json-file | - | /dev/stdin>" >&2
  echo "  dag-lib.sh ready-set [--issue <ISSUE-ID>]" >&2
  echo "  dag-lib.sh status-of <task_id>" >&2
  exit 64
}

[ $# -lt 1 ] && usage
SUBCMD="$1"; shift

# ---- Dependency check -------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not found in PATH" >&2
  exit 64
fi

# ---- Resolve MROOT (worktree-aware) -----------------------------------------
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)

TASKS_DIR="$MROOT/.claude/tasks"

# ---- check-cycle jq program --------------------------------------------------
# One jq program: build the node/edge set, peel sources (in-degree 0) to a
# fixpoint, then peel sinks (out-degree 0, within what peel-1 left) to a
# fixpoint. An acyclic graph fully peels to nothing. A non-empty remainder
# holds every node on some cycle, plus any node that only lies on a path
# between two cycles; the walk below is still correct, because every node
# left in the remainder still has out-degree >= 1 inside it, so following
# successors from any start (bounded by |remainder|+1 steps - pigeonhole
# guarantees a repeat) always closes on a real cycle edge.
read -r -d '' CC_JQ <<'CCJQEOF' || true
def has_dir(dir; edges):
  if dir == "in" then (edges | map(.[1])) else (edges | map(.[0])) end;

def peel(dir):
  until(
    ( . as $s
      | (has_dir(dir; $s.edges) | unique) as $has
      | ($s.nodes - $has) | length ) == 0;
    . as $s
    | (has_dir(dir; $s.edges) | unique) as $has
    | ($s.nodes - $has) as $remove
    | { nodes: ($s.nodes - $remove),
        edges: ($s.edges
                 | map(select( . as $e
                               | (($remove | index($e[0])) == null)
                                 and (($remove | index($e[1])) == null) ))) }
  );

def succ_in($cur; $edges; $R):
  ( $edges
    | map(select( . as $e | $e[0] == $cur and (($R | index($e[1])) != null) ))
    | .[0][1] );


. as $arr
| ($arr | [ .[].task_id ] | unique) as $allnodes
| ($arr
    | [ .[] | . as $n
        | ($n.depends_on // [])[]?
        | select(. as $d | ($allnodes | index($d)) != null)
        | [., $n.task_id] ]) as $alledges
| { nodes: $allnodes, edges: $alledges }
| peel("in")
| peel("out")
| . as $st
| ($st.nodes) as $R
| if ($R | length) == 0 then
    empty
  else
    ($R[0]) as $start
    | ( { visited: [$start], cur: $start, done: false, edge: null }
        | until(.done;
            . as $w
            | succ_in($w.cur; $st.edges; $R) as $nxt
            | if ($w.visited | index($nxt)) != null then
                $w + { done: true, edge: [$w.cur, $nxt] }
              else
                $w + { visited: ($w.visited + [$nxt]), cur: $nxt }
              end
          )
      ) as $res
    | "cycle: \($res.edge[0]) -> \($res.edge[1])"
  end
CCJQEOF

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

  local raw
  raw=$(cat -- "$src") || { echo "error: could not read input: $src" >&2; exit 2; }

  if ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "error: check-cycle input must be a JSON array" >&2
    exit 2
  fi

  local out rc
  out=$(printf '%s' "$raw" | jq -r "$CC_JQ") && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: check-cycle: jq program failed" >&2
    exit 2
  fi

  if [ -z "$out" ]; then
    exit 0
  fi
  echo "$out" >&2
  exit 1
}

# ---- ready-set jq program ---------------------------------------------------
# Input: a single JSON array value, [{"f": <path>, "doc": <parsed value> |
# "__BAD__"}, ...] -- one record per task file, built in bash by
# load_ready_docs (fast path or fallback, see below). "__BAD__" marks a file
# that could not be read or parsed. Tags every result line so bash can route
# it without a second jq pass: W=warn (unreadable file), B=blocked-dep
# (stderr only), R=ready (stdout only). Done set spans every valid task doc,
# unscoped. A doc whose depends_on is present but not an array is treated as
# invalid (excluded from $valid, same as a missing task_id) rather than
# raising a runtime error when a dep list is iterated.
read -r -d '' RS_JQ <<'RSJQEOF' || true
. as $docs
| ($docs | map(select(.doc == "__BAD__") | "W\t\(.f)")) as $warnings
| ($docs | map(select(.doc != "__BAD__") | .doc)) as $rawdocs
| ($rawdocs
    | map(select( type == "object"
                  and (.task_id | type) == "string"
                  and ((.depends_on == null) or (.depends_on | type) == "array") ))
  ) as $valid
| ($valid | map(select(.status == "completed") | .task_id)) as $done
| ( if $issue == "" then $valid
    else ($valid | map(select(.task_id
            | startswith($issue + "-")
            and (ltrimstr($issue + "-") | test("^[0-9]+$")))))
    end ) as $scope
| ($scope | map(select(.status == "pending"))) as $pending
| ($pending
    | map(select( ((.depends_on // []) | map(select(. as $d | ($done | index($d)) == null)) | length) == 0 ))
    | map("R\t\(.task_id)")) as $ready
| ($pending
    | map(. as $t
        | ((.depends_on // [])[]?) as $d
        | select( ($valid | map(select(.task_id == $d) | .status) | .[0]) == "blocked" )
        | "B\t\($t.task_id)\t\($d)")) as $blocked
| ($warnings + $blocked + $ready) | .[]
RSJQEOF

# load_ready_docs <file...> — prints one JSON array value [{"f","doc"}, ...],
# one record per file, doc either the parsed value or the string "__BAD__".
# Fast path: one ordinary jq pass over every file (self-delimiting JSON, so
# a missing trailing newline cannot merge two files' content). Falls back to
# a per-file read only when the fast pass fails outright, or its record
# count does not match the file count (a truncated file that still parsed,
# or one that could not be opened at all and made jq abort the whole pass).
# The fallback isolates each file: a read/parse failure on one file becomes
# its own "__BAD__" record and never drops the files after it.
load_ready_docs() {
  local fast_json fast_rc fast_count
  fast_json=$(jq -n -c '[inputs | {f: input_filename, doc: .}]' "$@" 2>/dev/null) && fast_rc=0 || fast_rc=$?
  if [ "$fast_rc" -eq 0 ]; then
    fast_count=$(printf '%s' "$fast_json" | jq 'length' 2>/dev/null) && : || fast_count=-1
    if [ "$fast_count" -eq "$#" ]; then
      printf '%s' "$fast_json"
      return 0
    fi
  fi

  local f
  { for f in "$@"; do
      if ! jq -c --arg f "$f" '{f: $f, doc: .}' -- "$f" 2>/dev/null; then
        jq -n -c --arg f "$f" '{f: $f, doc: "__BAD__"}'
      fi
    done
  } | jq -n -c '[inputs]'
}

cmd_ready_set() {
  local issue="" issue_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue)
        [ $# -ge 2 ] || { echo "error: --issue requires a value" >&2; usage; }
        [ "$issue_set" -eq 0 ] || { echo "error: --issue given more than once" >&2; usage; }
        issue="$2"
        issue_set=1
        shift 2
        ;;
      *)
        echo "error: unknown ready-set argument: $1" >&2
        usage
        ;;
    esac
  done

  if [ "$issue_set" -eq 1 ] && ! [[ "$issue" =~ $ID_RE ]]; then
    echo "error: --issue value must match $ID_RE, got: $issue" >&2
    exit 64
  fi

  if [ ! -d "$TASKS_DIR" ]; then
    return 0
  fi

  shopt -s nullglob
  local files=("$TASKS_DIR"/*.json)
  shopt -u nullglob
  if [ ${#files[@]} -eq 0 ]; then
    return 0
  fi

  local -a use_files=()
  local f
  for f in "${files[@]}"; do
    if [ -s "$f" ]; then
      use_files+=("$f")
    else
      echo "warning: skipping unreadable task file: $f" >&2
    fi
  done
  if [ ${#use_files[@]} -eq 0 ]; then
    return 0
  fi

  local docs_json rc
  docs_json=$(load_ready_docs "${use_files[@]}") && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: ready-set: could not read the task store" >&2
    exit 2
  fi

  local out
  out=$(printf '%s' "$docs_json" | jq -r --arg issue "$issue" "$RS_JQ") && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: ready-set: jq program failed" >&2
    exit 2
  fi

  local tag v1 v2
  while IFS=$'\t' read -r tag v1 v2 || [ -n "$tag" ]; do
    case "$tag" in
      R) printf '%s\n' "$v1" ;;
      W) printf 'warning: skipping unreadable task file: %s\n' "$v1" >&2 ;;
      B) printf 'blocked-dep: %s <- %s\n' "$v1" "$v2" >&2 ;;
      *) : ;;
    esac
  done <<<"$out"
}


# read_status <file> — prints .status (default "pending"); a corrupt or
# unparseable file exits 2 instead of leaking a raw jq exit code.
read_status() {
  local f="$1" st rc
  st=$(jq -r '.status // "pending"' "$f" 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: status-of: could not read $f" >&2
    exit 2
  fi
  printf '%s\n' "$st"
}

cmd_status_of() {
  [ $# -eq 1 ] || { echo "error: status-of requires 1 argument" >&2; usage; }
  local task_id="$1"
  if ! [[ "$task_id" =~ $ID_RE ]]; then
    echo "error: task_id must match $ID_RE, got: $task_id" >&2
    exit 64
  fi

  local exact="$TASKS_DIR/${task_id}.json"
  if [ -f "$exact" ]; then
    read_status "$exact"
    return 0
  fi

  shopt -s nullglob
  local matches=("$TASKS_DIR"/*-"${task_id}".json)
  shopt -u nullglob

  case "${#matches[@]}" in
    0) echo "pending" ;;
    1) read_status "${matches[0]}" ;;
    *)
      echo "error: ambiguous task id $task_id, matches:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      exit 2
      ;;
  esac
}

# ---- Dispatch ---------------------------------------------------------------
case "$SUBCMD" in
  check-cycle) cmd_check_cycle "$@" ;;
  ready-set)   cmd_ready_set "$@" ;;
  status-of)   cmd_status_of "$@" ;;
  *) echo "error: unknown subcommand: $SUBCMD" >&2; usage ;;
esac
