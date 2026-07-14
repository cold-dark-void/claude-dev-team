#!/usr/bin/env bash
# epic-lib.sh — epic state CLI (SPEC-025).
#
# Subprocess-only — NEVER source this file.
# Owns: $MROOT/.claude/epics/<EPIC-ID>/state.json atomic ops + epic ready-set.
# MUST NOT reimplement ticket lifecycle (/kickoff, /orchestrate, worktrees, tasks/).
# Cycle detection reuses skills/orchestrate/dag-lib.sh check-cycle literally.
#
# Exit codes: 0 ok, 1 operational fail, 2 conflict/exists, 64 usage.
# Stdout: data only. Diagnostics: stderr.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: bash skills/epic/epic-lib.sh <cmd> …

Commands:
  init <EPIC-ID> --title T --mode kickoff|orchestrate
  add-child <EPIC-ID> --id ID --slug S --title T --estimate S|M|L
            --agent ic4|ic5 --depends-on '["…"]'
            [--linear-id L] [--problem P] [--ac '["…"]']
  set-status <EPIC-ID> <CHILD-ID> pending|in_progress|completed|blocked
  mark-done <TICKET-ID>
  ready-set <EPIC-ID>
  check-cycle <json-file|->
  show <EPIC-ID>
  rollup
  waves <EPIC-ID>
  exists <EPIC-ID>
EOF
  exit 64
}

die() {
  local rc="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
}

if ! command -v jq >/dev/null 2>&1; then
  die 1 "jq is required but not found in PATH"
fi

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DAG_LIB="${EPIC_DAG_LIB:-$HERE/../orchestrate/dag-lib.sh}"

resolve_mroot() {
  if [ -n "${EPIC_ROOT:-}" ]; then
    MROOT="$EPIC_ROOT"
    return 0
  fi
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

epic_paths() {
  # epic_paths <EPIC-ID>
  local id="${1:-}"
  [ -n "$id" ] || die 64 "missing <EPIC-ID>"
  resolve_mroot
  EPICS_DIR="$MROOT/.claude/epics"
  EPIC_DIR="$EPICS_DIR/$id"
  STATE="$EPIC_DIR/state.json"
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

read_state() {
  # read_state <EPIC-ID> → stdout JSON
  epic_paths "$1"
  [ -f "$STATE" ] || die 1 "no state for epic: $1 ($STATE)"
  cat "$STATE"
}

write_state() {
  # write_state <EPIC-ID> <json-string>
  local id="$1" json="$2"
  epic_paths "$id"
  mkdir -p "$EPIC_DIR"
  local tmp
  # same-dir tmp for atomic rename on one FS
  tmp="$EPIC_DIR/state.json.tmp.$$"
  printf '%s\n' "$json" > "$tmp"
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die 1 "refusing to write invalid state JSON"
  fi
  # stamp updated_at
  local stamped
  stamped=$(jq --arg ts "$(iso_now)" '.updated_at = $ts' "$tmp")
  printf '%s\n' "$stamped" > "$tmp"
  mv "$tmp" "$STATE"
}

# ---- commands ---------------------------------------------------------------

cmd_init() {
  local epic_id="" title="" mode=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)
        title="${2:-}"; shift 2 || die 64 "init: --title needs value"
        ;;
      --mode)
        mode="${2:-}"; shift 2 || die 64 "init: --mode needs value"
        ;;
      -*)
        die 64 "init: unknown flag $1"
        ;;
      *)
        if [ -z "$epic_id" ]; then epic_id="$1"; shift
        else die 64 "init: unexpected arg $1"
        fi
        ;;
    esac
  done
  [ -n "$epic_id" ] || die 64 "init: missing <EPIC-ID>"
  [ -n "$title" ] || die 64 "init: --title required"
  case "$mode" in
    kickoff|orchestrate) ;;
    *) die 64 "init: --mode must be kickoff|orchestrate" ;;
  esac

  epic_paths "$epic_id"
  if [ -f "$STATE" ]; then
    die 2 "init: state already exists: $STATE"
  fi
  local ts json
  ts=$(iso_now)
  json=$(jq -cn \
    --arg id "$epic_id" \
    --arg title "$title" \
    --arg mode "$mode" \
    --arg ts "$ts" \
    '{epic_id:$id,title:$title,created_at:$ts,updated_at:$ts,execution_mode:$mode,children:[]}')
  write_state "$epic_id" "$json"
  printf '%s\n' "$STATE"
}

cmd_add_child() {
  local epic_id="" cid="" slug="" title="" estimate="" agent="" depends_on="[]"
  local linear_id="" problem="" ac="[]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) cid="${2:-}"; shift 2 || die 64 "add-child: --id needs value" ;;
      --slug) slug="${2:-}"; shift 2 || die 64 "add-child: --slug needs value" ;;
      --title) title="${2:-}"; shift 2 || die 64 "add-child: --title needs value" ;;
      --estimate) estimate="${2:-}"; shift 2 || die 64 "add-child: --estimate needs value" ;;
      --agent) agent="${2:-}"; shift 2 || die 64 "add-child: --agent needs value" ;;
      --depends-on) depends_on="${2:-}"; shift 2 || die 64 "add-child: --depends-on needs value" ;;
      --linear-id) linear_id="${2:-}"; shift 2 || die 64 "add-child: --linear-id needs value" ;;
      --problem) problem="${2:-}"; shift 2 || die 64 "add-child: --problem needs value" ;;
      --ac) ac="${2:-}"; shift 2 || die 64 "add-child: --ac needs value" ;;
      -*) die 64 "add-child: unknown flag $1" ;;
      *)
        if [ -z "$epic_id" ]; then epic_id="$1"; shift
        else die 64 "add-child: unexpected arg $1"
        fi
        ;;
    esac
  done
  [ -n "$epic_id" ] || die 64 "add-child: missing <EPIC-ID>"
  [ -n "$cid" ] || die 64 "add-child: --id required"
  [ -n "$slug" ] || die 64 "add-child: --slug required"
  [ -n "$title" ] || die 64 "add-child: --title required"
  case "$estimate" in S|M|L) ;; *) die 64 "add-child: --estimate must be S|M|L" ;; esac
  case "$agent" in ic4|ic5) ;; *) die 64 "add-child: --agent must be ic4|ic5" ;; esac

  # ID scheme: <EPIC-ID>-C<n>
  if ! printf '%s' "$cid" | grep -Eq "^${epic_id}-C[0-9]+$"; then
    die 64 "add-child: id must match ${epic_id}-C[0-9]+ (got $cid)"
  fi

  if ! printf '%s' "$depends_on" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die 64 "add-child: --depends-on must be a JSON array"
  fi
  if ! printf '%s' "$ac" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die 64 "add-child: --ac must be a JSON array"
  fi

  local st child linear_json
  st=$(read_state "$epic_id")
  if echo "$st" | jq -e --arg id "$cid" '.children[] | select(.id==$id)' >/dev/null 2>&1; then
    die 2 "add-child: child already exists: $cid"
  fi

  if [ -n "$linear_id" ]; then
    linear_json=$(jq -cn --arg v "$linear_id" '$v')
  else
    linear_json="null"
  fi

  child=$(jq -cn \
    --arg id "$cid" \
    --arg slug "$slug" \
    --arg title "$title" \
    --arg estimate "$estimate" \
    --arg agent "$agent" \
    --argjson deps "$depends_on" \
    --argjson lin "$linear_json" \
    --arg problem "$problem" \
    --argjson ac "$ac" \
    '{
      id:$id, slug:$slug, title:$title, estimate:$estimate, agent:$agent,
      depends_on:$deps, status:"pending", linear_id:$lin,
      problem:$problem, acceptance_criteria:$ac
    }')
  st=$(echo "$st" | jq --argjson c "$child" '.children += [$c]')
  write_state "$epic_id" "$st"
  echo "$st" | jq -c --arg id "$cid" '.children[] | select(.id==$id)'
}

cmd_set_status() {
  local epic_id="${1:-}" child_id="${2:-}" status="${3:-}"
  [ -n "$epic_id" ] || die 64 "set-status: missing <EPIC-ID>"
  [ -n "$child_id" ] || die 64 "set-status: missing <CHILD-ID>"
  case "$status" in
    pending|in_progress|completed|blocked) ;;
    *) die 64 "set-status: status must be pending|in_progress|completed|blocked" ;;
  esac
  local st
  st=$(read_state "$epic_id")
  if ! echo "$st" | jq -e --arg id "$child_id" '.children[] | select(.id==$id)' >/dev/null 2>&1; then
    die 1 "set-status: child not found: $child_id"
  fi
  st=$(echo "$st" | jq --arg id "$child_id" --arg s "$status" \
    '(.children[] | select(.id==$id) | .status) = $s')
  write_state "$epic_id" "$st"
  echo "$st" | jq -c --arg id "$child_id" '.children[] | select(.id==$id)'
}

cmd_mark_done() {
  local ticket="${1:-}"
  [ -n "$ticket" ] || die 64 "mark-done: missing <TICKET-ID>"
  resolve_mroot
  local epics_dir="$MROOT/.claude/epics"
  [ -d "$epics_dir" ] || exit 0

  local found=0
  local state_file epic_id st
  while IFS= read -r state_file; do
    [ -f "$state_file" ] || continue
    epic_id=$(jq -r '.epic_id // empty' "$state_file" 2>/dev/null) || continue
    [ -n "$epic_id" ] || continue
    if ! jq -e --arg t "$ticket" \
      '.children[] | select(.id==$t or .linear_id==$t)' "$state_file" >/dev/null 2>&1; then
      continue
    fi
    st=$(jq --arg t "$ticket" \
      '(.children[] | select(.id==$t or .linear_id==$t) | .status) = "completed"' \
      "$state_file")
    write_state "$epic_id" "$st"
    found=1
    echo "$st" | jq -c --arg t "$ticket" \
      '.children[] | select(.id==$t or .linear_id==$t)'
  done < <(find "$epics_dir" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort)

  # soft no-op if unknown (wrap-ticket)
  [ "$found" -eq 1 ] || true
  exit 0
}

cmd_ready_set() {
  local epic_id="${1:-}"
  [ -n "$epic_id" ] || die 64 "ready-set: missing <EPIC-ID>"
  local st
  st=$(read_state "$epic_id")
  # ready ⟺ status=pending AND every depends_on id has status=completed
  # missing dep id → treat as incomplete
  echo "$st" | jq -r '
    .children as $all
    | ($all | map({key:.id, value:.status}) | from_entries) as $stmap
    | $all[]
    | select(.status == "pending")
    | select(
        all(.depends_on[]?;
          ($stmap[.] // "missing") == "completed"
        )
      )
    | .id
  ' | sort
}

cmd_check_cycle() {
  local src="${1:-}"
  [ -n "$src" ] || die 64 "check-cycle: missing <json-file|->"
  [ -f "$DAG_LIB" ] || die 1 "dag-lib not found: $DAG_LIB"
  # thin wrapper — no reimplemented DFS
  bash "$DAG_LIB" check-cycle "$src"
}

cmd_show() {
  local epic_id="${1:-}"
  [ -n "$epic_id" ] || die 64 "show: missing <EPIC-ID>"
  local st ready waves
  st=$(read_state "$epic_id")
  ready=$(cmd_ready_set "$epic_id" | paste -sd, - || true)
  waves=$(cmd_waves "$epic_id" || true)
  echo "$st" | jq --arg ready "$ready" --arg waves "$waves" '
    {
      epic_id, title, execution_mode, created_at, updated_at,
      counts: {
        pending: ([.children[] | select(.status=="pending")] | length),
        in_progress: ([.children[] | select(.status=="in_progress")] | length),
        completed: ([.children[] | select(.status=="completed")] | length),
        blocked: ([.children[] | select(.status=="blocked")] | length),
        total: (.children | length)
      },
      ready: (if $ready == "" then [] else ($ready | split(",")) end),
      waves: $waves,
      children: .children
    }
  '
}

cmd_rollup() {
  resolve_mroot
  local epics_dir="$MROOT/.claude/epics"
  if [ ! -d "$epics_dir" ]; then
    exit 0
  fi
  local state_file epic_id st non_done ready waves
  local any=0
  while IFS= read -r state_file; do
    [ -f "$state_file" ] || continue
    st=$(cat "$state_file")
    epic_id=$(echo "$st" | jq -r '.epic_id // empty')
    [ -n "$epic_id" ] || continue
    non_done=$(echo "$st" | jq '[.children[] | select(.status != "completed")] | length')
    [ "$non_done" -gt 0 ] || continue
    any=1
    ready=$(echo "$st" | jq -r '
      .children as $all
      | ($all | map({key:.id, value:.status}) | from_entries) as $stmap
      | $all[]
      | select(.status == "pending")
      | select(all(.depends_on[]?; ($stmap[.] // "missing") == "completed"))
      | .id
    ' | sort | paste -sd, -)
    waves=$(cmd_waves "$epic_id" 2>/dev/null || true)
    echo "$st" | jq -c --arg ready "${ready:-}" --arg waves "${waves:-}" '
      {
        epic_id, title, execution_mode,
        counts: {
          pending: ([.children[] | select(.status=="pending")] | length),
          in_progress: ([.children[] | select(.status=="in_progress")] | length),
          completed: ([.children[] | select(.status=="completed")] | length),
          blocked: ([.children[] | select(.status=="blocked")] | length),
          total: (.children | length)
        },
        ready: (if $ready == "" then [] else ($ready | split(",")) end),
        waves: $waves
      }
    '
  done < <(find "$epics_dir" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort)
  [ "$any" -eq 1 ] || true
}

cmd_waves() {
  # Kahn topological levels for display. Output: "Wave 1: C1, C2 → Wave 2: C3"
  local epic_id="${1:-}"
  [ -n "$epic_id" ] || die 64 "waves: missing <EPIC-ID>"
  local st
  st=$(read_state "$epic_id")

  # Build remaining indegree + adj via jq, then layer in bash
  local nodes deps
  nodes=$(echo "$st" | jq -r '.children[].id' | sort)
  [ -n "$nodes" ] || { printf '\n'; return 0; }

  declare -A indeg=()
  declare -A children_of=()  # parent -> space-separated kids that depend on parent
  declare -A status_of=()

  while IFS=$'\t' read -r id status depjson; do
    status_of["$id"]="$status"
    indeg["$id"]=0
    # count only deps that are also nodes in this epic
    local d
    for d in $(echo "$depjson" | jq -r '.[]'); do
      if echo "$st" | jq -e --arg d "$d" '.children[] | select(.id==$d)' >/dev/null 2>&1; then
        indeg["$id"]=$(( ${indeg["$id"]} + 1 ))
        children_of["$d"]="${children_of[$d]:-} $id"
      fi
    done
  done < <(echo "$st" | jq -r '.children[] | [.id, .status, (.depends_on|tostring)] | @tsv')

  local remaining=0
  local n
  for n in $nodes; do remaining=$((remaining + 1)); done

  local wave_num=0
  local parts=()
  local visited=0

  while [ "$visited" -lt "$remaining" ]; do
    local layer=()
    for n in $nodes; do
      if [ "${indeg[$n]:--1}" -eq 0 ]; then
        layer+=("$n")
      fi
    done
    if [ "${#layer[@]}" -eq 0 ]; then
      # cycle or leftover — dump remaining as final wave (should not happen post check-cycle)
      for n in $nodes; do
        if [ "${indeg[$n]:--1}" -ge 0 ]; then
          layer+=("$n")
        fi
      done
      if [ "${#layer[@]}" -eq 0 ]; then break; fi
    fi
    wave_num=$((wave_num + 1))
    # stable sort layer
    local sorted
    sorted=$(printf '%s\n' "${layer[@]}" | sort | paste -sd, -)
    parts+=("Wave ${wave_num}: ${sorted//,/, }")
    for n in "${layer[@]}"; do
      indeg["$n"]=-1
      visited=$((visited + 1))
      local kid
      for kid in ${children_of[$n]:-}; do
        if [ "${indeg[$kid]:--1}" -gt 0 ]; then
          indeg["$kid"]=$(( ${indeg[$kid]} - 1 ))
        fi
      done
    done
  done

  local out=""
  local i
  for i in "${!parts[@]}"; do
    if [ -n "$out" ]; then out+=" → "; fi
    out+="${parts[$i]}"
  done
  printf '%s\n' "$out"
}

cmd_exists() {
  local epic_id="${1:-}"
  [ -n "$epic_id" ] || die 64 "exists: missing <EPIC-ID>"
  epic_paths "$epic_id"
  [ -f "$STATE" ]
}

# ---- dispatch ---------------------------------------------------------------

[ $# -lt 1 ] && usage
SUBCMD="$1"; shift

case "$SUBCMD" in
  init)        cmd_init "$@" ;;
  add-child)   cmd_add_child "$@" ;;
  set-status)  cmd_set_status "$@" ;;
  mark-done)   cmd_mark_done "$@" ;;
  ready-set)   cmd_ready_set "$@" ;;
  check-cycle) cmd_check_cycle "$@" ;;
  show)        cmd_show "$@" ;;
  rollup)      cmd_rollup "$@" ;;
  waves)       cmd_waves "$@" ;;
  exists)      cmd_exists "$@" ;;
  -h|--help|help) usage ;;
  *) die 64 "unknown subcommand: $SUBCMD" ;;
esac
