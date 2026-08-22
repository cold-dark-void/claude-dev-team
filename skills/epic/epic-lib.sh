#!/usr/bin/env bash
# epic-lib.sh — epic state CLI (SPEC-025).
#
# Subprocess-only — NEVER source this file.
# Owns: $MROOT/.claude/epics/<EPIC-ID>/state.json atomic ops + epic ready-set.
# MUST NOT reimplement ticket lifecycle (/kickoff, /orchestrate, tasks/).
# M11 carve-out (CDT-141-C2/C3/C4/C5/C6): MAY ensure one epic integration worktree via
# worktree-lib when worktree_enabled — never per-child worktrees. Children route
# into that tree via ensure-ticket-worktree (C3). C4: assert-release-allowed
# forbids mid-epic /release and master-merge when release_bump is set until seal.
# C5: seal-ready + seal (squash-stage → one /release <bump> → sealed=true).
# M16 (CDT-158): gap-callout — warn-only mid-epic incomplete-child notice.
# Resume reuses same tree; flag vs state conflict hard-fails (C6).
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
       [--worktree-enabled true|false] [--release-bump patch|minor|major]
  add-child <EPIC-ID> --id ID --slug S --title T --estimate S|M|L
            --agent ic4|ic5 --depends-on '["…"]'
            [--linear-id L] [--problem P] [--ac '["…"]']
  set-status <EPIC-ID> <CHILD-ID> pending|in_progress|completed|blocked
             [--outcome "…"]   # optional; completed|blocked only; ≤200 chars, 1 line
  set-linear-project <EPIC-ID> <PROJECT-ID>|null|--clear
  set-last-seed <EPIC-ID> <path>|null|--clear
  ensure-integration-worktree <EPIC-ID>
  resolve-resume-flags <EPIC-ID> [--] [args...]
  resolve-child-worktree <TICKET-ID>
  ensure-ticket-worktree <TICKET-ID>
  assert-release-allowed <ticket-or-epic>
  gap-callout <ticket-or-epic>
  seal-ready <EPIC-ID>
  seal <EPIC-ID> [--dry-run|--complete|--abort [--force]]
  build-seed <EPIC-ID> [--next <CHILD-ID>] [--out path]
  validate-seed <path>
  mark-done <TICKET-ID>
  sync-apply <EPIC-ID> --verdicts FILE [--dry-run]
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

# validate_epic_id <id>  — die 64 if empty or outside allowlist (CDT-169)
validate_epic_id() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    die 64 "missing <EPIC-ID>"
  fi
  if [[ ! "$id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die 64 "invalid epic id (only [A-Za-z0-9_-] allowed): $id"
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  die 1 "jq is required but not found in PATH"
fi

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DAG_LIB="${EPIC_DAG_LIB:-$HERE/../orchestrate/dag-lib.sh}"
# worktree-lib: EPIC_WT_LIB for tests; else co-located sibling (install-aware via PDH in SKILL callers)
WT_LIB="${EPIC_WT_LIB:-$HERE/../worktree-lib.sh}"

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
  validate_epic_id "$id"
  resolve_mroot
  EPICS_DIR="$MROOT/.claude/epics"
  # Global exclusive lock for state RMW (SPEC-025 M6 / CDT-165).
  # Production: $MROOT/.claude/epics/.lock
  # Tests (EPIC_ROOT set): $EPIC_ROOT/.claude/epics/.lock
  EPICS_LOCK="$EPICS_DIR/.lock"
  EPIC_DIR="$EPICS_DIR/$id"
  STATE="$EPIC_DIR/state.json"
}

# ---- Concurrency (SPEC-025 M6) ----------------------------------------------
# EPICS_LOCK serializes all state.json mutators across epics (global flock).
# write_state is an unlocked atomic publish helper (tmp+mv) — callers MUST hold
# EPICS_LOCK around full RMW so concurrent processes cannot lose fields.
# Do NOT flock inside write_state (same-process multi-fd self-deadlock risk).
# Readers (read_state / show / ready-set / …) stay unlocked — stale complete
# JSON is OK (AC5).
#
# Mutator critical section pattern (block forever; append-open so flock fd
# never truncates the lock file):
#   mkdir -p "$EPICS_DIR"
#   (
#     flock -x 9
#     st=$(cat "$STATE")   # or empty for init
#     # pure in-memory mutate
#     write_state "$epic_id" "$st"
#   ) 9>>"$EPICS_LOCK"
#
# Hold lock for state RMW only — never across Linear MCP, worktree-lib, or git.

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

read_state() {
  # read_state <EPIC-ID> → stdout JSON (unlocked; AC5)
  epic_paths "$1"
  [ -f "$STATE" ] || die 1 "no state for epic: $1 ($STATE)"
  cat "$STATE"
}

write_state() {
  # write_state <EPIC-ID> <json-string>
  # Unlocked publish: same-dir tmp + jq validate + stamp + mv (AC4).
  # Callers that RMW MUST wrap read+mutate+write_state under EPICS_LOCK
  # (see Concurrency block above). No flock here — avoids nested deadlock.
  local id="$1" json="$2"
  epic_paths "$id"
  mkdir -p "$EPICS_DIR" "$EPIC_DIR"
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
  # CDT-141-C1 / M14 — optional; omitted keys keep default path byte-compatible
  local wt_set=false wt_enabled=false
  local rel_set=false rel_bump=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)
        title="${2:-}"; shift 2 || die 64 "init: --title needs value"
        ;;
      --mode)
        mode="${2:-}"; shift 2 || die 64 "init: --mode needs value"
        ;;
      --worktree-enabled)
        wt_set=true
        case "${2:-}" in
          true|false)
            wt_enabled="$2"; shift 2 || die 64 "init: --worktree-enabled needs true|false"
            ;;
          *)
            die 64 "init: --worktree-enabled must be true|false"
            ;;
        esac
        ;;
      --release-bump)
        rel_set=true
        rel_bump="${2:-}"; shift 2 || die 64 "init: --release-bump needs value"
        case "$rel_bump" in
          patch|minor|major) ;;
          *) die 64 "init: --release-bump must be patch|minor|major" ;;
        esac
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
  if [ "$rel_set" = true ] && [ "$wt_enabled" != true ]; then
    die 64 "init: --release-bump requires --worktree-enabled true"
  fi

  epic_paths "$epic_id"
  local ts json
  ts=$(iso_now)
  if [ "$wt_set" = true ] || [ "$rel_set" = true ]; then
    # Modes set → always write both keys (release_bump may be null)
    if [ "$rel_set" = true ]; then
      json=$(jq -cn \
        --arg id "$epic_id" \
        --arg title "$title" \
        --arg mode "$mode" \
        --arg ts "$ts" \
        --argjson wt "$wt_enabled" \
        --arg rb "$rel_bump" \
        '{epic_id:$id,title:$title,created_at:$ts,updated_at:$ts,execution_mode:$mode,linear_project_id:null,worktree_enabled:$wt,release_bump:$rb,children:[]}')
    else
      json=$(jq -cn \
        --arg id "$epic_id" \
        --arg title "$title" \
        --arg mode "$mode" \
        --arg ts "$ts" \
        --argjson wt "$wt_enabled" \
        '{epic_id:$id,title:$title,created_at:$ts,updated_at:$ts,execution_mode:$mode,linear_project_id:null,worktree_enabled:$wt,release_bump:null,children:[]}')
    fi
  else
    # Default path: omit M14 keys (AC6/AC7 — readers default false/null)
    json=$(jq -cn \
      --arg id "$epic_id" \
      --arg title "$title" \
      --arg mode "$mode" \
      --arg ts "$ts" \
      '{epic_id:$id,title:$title,created_at:$ts,updated_at:$ts,execution_mode:$mode,linear_project_id:null,children:[]}')
  fi
  # Exists-check + first write under EPICS_LOCK (SPEC-025 M6)
  mkdir -p "$EPICS_DIR"
  (
    flock -x 9
    if [ -f "$STATE" ]; then
      die 2 "init: state already exists: $STATE"
    fi
    write_state "$epic_id" "$json"
  ) 9>>"$EPICS_LOCK"
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

  epic_paths "$epic_id"
  mkdir -p "$EPICS_DIR"
  (
    flock -x 9
    st=$(read_state "$epic_id")
    if echo "$st" | jq -e --arg id "$cid" '.children[] | select(.id==$id)' >/dev/null 2>&1; then
      die 2 "add-child: child already exists: $cid"
    fi
    st=$(echo "$st" | jq --argjson c "$child" '.children += [$c]')
    write_state "$epic_id" "$st"
    echo "$st" | jq -c --arg id "$cid" '.children[] | select(.id==$id)'
  ) 9>>"$EPICS_LOCK"
}

cmd_set_status() {
  # set-status <EPIC-ID> <CHILD-ID> <status> [--outcome "…"]
  # Optional --outcome only with completed|blocked: ≤200 chars, newlines→spaces, 1 line
  # written to children[].outcome_summary. 3-arg path unchanged when --outcome omitted.
  local epic_id="${1:-}" child_id="${2:-}" status="${3:-}"
  [ -n "$epic_id" ] || die 64 "set-status: missing <EPIC-ID>"
  [ -n "$child_id" ] || die 64 "set-status: missing <CHILD-ID>"
  [ -n "$status" ] || die 64 "set-status: missing status"
  case "$status" in
    pending|in_progress|completed|blocked) ;;
    *) die 64 "set-status: status must be pending|in_progress|completed|blocked" ;;
  esac
  shift 3

  local outcome="" have_outcome=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --outcome)
        [ $# -ge 2 ] || die 64 "set-status: --outcome requires a value"
        outcome="$2"
        have_outcome=1
        shift 2
        ;;
      --outcome=*)
        outcome="${1#--outcome=}"
        have_outcome=1
        shift
        ;;
      -*)
        die 64 "set-status: unknown flag $1"
        ;;
      *)
        die 64 "set-status: unexpected arg: $1"
        ;;
    esac
  done

  if [ "$have_outcome" -eq 1 ]; then
    case "$status" in
      completed|blocked) ;;
      *) die 64 "set-status: --outcome only allowed with completed|blocked" ;;
    esac
    # newlines → spaces; collapse runs of whitespace; trim ends → 1 line
    outcome=$(printf '%s' "$outcome" | tr '\n\r' '  ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ "${#outcome}" -gt 200 ]; then
      die 64 "set-status: --outcome must be ≤200 chars (got ${#outcome})"
    fi
  fi

  epic_paths "$epic_id"
  mkdir -p "$EPICS_DIR"
  local st
  (
    flock -x 9
    st=$(read_state "$epic_id")
    if ! echo "$st" | jq -e --arg id "$child_id" '.children[] | select(.id==$id)' >/dev/null 2>&1; then
      die 1 "set-status: child not found: $child_id"
    fi
    if [ "$have_outcome" -eq 1 ]; then
      st=$(echo "$st" | jq --arg id "$child_id" --arg s "$status" --arg o "$outcome" \
        '(.children[] | select(.id==$id) | .status) = $s
         | (.children[] | select(.id==$id) | .outcome_summary) = $o')
    else
      st=$(echo "$st" | jq --arg id "$child_id" --arg s "$status" \
        '(.children[] | select(.id==$id) | .status) = $s')
    fi
    write_state "$epic_id" "$st"
    echo "$st" | jq -c --arg id "$child_id" '.children[] | select(.id==$id)'
  ) 9>>"$EPICS_LOCK"
}

cmd_set_linear_project() {
  # set-linear-project <EPIC-ID> <PROJECT-ID>|null|--clear
  # Persists only — never calls Linear MCP/network.
  # Exit codes: 1 = not found (same as read_state / set-status); 2 reserved for
  # "already exists" elsewhere; 64 = usage / invalid flag.
  local epic_id="${1:-}" raw="${2:-}"
  [ -n "$epic_id" ] || die 64 "set-linear-project: missing <EPIC-ID>"
  [ $# -ge 2 ] || die 64 "set-linear-project: missing <PROJECT-ID>|null|--clear"

  # Reject flag typos (e.g. --clea) that would otherwise be stored as project ids.
  case "$raw" in
    --clear) ;;
    -*) die 64 "set-linear-project: unknown flag $raw (use PROJECT-ID|null|--clear)" ;;
  esac

  epic_paths "$epic_id"
  mkdir -p "$EPICS_DIR"
  local st
  (
    flock -x 9
    st=$(read_state "$epic_id")   # die 1 if epic missing
    case "$raw" in
      ""|null|--clear)
        st=$(echo "$st" | jq '.linear_project_id = null')
        ;;
      *)
        st=$(echo "$st" | jq --arg v "$raw" '.linear_project_id = $v')
        ;;
    esac
    write_state "$epic_id" "$st"
    echo "$st" | jq -c '{linear_project_id}'
  ) 9>>"$EPICS_LOCK"
}

cmd_set_last_seed() {
  # set-last-seed <EPIC-ID> <path>|null|--clear
  # Top-level last_seed_path (CDT-127 / SPEC-025 M6 additive). Persists only.
  # Exit codes: 1 = epic not found; 64 = usage / invalid flag.
  local epic_id="${1:-}" raw="${2:-}"
  [ -n "$epic_id" ] || die 64 "set-last-seed: missing <EPIC-ID>"
  [ $# -ge 2 ] || die 64 "set-last-seed: missing <path>|null|--clear"

  case "$raw" in
    --clear) ;;
    -*) die 64 "set-last-seed: unknown flag $raw (use path|null|--clear)" ;;
  esac

  epic_paths "$epic_id"
  mkdir -p "$EPICS_DIR"
  local st
  (
    flock -x 9
    st=$(read_state "$epic_id")
    case "$raw" in
      ""|null|--clear)
        st=$(echo "$st" | jq '.last_seed_path = null')
        ;;
      *)
        st=$(echo "$st" | jq --arg v "$raw" '.last_seed_path = $v')
        ;;
    esac
    write_state "$epic_id" "$st"
    echo "$st" | jq -c '{last_seed_path}'
  ) 9>>"$EPICS_LOCK"
}

cmd_ensure_integration_worktree() {
  # ensure-integration-worktree <EPIC-ID>
  # CDT-141-C2 / M14: one epic integration worktree when worktree_enabled.
  # worktree_enabled // false → no-op exit 0 (no create).
  # true → ensure slug epic-<ID> via worktree-lib; record slug/path/branch atomically.
  # Reuse: if integration_path already set and dir exists, skip ensure (FRESH-lock safe).
  local epic_id="${1:-}"
  [ -n "$epic_id" ] || die 64 "ensure-integration-worktree: missing <EPIC-ID>"
  [ $# -eq 1 ] || die 64 "ensure-integration-worktree: unexpected args"

  local st wt_enabled slug branch existing_path path reused=false
  st=$(read_state "$epic_id")
  wt_enabled=$(echo "$st" | jq -r '.worktree_enabled // false')

  if [ "$wt_enabled" != "true" ]; then
    jq -cn \
      '{worktree_enabled:false,integration_slug:null,integration_path:null,integration_branch:null,reused:false}'
    return 0
  fi

  slug="epic-${epic_id}"
  branch="feat/${slug}"
  existing_path=$(echo "$st" | jq -r '.integration_path // empty')

  if [ -n "$existing_path" ] && [ -d "$existing_path" ]; then
    # Already recorded + on disk — reuse without worktree-lib ensure (avoids FRESH prompt).
    path="$existing_path"
    reused=true
  else
    [ -f "$WT_LIB" ] || die 1 "ensure-integration-worktree: worktree-lib not found: $WT_LIB"

    # Subprocess only — never source. worktree-lib outside EPICS_LOCK (OQ2).
    local errf erc=0
    errf=$(mktemp "${TMPDIR:-/tmp}/epic-wt-ensure.XXXXXX")
    set +e
    path=$(bash "$WT_LIB" ensure "$slug" 2>"$errf")
    erc=$?
    set -e
    if [ "$erc" -ne 0 ] || [ -z "$path" ]; then
      local diag
      diag=$(tr '\n' ' ' <"$errf" | sed 's/[[:space:]]*$//')
      rm -f "$errf"
      die "${erc:-1}" "ensure-integration-worktree: worktree-lib ensure failed for $slug (rc=$erc)${diag:+: $diag}"
    fi
    rm -f "$errf"

    # Normalize path (strip trailing newline/whitespace)
    path=$(printf '%s' "$path" | tr -d '\r' | sed 's/[[:space:]]*$//')
    [ -n "$path" ] || die 1 "ensure-integration-worktree: empty path from worktree-lib"
    [ -d "$path" ] || die 1 "ensure-integration-worktree: path not a directory: $path"
    reused=false
  fi

  # State RMW under EPICS_LOCK — re-read then set integration_* (SPEC-025 M6)
  epic_paths "$epic_id"
  mkdir -p "$EPICS_DIR"
  (
    flock -x 9
    st=$(read_state "$epic_id")
    # Prefer still-valid recorded path under lock (heal race with concurrent ensure)
    existing_path=$(echo "$st" | jq -r '.integration_path // empty')
    if [ -n "$existing_path" ] && [ -d "$existing_path" ]; then
      path="$existing_path"
      reused=true
    fi
    st=$(echo "$st" | jq \
      --arg s "$slug" --arg p "$path" --arg b "$branch" \
      '.integration_slug = $s | .integration_path = $p | .integration_branch = $b')
    write_state "$epic_id" "$st"
    echo "$st" | jq -c --argjson reused "$([ "$reused" = true ] && echo true || echo false)" \
      '{worktree_enabled:true,integration_slug,integration_path,integration_branch,reused:$reused}'
  ) 9>>"$EPICS_LOCK"
}

cmd_resolve_resume_flags() {
  # resolve-resume-flags <EPIC-ID> [--] [args...]
  # CDT-141-C6 / M14: resume mode resolution against durable state.
  # - M14 flags omitted (--worktree / --release absent) → honor state
  #   (worktree_enabled // false, release_bump // null). No silent downgrade.
  # - M14 flags present → must match state exactly or exit 64 (zero side effects).
  # - Always re-parses via parse-flags first (illegal combos still 64).
  # Stdout: same JSON as parse-flags.sh.
  local epic_id="${1:-}"
  [ -n "$epic_id" ] || die 64 "resolve-resume-flags: missing <EPIC-ID>"
  shift
  if [ "${1:-}" = "--" ]; then
    shift
  fi

  local st
  st=$(read_state "$epic_id")

  local parse_flags="${EPIC_PARSE_FLAGS:-$HERE/parse-flags.sh}"
  [ -f "$parse_flags" ] || die 1 "resolve-resume-flags: parse-flags not found: $parse_flags"

  local parsed prc=0
  set +e
  parsed=$(bash "$parse_flags" "$@" 2>&1)
  prc=$?
  set -e
  if [ "$prc" -ne 0 ]; then
    printf '%s\n' "$parsed" >&2
    exit "$prc"
  fi

  local flags_present=false a
  for a in "$@"; do
    case "$a" in
      --worktree|--worktree=*|--release|--release=*)
        flags_present=true
        break
        ;;
    esac
  done

  local sw sr
  sw=$(echo "$st" | jq -r 'if .worktree_enabled == true then "true" else "false" end')
  sr=$(echo "$st" | jq -c '.release_bump // null')

  if [ "$flags_present" = false ]; then
    # Honor durable store — modes from state, not CLI defaults
    jq -cn \
      --argjson worktree_enabled "$sw" \
      --argjson release_bump "$sr" \
      '{worktree_enabled:$worktree_enabled, release_bump:$release_bump}'
    return 0
  fi

  local pw pr
  pw=$(echo "$parsed" | jq -r '.worktree_enabled')
  pr=$(echo "$parsed" | jq -c '.release_bump // null')

  if [ "$pw" != "$sw" ] || [ "$pr" != "$sr" ]; then
    die 64 "resume flag conflict: CLI worktree_enabled=$pw release_bump=$pr vs state worktree_enabled=$sw release_bump=$sr (omit flags to honor stored mode; no silent mode change)"
  fi

  printf '%s\n' "$parsed"
}

# ---- CDT-141-C3: children share epic integration worktree -------------------

# Internal: find parent epic state for a child ticket (id or linear_id).
# Sets: _RCW_FOUND (0|1), _RCW_EPIC_ID, _RCW_STATE_JSON (full state when found).
_find_parent_epic_for_ticket() {
  local ticket="${1:-}"
  _RCW_FOUND=0
  _RCW_EPIC_ID=""
  _RCW_STATE_JSON=""
  resolve_mroot
  local epics_dir="$MROOT/.claude/epics"
  [ -d "$epics_dir" ] || return 0
  local state_file epic_id
  while IFS= read -r state_file; do
    [ -f "$state_file" ] || continue
    epic_id=$(jq -r '.epic_id // empty' "$state_file" 2>/dev/null) || continue
    [ -n "$epic_id" ] || continue
    if jq -e --arg t "$ticket" \
      '.children[] | select(.id==$t or .linear_id==$t)' "$state_file" >/dev/null 2>&1; then
      _RCW_FOUND=1
      _RCW_EPIC_ID="$epic_id"
      _RCW_STATE_JSON=$(cat "$state_file")
      return 0
    fi
  done < <(find "$epics_dir" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort)
  return 0
}

cmd_resolve_child_worktree() {
  # resolve-child-worktree <TICKET-ID>
  # Lookup parent epic for ticket; report whether child must use shared integration WT.
  # Soft: unknown ticket → use_shared=false (default per-child path). Exit 0 always
  # except usage (64).
  local ticket="${1:-}"
  [ -n "$ticket" ] || die 64 "resolve-child-worktree: missing <TICKET-ID>"
  [ $# -eq 1 ] || die 64 "resolve-child-worktree: unexpected args"

  local is_child=false epic_id="" wt_enabled=false
  local int_path="" int_slug="" int_branch=""
  local use_shared=false source="none"

  _find_parent_epic_for_ticket "$ticket"
  if [ "$_RCW_FOUND" -eq 1 ]; then
    is_child=true
    epic_id="$_RCW_EPIC_ID"
    wt_enabled=$(echo "$_RCW_STATE_JSON" | jq -r '.worktree_enabled // false')
    int_path=$(echo "$_RCW_STATE_JSON" | jq -r '.integration_path // empty')
    int_slug=$(echo "$_RCW_STATE_JSON" | jq -r '.integration_slug // empty')
    int_branch=$(echo "$_RCW_STATE_JSON" | jq -r '.integration_branch // empty')
    if [ "$wt_enabled" = "true" ] && [ -n "$int_path" ] && [ -d "$int_path" ]; then
      use_shared=true
      source="epic_state"
    fi
  fi

  # Handoff env channel (B.4 sets EPIC_INTEGRATION_PATH) — only if not already shared.
  if [ "$use_shared" != "true" ] && [ -n "${EPIC_INTEGRATION_PATH:-}" ] && [ -d "$EPIC_INTEGRATION_PATH" ]; then
    use_shared=true
    int_path="$EPIC_INTEGRATION_PATH"
    [ -n "$int_slug" ] || int_slug=$(basename "$int_path")
    [ -n "$int_branch" ] || int_branch="feat/${int_slug}"
    source="env"
  fi

  local skip_ensure=false skip_release=false
  if [ "$use_shared" = "true" ]; then
    skip_ensure=true
    skip_release=true
  fi

  jq -cn \
    --arg ticket "$ticket" \
    --argjson is_epic_child "$is_child" \
    --arg epic_id "${epic_id}" \
    --argjson worktree_enabled "$wt_enabled" \
    --argjson use_shared "$use_shared" \
    --arg integration_path "${int_path}" \
    --arg integration_slug "${int_slug}" \
    --arg integration_branch "${int_branch}" \
    --argjson skip_ensure "$skip_ensure" \
    --argjson skip_release "$skip_release" \
    --arg source "$source" \
    '{
      ticket_id: $ticket,
      is_epic_child: $is_epic_child,
      epic_id: (if $epic_id == "" then null else $epic_id end),
      worktree_enabled: $worktree_enabled,
      use_shared: $use_shared,
      integration_path: (if $integration_path == "" then null else $integration_path end),
      integration_slug: (if $integration_slug == "" then null else $integration_slug end),
      integration_branch: (if $integration_branch == "" then null else $integration_branch end),
      skip_ensure: $skip_ensure,
      skip_release: $skip_release,
      source: $source
    }'
}

cmd_ensure_ticket_worktree() {
  # ensure-ticket-worktree <TICKET-ID>
  # CDT-141-C3: when epic child has shared integration WT, print that path and
  # MUST NOT call worktree-lib ensure for the child slug (zero per-child trees).
  # Otherwise: worktree-lib ensure <TICKET-ID> (today's per-ticket behavior).
  # Stdout: absolute worktree path only (same contract as worktree-lib ensure).
  # Extra diagnostics on stderr. JSON summary line after path? No — path only so
  # callers can WT_PATH=$(bash … ensure-ticket-worktree …) like worktree-lib.
  local ticket="${1:-}"
  [ -n "$ticket" ] || die 64 "ensure-ticket-worktree: missing <TICKET-ID>"
  [ $# -eq 1 ] || die 64 "ensure-ticket-worktree: unexpected args"

  local resolved use_shared path
  resolved=$(cmd_resolve_child_worktree "$ticket") || return $?
  use_shared=$(echo "$resolved" | jq -r '.use_shared // false')

  if [ "$use_shared" = "true" ]; then
    path=$(echo "$resolved" | jq -r '.integration_path // empty')
    [ -n "$path" ] && [ -d "$path" ] || die 1 "ensure-ticket-worktree: shared path missing or not a dir: ${path:-null}"
    # Do NOT call worktree-lib ensure for child slug or re-ensure epic slug.
    printf '%s\n' "$path"
    return 0
  fi

  [ -f "$WT_LIB" ] || die 1 "ensure-ticket-worktree: worktree-lib not found: $WT_LIB"
  local errf erc=0
  errf=$(mktemp "${TMPDIR:-/tmp}/epic-ticket-wt.XXXXXX")
  set +e
  path=$(bash "$WT_LIB" ensure "$ticket" 2>"$errf")
  erc=$?
  set -e
  if [ "$erc" -ne 0 ] || [ -z "$path" ]; then
    local diag
    diag=$(tr '\n' ' ' <"$errf" | sed 's/[[:space:]]*$//')
    rm -f "$errf"
    # Preserve worktree-lib exit codes (1/2/64) for callers.
    if [ -n "$diag" ]; then
      printf '%s\n' "$diag" >&2
    fi
    exit "${erc:-1}"
  fi
  rm -f "$errf"
  path=$(printf '%s' "$path" | tr -d '\r' | sed 's/[[:space:]]*$//')
  [ -n "$path" ] || die 1 "ensure-ticket-worktree: empty path from worktree-lib"
  printf '%s\n' "$path"
}

# ---- CDT-141-C4: mid-epic /release + master-merge forbid --------------------

cmd_assert_release_allowed() {
  # assert-release-allowed <ticket-or-epic>
  # Exit 0 when /release and land-to-master are allowed for this work.
  # Exit 64 when durable state has release_bump set and seal is not done
  # (release=end mid-flight). Message names the epic and CDT-141.
  # Reads state only — resume-safe; no side effects.
  # C5 seal path: set EPIC_ALLOW_SEAL_RELEASE=1 to bypass (or sealed=true).
  local ref="${1:-}"
  [ -n "$ref" ] || die 64 "assert-release-allowed: missing <ticket-or-epic>"
  [ $# -eq 1 ] || die 64 "assert-release-allowed: unexpected args"
  validate_epic_id "$ref"

  # C5 seal invocation may temporarily allow the end-of-epic /release.
  if [ "${EPIC_ALLOW_SEAL_RELEASE:-}" = "1" ]; then
    return 0
  fi

  local epic_id="" st=""
  resolve_mroot

  if [ -f "$MROOT/.claude/epics/$ref/state.json" ]; then
    epic_id="$ref"
    st=$(cat "$MROOT/.claude/epics/$ref/state.json")
  else
    _find_parent_epic_for_ticket "$ref"
    if [ "$_RCW_FOUND" -eq 1 ]; then
      epic_id="$_RCW_EPIC_ID"
      st="$_RCW_STATE_JSON"
    else
      # Unknown ticket / no epic state → not under release=end; allow.
      return 0
    fi
  fi

  local rb sealed
  rb=$(echo "$st" | jq -r '.release_bump // empty')
  sealed=$(echo "$st" | jq -r 'if .sealed == true then "true" else "false" end')

  # release_bump absent/null → per-child release/merge unchanged
  if [ -z "$rb" ] || [ "$rb" = "null" ]; then
    return 0
  fi

  # Post-seal (C5 sets sealed=true) → allow
  if [ "$sealed" = "true" ]; then
    return 0
  fi

  # Mid-flight: release_bump set, seal not done — forbid /release + master merge
  die 64 "epic $epic_id is in release=end mode until seal (CDT-141)"
}

# ---- CDT-158 / SPEC-025 M16: mid-epic incomplete-child gap callout ----------

cmd_gap_callout() {
  # gap-callout <ticket-or-epic>
  # Warn-only: stdout notice when any child other than the shipping ref is
  # not completed. Empty stdout + exit 0 for unknown / all-complete / last
  # remaining child. Never mutates state. Incomplete never changes exit (0).
  # Charset same as assert-release-allowed (64 before path join).
  local ref="${1:-}"
  [ -n "$ref" ] || die 64 "gap-callout: missing <ticket-or-epic>"
  [ $# -eq 1 ] || die 64 "gap-callout: unexpected args"
  validate_epic_id "$ref"

  local st=""
  resolve_mroot

  if [ -f "$MROOT/.claude/epics/$ref/state.json" ]; then
    st=$(cat "$MROOT/.claude/epics/$ref/state.json")
  else
    _find_parent_epic_for_ticket "$ref"
    if [ "$_RCW_FOUND" -eq 1 ]; then
      st="$_RCW_STATE_JSON"
    else
      return 0
    fi
  fi

  local shipping_id n_other
  shipping_id=$(printf '%s\n' "$st" | jq -r --arg t "$ref" \
    '([.children[]? | select(.id==$t or .linear_id==$t) | .id] | first) // empty')

  n_other=$(printf '%s\n' "$st" | jq -r --arg sid "$shipping_id" \
    '[.children[]? | select(.status != "completed" and .id != $sid)] | length')
  [ "${n_other:-0}" -gt 0 ] || return 0

  printf '%s\n' "$st" | jq -r --arg sid "$shipping_id" '
    def titles(xs): [xs[] | .title] | join(", ");
    (.children // []) as $ch |
    ($ch | map(select(.status != "completed"))) as $inc |
    ($inc | map(select(.id != $sid))) as $pend |
    ($ch | map(select(.status == "completed" or .id == $sid))) as $incl |
    "mid-epic ship: remaining children are out of this tag",
    "incomplete:",
    ($inc[] | "\(.id) \(.title)"),
    "includes: \(titles($incl))",
    "pending: \(titles($pend))",
    "partial product: this tag is not the full epic"
  '
}

# ---- CDT-141-C5: end-of-epic seal (squash → one /release <bump>) ------------

# Resolve main-repo checkout for squash-stage (MROOT; EPIC_ROOT in tests).
_seal_main_repo() {
  resolve_mroot
  SEAL_MAIN="$MROOT"
  if [ ! -d "$SEAL_MAIN/.git" ] && [ ! -f "$SEAL_MAIN/.git" ]; then
    # bare EPIC_ROOT without git is ok for seal-ready; seal stage needs git
    return 1
  fi
  return 0
}

# Default branch on main repo: master preferred, else main.
_seal_default_branch() {
  local main="$1"
  if git -C "$main" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    SEAL_DEFAULT=master
  elif git -C "$main" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    SEAL_DEFAULT=main
  else
    return 1
  fi
  return 0
}

# Compute seal readiness fields from state JSON (no side effects).
# Sets: SEAL_RB, SEAL_WT, SEAL_SEALED, SEAL_INCOMPLETE, SEAL_TOTAL,
#        SEAL_BRANCH, SEAL_PATH, SEAL_READY, SEAL_REASON
_seal_eval_ready() {
  local st="$1"
  SEAL_RB=$(echo "$st" | jq -r '.release_bump // empty')
  SEAL_WT=$(echo "$st" | jq -r 'if .worktree_enabled == true then "true" else "false" end')
  SEAL_SEALED=$(echo "$st" | jq -r 'if .sealed == true then "true" else "false" end')
  SEAL_INCOMPLETE=$(echo "$st" | jq '[.children[] | select(.status != "completed")] | length')
  SEAL_TOTAL=$(echo "$st" | jq '.children | length')
  SEAL_BRANCH=$(echo "$st" | jq -r '.integration_branch // empty')
  SEAL_PATH=$(echo "$st" | jq -r '.integration_path // empty')
  SEAL_READY=false
  SEAL_REASON=""

  if [ -z "$SEAL_RB" ] || [ "$SEAL_RB" = "null" ]; then
    SEAL_REASON="no_release_bump"
    return 0
  fi
  if [ "$SEAL_WT" != "true" ]; then
    SEAL_REASON="worktree_disabled"
    return 0
  fi
  if [ "$SEAL_SEALED" = "true" ]; then
    SEAL_REASON="already_sealed"
    return 0
  fi
  if [ "$SEAL_TOTAL" -eq 0 ]; then
    SEAL_REASON="no_children"
    return 0
  fi
  if [ "$SEAL_INCOMPLETE" -gt 0 ]; then
    SEAL_REASON="children_incomplete"
    return 0
  fi
  if [ -z "$SEAL_BRANCH" ]; then
    SEAL_REASON="missing_integration_branch"
    return 0
  fi
  SEAL_READY=true
  SEAL_REASON="ready"
}

_seal_ready_json() {
  local epic_id="$1"
  jq -nc \
    --arg epic_id "$epic_id" \
    --argjson ready "$([ "$SEAL_READY" = true ] && echo true || echo false)" \
    --argjson worktree_enabled "$([ "$SEAL_WT" = true ] && echo true || echo false)" \
    --arg release_bump "${SEAL_RB:-}" \
    --argjson sealed "$([ "$SEAL_SEALED" = true ] && echo true || echo false)" \
    --argjson all_children_completed "$([ "${SEAL_INCOMPLETE:-1}" -eq 0 ] && [ "${SEAL_TOTAL:-0}" -gt 0 ] && echo true || echo false)" \
    --argjson children_total "${SEAL_TOTAL:-0}" \
    --argjson children_incomplete "${SEAL_INCOMPLETE:-0}" \
    --arg integration_branch "${SEAL_BRANCH:-}" \
    --arg integration_path "${SEAL_PATH:-}" \
    --arg reason "${SEAL_REASON:-}" \
    '{
      ready:$ready,
      epic_id:$epic_id,
      worktree_enabled:$worktree_enabled,
      release_bump:(if $release_bump=="" then null else $release_bump end),
      sealed:$sealed,
      all_children_completed:$all_children_completed,
      children_total:$children_total,
      children_incomplete:$children_incomplete,
      integration_branch:(if $integration_branch=="" then null else $integration_branch end),
      integration_path:(if $integration_path=="" then null else $integration_path end),
      reason:$reason
    }'
}

cmd_seal_ready() {
  # seal-ready <EPIC-ID>
  # Pure check: exit 0 + JSON always when state exists.
  # ready=true only when worktree_enabled, release_bump set, all children
  # completed, sealed≠true, integration_branch present.
  # Without --release (release_bump null): ready=false reason=no_release_bump.
  local epic_id="${1:-}"
  [ -n "$epic_id" ] || die 64 "seal-ready: missing <EPIC-ID>"
  [ $# -eq 1 ] || die 64 "seal-ready: unexpected args"
  local st
  st=$(read_state "$epic_id")
  _seal_eval_ready "$st"
  _seal_ready_json "$epic_id"
}

# Reset squash-stage on main (merge --squash has no MERGE_HEAD).
# Callers: abort (after dirty gate), squash-fail, hook-fail recovery (AC6).
_seal_reset_main() {
  local main="$1"
  git -C "$main" reset --hard >/dev/null 2>&1 || true
  git -C "$main" clean -fd >/dev/null 2>&1 || true
}

# True (return 0) when main-repo checkout has non-empty porcelain (CDT-170).
_seal_main_is_dirty() {
  local main="$1"
  [ -n "$(git -C "$main" status --porcelain 2>/dev/null)" ]
}

cmd_seal() {
  # seal <EPIC-ID> [--dry-run|--complete|--abort [--force]]
  # End-of-epic seal composition (CDT-141-C5 / M14 / CDT-170):
  #   default     — preflight → squash-stage on master/main →
  #                 EPIC_SEAL_RELEASE_HOOK (tests) or handoff JSON for /release
  #   --dry-run   — readiness + plan only; zero git / state writes
  #   --complete  — set sealed=true after successful /release (atomic)
  #   --abort     — reset --hard main only if clean (or with --force); leave sealed=false
  #   --force     — only with --abort; MAY wipe dirty main WIP
  # Without release_bump: exit 0 skipped (no epic seal path).
  # Already sealed: exit 0 already_sealed (runs once).
  # Failure: sealed stays false; main restored clean (no partial tag/push from us).
  local epic_id="" mode="run" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) mode=dry-run; shift ;;
      --complete) mode=complete; shift ;;
      --abort) mode=abort; shift ;;
      --force) force=1; shift ;;
      -*)
        die 64 "seal: unknown flag $1"
        ;;
      *)
        if [ -z "$epic_id" ]; then epic_id="$1"; shift
        else die 64 "seal: unexpected arg $1"
        fi
        ;;
    esac
  done
  [ -n "$epic_id" ] || die 64 "seal: missing <EPIC-ID>"
  if [ "$force" -eq 1 ] && [ "$mode" != "abort" ]; then
    die 64 "seal: --force only valid with --abort"
  fi

  local st
  st=$(read_state "$epic_id")
  _seal_eval_ready "$st"

  # ---- --abort: cleanup on main (dirty gate unless --force; CDT-170) ----
  if [ "$mode" = "abort" ]; then
    if _seal_main_repo; then
      if _seal_main_is_dirty "$SEAL_MAIN" && [ "$force" -eq 0 ]; then
        die 1 "seal: main working tree dirty — refuse abort (use --abort --force to wipe)"
      fi
      _seal_reset_main "$SEAL_MAIN"
    fi
    # ensure sealed remains false (do not flip true)
    if [ "$SEAL_SEALED" = "true" ]; then
      # already sealed — abort does not unseal
      jq -nc --arg id "$epic_id" \
        '{epic_id:$id, aborted:false, reason:"already_sealed", sealed:true}'
      return 0
    fi
    jq -nc --arg id "$epic_id" \
      '{epic_id:$id, aborted:true, sealed:false, reason:"reset"}'
    return 0
  fi

  # ---- --complete: mark sealed after /release succeeded ----
  if [ "$mode" = "complete" ]; then
    # Preflight from unlocked snapshot; re-check under lock before write
    if [ -z "$SEAL_RB" ] || [ "$SEAL_RB" = "null" ]; then
      die 64 "seal --complete: no release_bump (no seal path without --release)"
    fi
    if [ "$SEAL_SEALED" = "true" ]; then
      jq -nc --arg id "$epic_id" --arg rb "$SEAL_RB" \
        '{epic_id:$id, sealed:true, already_sealed:true, release_bump:$rb}'
      return 0
    fi
    if [ "$SEAL_INCOMPLETE" -gt 0 ] || [ "$SEAL_TOTAL" -eq 0 ]; then
      die 64 "seal --complete: not all children completed"
    fi
    epic_paths "$epic_id"
    mkdir -p "$EPICS_DIR"
    (
      flock -x 9
      st=$(read_state "$epic_id")
      _seal_eval_ready "$st"
      if [ -z "$SEAL_RB" ] || [ "$SEAL_RB" = "null" ]; then
        die 64 "seal --complete: no release_bump (no seal path without --release)"
      fi
      if [ "$SEAL_SEALED" = "true" ]; then
        jq -nc --arg id "$epic_id" --arg rb "$SEAL_RB" \
          '{epic_id:$id, sealed:true, already_sealed:true, release_bump:$rb}'
        exit 0
      fi
      if [ "$SEAL_INCOMPLETE" -gt 0 ] || [ "$SEAL_TOTAL" -eq 0 ]; then
        die 64 "seal --complete: not all children completed"
      fi
      st=$(echo "$st" | jq '.sealed = true')
      write_state "$epic_id" "$st"
      jq -nc --arg id "$epic_id" --arg rb "$SEAL_RB" \
        '{epic_id:$id, sealed:true, already_sealed:false, release_bump:$rb}'
    ) 9>>"$EPICS_LOCK"
    return 0
  fi

  # ---- no release mode: skip (without --release, no seal path) ----
  if [ -z "$SEAL_RB" ] || [ "$SEAL_RB" = "null" ]; then
    jq -nc --arg id "$epic_id" --arg reason "$SEAL_REASON" \
      '{epic_id:$id, skipped:true, sealed:false, reason:$reason}'
    return 0
  fi

  # ---- already sealed: once only ----
  if [ "$SEAL_SEALED" = "true" ]; then
    jq -nc --arg id "$epic_id" --arg rb "$SEAL_RB" \
      '{epic_id:$id, already_sealed:true, sealed:true, release_bump:$rb, skipped:true}'
    return 0
  fi

  # ---- not ready (incomplete / missing branch / etc.) ----
  if [ "$SEAL_READY" != true ]; then
    die 64 "seal: not ready ($SEAL_REASON) — need worktree_enabled, release_bump, all children completed, not sealed"
  fi

  # ---- dry-run: plan only ----
  if [ "$mode" = "dry-run" ]; then
    jq -nc \
      --arg id "$epic_id" \
      --arg rb "$SEAL_RB" \
      --arg branch "$SEAL_BRANCH" \
      --arg path "${SEAL_PATH:-}" \
      '{
        epic_id:$id,
        dry_run:true,
        ready:true,
        release_bump:$rb,
        integration_branch:$branch,
        integration_path:(if $path=="" then null else $path end),
        plan:["squash-stage integration onto master/main","EPIC_ALLOW_SEAL_RELEASE=1 /release "+$rb,"seal --complete"],
        sealed:false
      }'
    return 0
  fi

  # ---- live seal: squash-stage + hook or handoff ----
  _seal_main_repo || die 1 "seal: main repo not found at $MROOT"
  local main="$SEAL_MAIN"
  _seal_default_branch "$main" || die 1 "seal: no master/main branch in $main"
  local default="$SEAL_DEFAULT"

  # integration branch must exist
  if ! git -C "$main" show-ref --verify --quiet "refs/heads/$SEAL_BRANCH" 2>/dev/null; then
    die 1 "seal: integration branch missing: $SEAL_BRANCH"
  fi

  # Require clean tree on default before staging (master unchanged until seal)
  local cur
  cur=$(git -C "$main" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$cur" != "$default" ]; then
    # Prefer checkout default when not locked by another worktree
    if ! git -C "$main" checkout -q "$default" 2>/dev/null; then
      die 1 "seal: cannot checkout $default on $main (current=$cur) — seal from main-repo checkout"
    fi
  fi
  if ! git -C "$main" diff --quiet 2>/dev/null \
    || ! git -C "$main" diff --cached --quiet 2>/dev/null; then
    die 1 "seal: $default working tree dirty — refuse squash-stage"
  fi

  local master_before
  master_before=$(git -C "$main" rev-parse HEAD)

  # Squash-stage only — no commit ( /release is sole ship-of-record )
  set +e
  local squash_err
  squash_err=$(git -C "$main" merge --squash "$SEAL_BRANCH" 2>&1)
  local squash_rc=$?
  set -e
  if [ "$squash_rc" -ne 0 ]; then
    _seal_reset_main "$main"
    die 1 "seal: squash conflict/fail for $SEAL_BRANCH — master restored (rc=$squash_rc): $(echo "$squash_err" | tr '\n' ' ')"
  fi

  # Empty squash (integration == master): still allow release of empty? treat as ok stage
  # Hook path (tests / automation): run mock /release once
  if [ -n "${EPIC_SEAL_RELEASE_HOOK:-}" ]; then
    set +e
    (
      cd "$main" || exit 1
      export EPIC_ALLOW_SEAL_RELEASE=1
      export EPIC_ID="$epic_id"
      export EPIC_RELEASE_END="$epic_id"
      export EPIC_RELEASE_BUMP="$SEAL_RB"
      export EPIC_INTEGRATION_BRANCH="$SEAL_BRANCH"
      # shellcheck disable=SC2086
      eval "$EPIC_SEAL_RELEASE_HOOK"
    )
    local hook_rc=$?
    set -e
    if [ "$hook_rc" -ne 0 ]; then
      _seal_reset_main "$main"
      # sealed stays false
      die 1 "seal: release hook failed (rc=$hook_rc) — master restored, sealed=false"
    fi
    # Success → sealed=true under EPICS_LOCK (git/hook work already outside lock)
    epic_paths "$epic_id"
    mkdir -p "$EPICS_DIR"
    (
      flock -x 9
      st=$(read_state "$epic_id")
      st=$(echo "$st" | jq '.sealed = true')
      write_state "$epic_id" "$st"
    ) 9>>"$EPICS_LOCK"
    local master_after
    master_after=$(git -C "$main" rev-parse HEAD)
    jq -nc \
      --arg id "$epic_id" \
      --arg rb "$SEAL_RB" \
      --arg branch "$SEAL_BRANCH" \
      --arg before "$master_before" \
      --arg after "$master_after" \
      '{
        epic_id:$id,
        sealed:true,
        release_bump:$rb,
        integration_branch:$branch,
        staged:true,
        release_invoked:true,
        master_before:$before,
        master_after:$after,
        already_sealed:false
      }'
    return 0
  fi

  # No hook: leave squash staged; print handoff for orchestrator (/release SoT)
  jq -nc \
    --arg id "$epic_id" \
    --arg rb "$SEAL_RB" \
    --arg branch "$SEAL_BRANCH" \
    --arg default "$default" \
    --arg main "$main" \
    --arg before "$master_before" \
    '{
      epic_id:$id,
      sealed:false,
      staged:true,
      release_bump:$rb,
      integration_branch:$branch,
      default_branch:$default,
      main_repo:$main,
      master_before:$before,
      release_invoked:false,
      env:{EPIC_ALLOW_SEAL_RELEASE:"1", EPIC_ID:$id, EPIC_RELEASE_END:$id, EPIC_RELEASE_BUMP:$rb},
      handoff:("/release "+$rb),
      next:["EPIC_ALLOW_SEAL_RELEASE=1 /release "+$rb,"bash epic-lib seal "+$id+" --complete"],
      on_failure:("bash epic-lib seal "+$id+" --abort --force")
    }'
}

cmd_mark_done() {
  local ticket="${1:-}"
  [ -n "$ticket" ] || die 64 "mark-done: missing <TICKET-ID>"
  resolve_mroot
  local epics_dir="$MROOT/.claude/epics"
  local EPICS_DIR="$epics_dir"
  local EPICS_LOCK="$EPICS_DIR/.lock"
  [ -d "$epics_dir" ] || exit 0

  # RO find scan outside lock; per-epic RMW under EPICS_LOCK (re-read under lock)
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
    mkdir -p "$EPICS_DIR"
    (
      flock -x 9
      epic_paths "$epic_id"
      [ -f "$STATE" ] || exit 0
      if ! jq -e --arg t "$ticket" \
        '.children[] | select(.id==$t or .linear_id==$t)' "$STATE" >/dev/null 2>&1; then
        exit 0
      fi
      st=$(jq --arg t "$ticket" \
        '(.children[] | select(.id==$t or .linear_id==$t) | .status) = "completed"' \
        "$STATE")
      write_state "$epic_id" "$st"
      echo "$st" | jq -c --arg t "$ticket" \
        '.children[] | select(.id==$t or .linear_id==$t)'
    ) 9>>"$EPICS_LOCK"
    found=1
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
      linear_project_id: (.linear_project_id // null),
      last_seed_path: (.last_seed_path // null),
      worktree_enabled: (.worktree_enabled // false),
      release_bump: (.release_bump // null),
      sealed: (.sealed // false),
      integration_slug: (.integration_slug // null),
      integration_path: (.integration_path // null),
      integration_branch: (.integration_branch // null),
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
        linear_project_id: (.linear_project_id // null),
        last_seed_path: (.last_seed_path // null),
        worktree_enabled: (.worktree_enabled // false),
        release_bump: (.release_bump // null),
        integration_slug: (.integration_slug // null),
        integration_path: (.integration_path // null),
        integration_branch: (.integration_branch // null),
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

# ---- CDT-127 / SPEC-025 M13: between-child seed (mechanical STM subset) -----

# Render seed markdown from state JSON on stdin.
# Args: <next-child-id> <generated_at> <waves-line>
_seed_render() {
  local next_id="$1" gen_at="$2" waves="$3"
  jq -r --arg next "$next_id" --arg ts "$gen_at" --arg waves "$waves" '
    def ready_ids:
      (.children as $all
       | ($all | map({key:.id, value:.status}) | from_entries) as $stmap
       | [$all[]
          | select(.status == "pending")
          | select(all(.depends_on[]?; ($stmap[.] // "missing") == "completed"))
          | .id]
       | sort | join(", "));
    def count_line:
      "pending=\([.children[] | select(.status=="pending")] | length)"
      + " in_progress=\([.children[] | select(.status=="in_progress")] | length)"
      + " completed=\([.children[] | select(.status=="completed")] | length)"
      + " blocked=\([.children[] | select(.status=="blocked")] | length)"
      + " total=\(.children | length)";
    def in_prog_line:
      ([.children[] | select(.status=="in_progress") | .id] | join(", ")) as $x
      | if $x == "" then "(none)" else $x end;
    def blocker_bullets:
      [.children[] | select(.status=="blocked")
       | "  - \(.id)"
         + (if (.outcome_summary // "") != "" then " — \(.outcome_summary)" else "" end)];
    def completed_lines:
      [.children[] | select(.status=="completed")
       | "- \(.id) completed — \(.outcome_summary // "")"];
    def last_completed:
      ([.children[] | select(.status=="completed") | .id] | last // "none");
    def open_blockers:
      [.children[] | select(.status=="blocked")
       | "- \(.id) blocked — \(.outcome_summary // "")"
         + "\n  problem: \(.problem // "")"];
    . as $s
    | ($s.children[] | select(.id == $next)) as $n
    | [
        "# Epic seed: \($s.epic_id)",
        "epic_id: \($s.epic_id)",
        "mode: \($s.execution_mode)",
        "generated_at: \($ts)",
        "last_completed: \(last_completed)",
        "next_child: \($next)",
        "",
        "## State now",
        "- counts: \(count_line)",
        "- ready: \(if ready_ids == "" then "(none)" else ready_ids end)",
        "- in_progress: \(in_prog_line)",
        "- blockers:",
        (if (blocker_bullets | length) == 0 then "  (none)"
         else (blocker_bullets | join("\n")) end),
        "- last_seed_path: \($s.last_seed_path // "null")",
        "",
        "## Through-line",
        (if (completed_lines | length) == 0 then "- (none)"
         else (completed_lines | join("\n")) end),
        "waves: \($waves)",
        "",
        "## appendix",
        "### Next: \($next)",
        "- title: \($n.title // "")",
        "- problem: \($n.problem // "")",
        "- acceptance_criteria: \($n.acceptance_criteria // [] | tostring)",
        "- estimate: \($n.estimate // "")",
        "- agent: \($n.agent // "")",
        "- depends_on: \($n.depends_on // [] | tostring)",
        "- execution_mode: \($s.execution_mode)",
        "",
        "### Open blockers",
        (if (open_blockers | length) == 0 then "(none)"
         else (open_blockers | join("\n")) end),
        ""
      ] | join("\n")
  '
}

cmd_build_seed() {
  # build-seed <EPIC-ID> [--next <CHILD-ID>] [--out path]
  # Mechanical STM-shaped packet from state.json (SPEC-025 M13.3). No handoff mine.
  # Fail-closed: missing state / zero children / no next → exit 1, no file.
  local epic_id="${1:-}"
  [ -n "$epic_id" ] || die 64 "build-seed: missing <EPIC-ID>"
  shift

  local next_arg="" out_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --next)
        [ $# -ge 2 ] || die 64 "build-seed: --next needs a value"
        next_arg="$2"; shift 2
        ;;
      --next=*)
        next_arg="${1#--next=}"; shift
        ;;
      --out)
        [ $# -ge 2 ] || die 64 "build-seed: --out needs a value"
        out_arg="$2"; shift 2
        ;;
      --out=*)
        out_arg="${1#--out=}"; shift
        ;;
      -*)
        die 64 "build-seed: unknown flag $1"
        ;;
      *)
        die 64 "build-seed: unexpected arg: $1"
        ;;
    esac
  done

  local st
  st=$(read_state "$epic_id")   # die 1 if missing

  local nchildren
  nchildren=$(echo "$st" | jq '.children | length')
  if [ "$nchildren" -eq 0 ]; then
    die 1 "build-seed: epic has zero children"
  fi

  local next_id
  if [ -n "$next_arg" ]; then
    next_id="$next_arg"
    if ! echo "$st" | jq -e --arg id "$next_id" '.children[] | select(.id==$id)' >/dev/null 2>&1; then
      die 1 "build-seed: --next child not found: $next_id"
    fi
  else
    next_id=$(cmd_ready_set "$epic_id" | head -n1 || true)
    [ -n "$next_id" ] || die 1 "build-seed: no ready child (pass --next)"
  fi

  local last_completed gen_at waves body
  last_completed=$(echo "$st" | jq -r '[.children[] | select(.status=="completed") | .id] | last // "none"')
  gen_at=$(iso_now)
  waves=$(cmd_waves "$epic_id" 2>/dev/null || true)
  [ -n "$waves" ] || waves="(none)"

  body=$(echo "$st" | _seed_render "$next_id" "$gen_at" "$waves") || die 1 "build-seed: render failed"
  [ -n "$body" ] || die 1 "build-seed: empty render"

  epic_paths "$epic_id"
  local seeds_dir out_path tmp abs
  seeds_dir="$EPIC_DIR/seeds"
  mkdir -p "$seeds_dir"

  if [ -n "$out_arg" ]; then
    out_path="$out_arg"
    mkdir -p "$(dirname "$out_path")"
  else
    local stamp prev_tag
    stamp=$(date -u +%Y%m%d-%H%M)
    prev_tag="$last_completed"
    [ -n "$prev_tag" ] || prev_tag="none"
    out_path="$seeds_dir/${stamp}-${prev_tag}-to-${next_id}.md"
  fi

  tmp="${out_path}.tmp.$$"
  printf '%s\n' "$body" > "$tmp"
  # fail-closed: refuse to land a seed that would not validate
  # subshell so validate-seed die/exit does not skip tmp cleanup
  if ! ( cmd_validate_seed "$tmp" >/dev/null 2>&1 ); then
    rm -f "$tmp"
    die 1 "build-seed: rendered seed failed validation"
  fi
  mv "$tmp" "$out_path"

  if command -v realpath >/dev/null 2>&1; then
    abs=$(realpath "$out_path")
  else
    abs=$(cd "$(dirname "$out_path")" && pwd)/$(basename "$out_path")
  fi

  # record last_seed_path under EPICS_LOCK (seed file already published outside lock)
  mkdir -p "$EPICS_DIR"
  (
    flock -x 9
    st=$(read_state "$epic_id")
    st=$(echo "$st" | jq --arg v "$abs" '.last_seed_path = $v')
    write_state "$epic_id" "$st"
  ) 9>>"$EPICS_LOCK"

  printf '%s\n' "$abs"
}

cmd_validate_seed() {
  # validate-seed <path>
  # Exit 0 if required M13.3 markers present; 1 if empty/corrupt/missing sections.
  local path="${1:-}"
  [ -n "$path" ] || die 64 "validate-seed: missing <path>"
  [ -f "$path" ] || die 1 "validate-seed: not found: $path"
  [ -s "$path" ] || die 1 "validate-seed: empty: $path"

  grep -qE '^## State now' "$path" \
    || die 1 "validate-seed: missing ## State now"
  grep -qE '^## Through-line' "$path" \
    || die 1 "validate-seed: missing ## Through-line"
  grep -qE '^## appendix' "$path" \
    || die 1 "validate-seed: missing ## appendix"

  # epic_id: … or Epic: … with non-empty id
  if ! grep -qE '^(epic_id:|Epic:)[[:space:]]*[^[:space:]]+' "$path"; then
    die 1 "validate-seed: missing epic_id:/Epic: marker with id"
  fi

  # next_child: … or ### Next: … with child id
  if ! grep -qE '^next_child:[[:space:]]*[^[:space:]]+' "$path" \
    && ! grep -qE '^### Next:[[:space:]]*[^[:space:]]+' "$path"; then
    die 1 "validate-seed: missing next_child:/### Next: marker with id"
  fi

  return 0
}

cmd_sync_apply() {
  # sync-apply <EPIC-ID> --verdicts FILE [--dry-run]
  # Session-owned Linear inventory → verdicts JSON; this command only mutates
  # state.json (no MCP). SPEC-025 M15.
  #
  # Verdicts shape:
  # {
  #   "linear_project_id": "<id>" | null,   # optional; set only when local is null
  #   "children": [
  #     { "id":"<EPIC>-C<n>", "status":"pending|in_progress|completed|blocked"?,
  #       "linear_id":"<LIN>"?, "outcome_summary":"<≤200 chars>"? }
  #   ],
  #   "orphans": [...],           # pass-through report only
  #   "unmatched_local": [...]    # pass-through report only
  # }
  #
  # Rules:
  # - Unknown child id → skip + conflict
  # - linear_id: fill when local null/empty; match → no-op; mismatch → conflict skip
  # - status: no-op if same; never downgrade completed → non-completed (no_downgrade_completed)
  # - outcome_summary only with completed|blocked when status is applied or already that status
  # - linear_project_id: fill when local null; mismatch non-null → conflict skip
  # - never deletes/reorders children; never re-decomposes
  # Exit: 0 ok (including all no-ops), 1 missing epic/verdicts/invalid JSON, 64 usage
  local epic_id="" verdicts="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --verdicts)
        [ $# -ge 2 ] || die 64 "sync-apply: --verdicts requires a file"
        verdicts="$2"
        shift 2
        ;;
      --verdicts=*)
        verdicts="${1#--verdicts=}"
        shift
        ;;
      --dry-run)
        dry=1
        shift
        ;;
      -*)
        die 64 "sync-apply: unknown flag $1"
        ;;
      *)
        if [ -z "$epic_id" ]; then
          epic_id="$1"
          shift
        else
          die 64 "sync-apply: unexpected arg $1"
        fi
        ;;
    esac
  done
  [ -n "$epic_id" ] || die 64 "sync-apply: missing <EPIC-ID>"
  [ -n "$verdicts" ] || die 64 "sync-apply: --verdicts FILE required"
  [ -f "$verdicts" ] || die 1 "sync-apply: verdicts file not found: $verdicts"

  if ! jq -e 'type == "object"' "$verdicts" >/dev/null 2>&1; then
    die 1 "sync-apply: verdicts must be a JSON object"
  fi
  if ! jq -e '(.children | type) == "array"' "$verdicts" >/dev/null 2>&1; then
    die 1 "sync-apply: verdicts.children must be a JSON array"
  fi

  # Verdicts parse/validate above stays outside lock; full state RMW under flock
  epic_paths "$epic_id"
  mkdir -p "$EPICS_DIR"
  (
    flock -x 9
    # note: plain subshell — no `local` (bash allows local only in functions)

    st=$(read_state "$epic_id")

    applied_json="[]"
    skipped_json="[]"
    conflicts_json="[]"
    v_proj="" child_id="" v_status="" v_lin="" v_out=""
    local_status="" local_lin="" local_proj="" local_out=""
    action_row=""

    # ---- project id (optional) ----
    if jq -e 'has("linear_project_id")' "$verdicts" >/dev/null 2>&1; then
      v_proj=$(jq -r '.linear_project_id // empty' "$verdicts")
      # empty / null JSON → treat as "no set request" when literal null
      if jq -e '.linear_project_id == null' "$verdicts" >/dev/null 2>&1; then
        : # ignore null project requests (never clear via sync)
      elif [ -n "$v_proj" ]; then
        local_proj=$(echo "$st" | jq -r '.linear_project_id // empty')
        if [ -z "$local_proj" ] || [ "$local_proj" = "null" ]; then
          st=$(echo "$st" | jq --arg v "$v_proj" '.linear_project_id = $v')
          action_row=$(jq -cn --arg a fill_linear_project --arg v "$v_proj" \
            '{action:$a, linear_project_id:$v}')
          applied_json=$(echo "$applied_json" | jq --argjson r "$action_row" '. + [$r]')
        elif [ "$local_proj" = "$v_proj" ]; then
          action_row=$(jq -cn --arg a project_id_unchanged --arg v "$v_proj" \
            '{action:$a, linear_project_id:$v}')
          skipped_json=$(echo "$skipped_json" | jq --argjson r "$action_row" '. + [$r]')
        else
          action_row=$(jq -cn --arg a project_id_mismatch \
            --arg local "$local_proj" --arg remote "$v_proj" \
            '{action:$a, local:$local, remote:$remote}')
          conflicts_json=$(echo "$conflicts_json" | jq --argjson r "$action_row" '. + [$r]')
        fi
      fi
    fi

    # ---- children ----
    n=$(jq '.children | length' "$verdicts")
    i=0
    while [ "$i" -lt "$n" ]; do
      child_id=$(jq -r --argjson i "$i" '.children[$i].id // empty' "$verdicts")
      if [ -z "$child_id" ]; then
        action_row=$(jq -cn --argjson i "$i" '{action:"missing_child_id", index:$i}')
        conflicts_json=$(echo "$conflicts_json" | jq --argjson r "$action_row" '. + [$r]')
        i=$((i + 1))
        continue
      fi
      if ! echo "$st" | jq -e --arg id "$child_id" '.children[] | select(.id==$id)' >/dev/null 2>&1; then
        action_row=$(jq -cn --arg a unknown_child --arg id "$child_id" '{action:$a, id:$id}')
        conflicts_json=$(echo "$conflicts_json" | jq --argjson r "$action_row" '. + [$r]')
        i=$((i + 1))
        continue
      fi

      local_status=$(echo "$st" | jq -r --arg id "$child_id" \
        '.children[] | select(.id==$id) | .status')
      local_lin=$(echo "$st" | jq -r --arg id "$child_id" \
        '.children[] | select(.id==$id) | .linear_id // empty')

      # linear_id fill
      if jq -e --argjson i "$i" '.children[$i] | has("linear_id")' "$verdicts" >/dev/null 2>&1 \
        && ! jq -e --argjson i "$i" '.children[$i].linear_id == null' "$verdicts" >/dev/null 2>&1; then
        v_lin=$(jq -r --argjson i "$i" '.children[$i].linear_id // empty' "$verdicts")
        if [ -n "$v_lin" ]; then
          if [ -z "$local_lin" ] || [ "$local_lin" = "null" ]; then
            st=$(echo "$st" | jq --arg id "$child_id" --arg v "$v_lin" \
              '(.children[] | select(.id==$id) | .linear_id) = $v')
            action_row=$(jq -cn --arg a fill_linear_id --arg id "$child_id" --arg v "$v_lin" \
              '{action:$a, id:$id, linear_id:$v}')
            applied_json=$(echo "$applied_json" | jq --argjson r "$action_row" '. + [$r]')
            local_lin="$v_lin"
          elif [ "$local_lin" = "$v_lin" ]; then
            action_row=$(jq -cn --arg a linear_id_unchanged --arg id "$child_id" --arg v "$v_lin" \
              '{action:$a, id:$id, linear_id:$v}')
            skipped_json=$(echo "$skipped_json" | jq --argjson r "$action_row" '. + [$r]')
          else
            action_row=$(jq -cn --arg a linear_id_mismatch --arg id "$child_id" \
              --arg local "$local_lin" --arg remote "$v_lin" \
              '{action:$a, id:$id, local:$local, remote:$remote}')
            conflicts_json=$(echo "$conflicts_json" | jq --argjson r "$action_row" '. + [$r]')
          fi
        fi
      fi

      # status
      if jq -e --argjson i "$i" '.children[$i] | has("status")' "$verdicts" >/dev/null 2>&1 \
        && ! jq -e --argjson i "$i" '.children[$i].status == null' "$verdicts" >/dev/null 2>&1; then
        v_status=$(jq -r --argjson i "$i" '.children[$i].status // empty' "$verdicts")
        case "$v_status" in
          pending|in_progress|completed|blocked)
            if [ "$local_status" = "$v_status" ]; then
              action_row=$(jq -cn --arg a status_unchanged --arg id "$child_id" --arg s "$v_status" \
                '{action:$a, id:$id, status:$s}')
              skipped_json=$(echo "$skipped_json" | jq --argjson r "$action_row" '. + [$r]')
            elif [ "$local_status" = "completed" ] && [ "$v_status" != "completed" ]; then
              action_row=$(jq -cn --arg a no_downgrade_completed --arg id "$child_id" \
                --arg local "$local_status" --arg remote "$v_status" \
                '{action:$a, id:$id, local:$local, remote:$remote}')
              skipped_json=$(echo "$skipped_json" | jq --argjson r "$action_row" '. + [$r]')
            else
              st=$(echo "$st" | jq --arg id "$child_id" --arg s "$v_status" \
                '(.children[] | select(.id==$id) | .status) = $s')
              action_row=$(jq -cn --arg a set_status --arg id "$child_id" \
                --arg from "$local_status" --arg to "$v_status" \
                '{action:$a, id:$id, from:$from, to:$to}')
              applied_json=$(echo "$applied_json" | jq --argjson r "$action_row" '. + [$r]')
              local_status="$v_status"
            fi
            ;;
          *)
            action_row=$(jq -cn --arg a invalid_status --arg id "$child_id" --arg s "$v_status" \
              '{action:$a, id:$id, status:$s}')
            conflicts_json=$(echo "$conflicts_json" | jq --argjson r "$action_row" '. + [$r]')
            ;;
        esac
      fi

      # outcome_summary (only when terminal status)
      if jq -e --argjson i "$i" '.children[$i] | has("outcome_summary")' "$verdicts" >/dev/null 2>&1 \
        && ! jq -e --argjson i "$i" '.children[$i].outcome_summary == null' "$verdicts" >/dev/null 2>&1; then
        v_out=$(jq -r --argjson i "$i" '.children[$i].outcome_summary // empty' "$verdicts")
        v_out=$(printf '%s' "$v_out" | tr '\n\r' '  ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ "${#v_out}" -gt 200 ]; then
          v_out="${v_out:0:200}"
        fi
        case "$local_status" in
          completed|blocked)
            if [ -n "$v_out" ]; then
              local_out=$(echo "$st" | jq -r --arg id "$child_id" \
                '.children[] | select(.id==$id) | .outcome_summary // empty')
              if [ "$local_out" = "$v_out" ]; then
                action_row=$(jq -cn --arg a outcome_unchanged --arg id "$child_id" \
                  '{action:$a, id:$id}')
                skipped_json=$(echo "$skipped_json" | jq --argjson r "$action_row" '. + [$r]')
              else
                st=$(echo "$st" | jq --arg id "$child_id" --arg o "$v_out" \
                  '(.children[] | select(.id==$id) | .outcome_summary) = $o')
                action_row=$(jq -cn --arg a set_outcome --arg id "$child_id" \
                  '{action:$a, id:$id}')
                applied_json=$(echo "$applied_json" | jq --argjson r "$action_row" '. + [$r]')
              fi
            fi
            ;;
          *)
            action_row=$(jq -cn --arg a outcome_skipped_nonterminal --arg id "$child_id" \
              --arg s "$local_status" '{action:$a, id:$id, status:$s}')
            skipped_json=$(echo "$skipped_json" | jq --argjson r "$action_row" '. + [$r]')
            ;;
        esac
      fi

      i=$((i + 1))
    done

    orphans=$(jq -c '.orphans // []' "$verdicts")
    unmatched=$(jq -c '.unmatched_local // []' "$verdicts")

    if [ "$dry" -eq 0 ]; then
      # Only write when something applied (avoid noisy updated_at on pure no-op)
      if [ "$(echo "$applied_json" | jq 'length')" -gt 0 ]; then
        write_state "$epic_id" "$st"
      fi
    fi

    jq -cn \
      --arg epic "$epic_id" \
      --argjson dry "$([ "$dry" -eq 1 ] && echo true || echo false)" \
      --argjson applied "$applied_json" \
      --argjson skipped "$skipped_json" \
      --argjson conflicts "$conflicts_json" \
      --argjson orphans "$orphans" \
      --argjson unmatched "$unmatched" \
      '{
        epic_id:$epic,
        dry_run:$dry,
        applied:$applied,
        skipped:$skipped,
        conflicts:$conflicts,
        orphans:$orphans,
        unmatched_local:$unmatched,
        applied_count:($applied|length),
        conflict_count:($conflicts|length)
      }'
  ) 9>>"$EPICS_LOCK"
}

# ---- dispatch ---------------------------------------------------------------

[ $# -lt 1 ] && usage
SUBCMD="$1"; shift

case "$SUBCMD" in
  init)        cmd_init "$@" ;;
  add-child)   cmd_add_child "$@" ;;
  set-status)  cmd_set_status "$@" ;;
  set-linear-project) cmd_set_linear_project "$@" ;;
  set-last-seed) cmd_set_last_seed "$@" ;;
  ensure-integration-worktree) cmd_ensure_integration_worktree "$@" ;;
  resolve-resume-flags) cmd_resolve_resume_flags "$@" ;;
  resolve-child-worktree) cmd_resolve_child_worktree "$@" ;;
  ensure-ticket-worktree) cmd_ensure_ticket_worktree "$@" ;;
  assert-release-allowed) cmd_assert_release_allowed "$@" ;;
  gap-callout) cmd_gap_callout "$@" ;;
  seal-ready)  cmd_seal_ready "$@" ;;
  seal)        cmd_seal "$@" ;;
  build-seed)  cmd_build_seed "$@" ;;
  validate-seed) cmd_validate_seed "$@" ;;
  mark-done)   cmd_mark_done "$@" ;;
  sync-apply)  cmd_sync_apply "$@" ;;

  ready-set)   cmd_ready_set "$@" ;;
  check-cycle) cmd_check_cycle "$@" ;;
  show)        cmd_show "$@" ;;
  rollup)      cmd_rollup "$@" ;;
  waves)       cmd_waves "$@" ;;
  exists)      cmd_exists "$@" ;;
  -h|--help|help) usage ;;
  *) die 64 "unknown subcommand: $SUBCMD" ;;
esac
