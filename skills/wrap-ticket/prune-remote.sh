#!/usr/bin/env bash
# prune-remote.sh — best-effort remote feat/* prune after wrap-ticket ship (CDT-157).
#
# Subprocess CLI — NEVER source. stdout = report; stderr = diagnostics.
#
# Usage:
#   prune-remote.sh allowlisted <name>
#   prune-remote.sh candidates <T> [--linear-id ID] [--child ID]... [--epic]
#   prune-remote.sh safe-to-delete <branch> [--base REF]
#   prune-remote.sh prune <T> [--linear-id ID] [--child ID]... [--epic] [--dry-run] [--base REF]
#
# Exit: allowlisted 0/1; safe-to-delete 0 safe / 1 leftover; prune 0 (usage 64).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EPIC_LIB="$HERE/../epic/epic-lib.sh"

USAGE='Usage: prune-remote.sh allowlisted <name>
       prune-remote.sh candidates <T> [--linear-id ID] [--child ID]... [--epic]
       prune-remote.sh safe-to-delete <branch> [--base REF]
       prune-remote.sh prune <T> [--linear-id ID] [--child ID]... [--epic] [--dry-run] [--base REF]'

usage() {
  printf '%s\n' "$USAGE" >&2
  exit 64
}

# allowlisted <name>
# Accepts ^feat/(epic-)?[A-Za-z][A-Za-z0-9]*-[0-9]+(-[A-Za-z0-9]+)*$ after
# optional origin/ strip. Rejects master/main/stable/develop/HEAD/extra / / ...
allowlisted() {
  local n="${1-}"
  [ -n "$n" ] || return 1
  n="${n#origin/}"
  case "$n" in
    *..*|*/|*/*/*) return 1 ;;
  esac
  [[ "$n" =~ ^feat/(epic-)?[A-Za-z][A-Za-z0-9]*-[0-9]+(-[A-Za-z0-9]+)*$ ]]
}

resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

epic_exists() {
  local id="$1"
  [ -n "$id" ] || return 1
  if [ -f "$EPIC_LIB" ]; then
    bash "$EPIC_LIB" exists "$id" >/dev/null 2>&1 && return 0
  fi
  resolve_mroot
  [ -f "$MROOT/.claude/epics/$id/state.json" ]
}

# Print child id / linear_id lines from epic state (skip empty/null).
state_child_ids() {
  local id="$1" state
  resolve_mroot
  state="$MROOT/.claude/epics/$id/state.json"
  [ -f "$state" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '.children[]? | (.id // empty), (.linear_id // empty)' "$state" 2>/dev/null \
      | sed '/^$/d'
  fi
}

# Append unique feat/<id> lines to CANDS (newline-separated).
add_cand() {
  local id="${1-}" b
  [ -n "$id" ] || return 0
  b="feat/${id}"
  case $'\n'"${CANDS-}"$'\n' in
    *$'\n'"$b"$'\n'*) return 0 ;;
  esac
  if [ -n "${CANDS-}" ]; then
    CANDS="${CANDS}"$'\n'"$b"
  else
    CANDS="$b"
  fi
}

# Populate CANDS from T + flags. Uses globals: T LINEAR_ID EPIC CHILDREN.
build_candidates() {
  local id
  CANDS=""
  add_cand "$T"
  if [ -n "$LINEAR_ID" ] && [ "$LINEAR_ID" != "$T" ]; then
    add_cand "$LINEAR_ID"
  fi
  if [ "$EPIC" = "1" ] || epic_exists "$T"; then
    add_cand "epic-${T}"
    while IFS= read -r id; do
      add_cand "$id"
    done < <(state_child_ids "$T")
  fi
  for id in "${CHILDREN[@]+"${CHILDREN[@]}"}"; do
    add_cand "$id"
  done
}

# Resolve merge base: --base, origin/HEAD, origin/master, origin/main, master, main.
resolve_base() {
  local ref
  if [ -n "${BASE-}" ]; then
    printf '%s\n' "$BASE"
    return 0
  fi
  if ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) && [ -n "$ref" ]; then
    printf '%s\n' "$ref"
    return 0
  fi
  for ref in origin/master origin/main master main; do
    if git rev-parse --verify --quiet "$ref" >/dev/null; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

# Resolve a constructed feat/ name to a local or origin tracking ref.
resolve_branch_ref() {
  local name="$1"
  name="${name#origin/}"
  if git rev-parse --verify --quiet "refs/heads/${name}" >/dev/null; then
    printf '%s\n' "refs/heads/${name}"
    return 0
  fi
  if git rev-parse --verify --quiet "refs/remotes/origin/${name}" >/dev/null; then
    printf '%s\n' "refs/remotes/origin/${name}"
    return 0
  fi
  return 1
}

# SAFE iff ancestor of base OR git cherry has no '+' lines.
# stdout: leftover reason when unsafe. exit 0 safe / 1 leftover.
is_safe() {
  local branch="$1" base="$2" br mb_rc cherry
  if ! br=$(resolve_branch_ref "$branch"); then
    printf 'missing\n'
    return 1
  fi
  mb_rc=0
  git merge-base --is-ancestor "$br" "$base" || mb_rc=$?
  if [ "$mb_rc" -eq 0 ]; then
    return 0
  fi
  if [ "$mb_rc" -ge 128 ]; then
    printf 'merge-base failed\n'
    return 1
  fi
  if ! cherry=$(git cherry "$base" "$br" 2>/dev/null); then
    printf 'cherry check failed\n'
    return 1
  fi
  if printf '%s\n' "$cherry" | grep -q '^+'; then
    printf 'unique commits\n'
    return 1
  fi
  return 0
}

cmd_allowlisted() {
  [ $# -ge 1 ] || usage
  if allowlisted "$1"; then
    exit 0
  fi
  exit 1
}

cmd_candidates() {
  parse_ticket_flags "$@"
  [ -n "$T" ] || usage
  build_candidates
  if [ -n "${CANDS-}" ]; then
    printf '%s\n' "$CANDS"
  fi
}

cmd_safe_to_delete() {
  local branch="" reason
  BASE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base)
        [ $# -ge 2 ] || usage
        BASE="$2"
        shift 2
        ;;
      -*) usage ;;
      *)
        if [ -z "$branch" ]; then
          branch="$1"
          shift
        else
          usage
        fi
        ;;
    esac
  done
  [ -n "$branch" ] || usage
  if ! BASE=$(resolve_base); then
    printf 'unresolvable base\n'
    exit 1
  fi
  if reason=$(is_safe "$branch" "$BASE"); then
    exit 0
  fi
  printf '%s\n' "$reason"
  exit 1
}

# Classify git push --delete stderr: already-gone vs real failure.
is_already_gone() {
  local err="$1"
  printf '%s' "$err" | grep -qiE 'remote ref does not exist|does not exist|src refspec .+ does not match|remote origin does not exist'
}

cmd_prune() {
  parse_ticket_flags "$@"
  [ -n "$T" ] || usage
  local base name ref reason err rc failed

  if ! base=$(resolve_base); then
    printf 'remote prune failed: unresolvable base\n'
    exit 0
  fi

  if [ "$DRY" != "1" ]; then
    if ! git remote get-url origin >/dev/null 2>&1; then
      printf 'remote prune failed: no origin remote\n'
      exit 0
    fi
  fi

  build_candidates
  failed=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    allowlisted "$name" || continue
    if ! ref=$(resolve_branch_ref "$name"); then
      # No local/tracking ref: live try-delete only if we can prove nothing —
      # AC2 forbids delete without safety. Silent skip (AC4 never-pushed).
      continue
    fi
    if reason=$(is_safe "$name" "$base"); then
      if [ "$DRY" = "1" ]; then
        printf 'pruned: %s\n' "$name"
        continue
      fi
      err=""
      rc=0
      err=$(git push origin --delete "$name" 2>&1) || rc=$?
      if [ "$rc" -eq 0 ]; then
        printf 'pruned: %s\n' "$name"
      elif is_already_gone "$err"; then
        :
      else
        if [ "$failed" -eq 0 ]; then
          printf 'remote prune failed: %s\n' "$err"
          failed=1
        fi
      fi
    else
      printf 'leftover: %s (%s)\n' "$name" "$reason"
    fi
  done < <(printf '%s\n' "${CANDS-}")
  exit 0
}

# Parse T + shared flags into globals.
parse_ticket_flags() {
  T=""
  LINEAR_ID=""
  EPIC=0
  DRY=0
  BASE=""
  CHILDREN=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --linear-id)
        [ $# -ge 2 ] || usage
        LINEAR_ID="$2"
        shift 2
        ;;
      --child)
        [ $# -ge 2 ] || usage
        CHILDREN+=("$2")
        shift 2
        ;;
      --epic)
        EPIC=1
        shift
        ;;
      --dry-run)
        DRY=1
        shift
        ;;
      --base)
        [ $# -ge 2 ] || usage
        BASE="$2"
        shift 2
        ;;
      -h|--help) usage ;;
      -*) usage ;;
      *)
        if [ -z "$T" ]; then
          T="$1"
          shift
        else
          usage
        fi
        ;;
    esac
  done
}

[ $# -ge 1 ] || usage
CMD="$1"
shift

case "$CMD" in
  allowlisted) cmd_allowlisted "$@" ;;
  candidates) cmd_candidates "$@" ;;
  safe-to-delete) cmd_safe_to_delete "$@" ;;
  prune) cmd_prune "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
